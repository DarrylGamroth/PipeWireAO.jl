"""
    ThreadLoop([name="PipeWireAO.jl"]; properties=nothing)

Create an owning PipeWire loop that runs on a native thread. Call [`start!`](@ref)
before expecting events and [`stop!`](@ref) before closing it. PipeWire objects
associated with this loop must be accessed while holding
[`with_thread_loop_lock`](@ref) unless the call originates in a loop callback.
"""
mutable struct ThreadLoop <: AbstractPipeWireLoop
    handle::Ptr{LibPipeWire.pw_thread_loop}
    state_lock::ReentrantLock
    running::Bool
    context_count::Int
    source_count::Int
    source_roots::IdDict{Any,Nothing}
    native_access_count::Int
end

function ThreadLoop(
    name::AbstractString="PipeWireAO.jl";
    properties=nothing,
)
    name_string = _validate_c_string(String(name), "thread-loop name")
    LibPipeWire.pw_init(C_NULL, C_NULL)
    handle = try
        _with_properties_dict(properties) do dictionary
            GC.@preserve name_string LibPipeWire.pw_thread_loop_new(
                pointer(name_string),
                dictionary,
            )
        end
    catch
        LibPipeWire.pw_deinit()
        rethrow()
    end
    if handle == C_NULL
        errno = Base.Libc.errno()
        LibPipeWire.pw_deinit()
        throw(PipeWireError(:pw_thread_loop_new, -errno))
    end

    loop = ThreadLoop(handle, ReentrantLock(), false, 0, 0, IdDict{Any,Nothing}(), 0)
    finalizer(close, loop)
    return loop
end

function _require_open(loop::ThreadLoop)
    loop.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire thread loop is closed", :closed))
    return loop.handle
end

function Base.isopen(loop::ThreadLoop)
    return lock(loop.state_lock) do
        loop.handle != C_NULL
    end
end

"Return whether the native PipeWire thread is running."
function isrunning(loop::ThreadLoop)
    return lock(loop.state_lock) do
        loop.handle != C_NULL && loop.running
    end
end

"Start the native PipeWire thread and return `loop`."
function start!(loop::ThreadLoop)
    result = lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.running && return Cint(0)
        result = LibPipeWire.pw_thread_loop_start(handle)
        result >= 0 && (loop.running = true)
        return result
    end
    _check_result(:pw_thread_loop_start, result)
    return loop
end

"Return whether the caller is the native PipeWire loop thread."
function in_thread(loop::ThreadLoop)
    return lock(loop.state_lock) do
        LibPipeWire.pw_thread_loop_in_thread(_require_open(loop))
    end
end

"Stop and join the native PipeWire thread, returning `loop`."
function stop!(loop::ThreadLoop)
    handle = lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.running || return Ptr{LibPipeWire.pw_thread_loop}(C_NULL)
        LibPipeWire.pw_thread_loop_in_thread(handle) && throw(
            InvalidStateException(
                "the PipeWire thread loop cannot stop itself",
                :loop_thread,
            ),
        )
        loop.running = false
        return handle
    end
    handle == C_NULL || LibPipeWire.pw_thread_loop_stop(handle)
    return loop
end

quit!(loop::ThreadLoop) = stop!(loop)

"""
    with_thread_loop_lock(f, loop)

Run `f(loop)` while holding PipeWire's native thread-loop lock. The lock is
recursive, so this is also valid inside a callback dispatched by `loop`.
"""
function with_thread_loop_lock(f, loop::ThreadLoop)
    handle = lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.native_access_count += 1
        return handle
    end
    LibPipeWire.pw_thread_loop_lock(handle)
    try
        return f(loop)
    finally
        LibPipeWire.pw_thread_loop_unlock(handle)
        lock(loop.state_lock) do
            loop.native_access_count -= 1
            @assert loop.native_access_count >= 0
        end
    end
end

function Base.close(loop::ThreadLoop)
    handle, running = lock(loop.state_lock) do
        loop.handle == C_NULL &&
            return Ptr{LibPipeWire.pw_thread_loop}(C_NULL), false
        loop.context_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire thread loop while contexts are open",
                :open_contexts,
            ),
        )
        loop.source_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire thread loop while loop sources are open",
                :open_sources,
            ),
        )
        loop.native_access_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire thread loop while its native lock is in use",
                :locked,
            ),
        )
        LibPipeWire.pw_thread_loop_in_thread(loop.handle) && throw(
            InvalidStateException(
                "the PipeWire thread loop cannot close itself",
                :loop_thread,
            ),
        )
        handle = loop.handle
        running = loop.running
        loop.handle = Ptr{LibPipeWire.pw_thread_loop}(C_NULL)
        loop.running = false
        return handle, running
    end
    handle == C_NULL && return nothing

    running && LibPipeWire.pw_thread_loop_stop(handle)
    LibPipeWire.pw_thread_loop_destroy(handle)
    LibPipeWire.pw_deinit()
    return nothing
end

function _retain_source(loop::ThreadLoop)
    return lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.source_count += 1
        return LibPipeWire.pw_thread_loop_get_loop(handle)
    end
end

function _register_source(loop::ThreadLoop, source)
    return lock(loop.state_lock) do
        loop.source_roots[source] = nothing
        return nothing
    end
end

function _cancel_source(loop::ThreadLoop)
    return lock(loop.state_lock) do
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _release_source(loop::ThreadLoop, source)
    return lock(loop.state_lock) do
        delete!(loop.source_roots, source)
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _with_loop_lock(f, loop::ThreadLoop)
    return with_thread_loop_lock(loop) do locked_loop
        handle = _require_open(locked_loop)
        return f(LibPipeWire.pw_thread_loop_get_loop(handle))
    end
end

function _retain_context(loop::ThreadLoop)
    return lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.context_count += 1
        return LibPipeWire.pw_thread_loop_get_loop(handle)
    end
end

function _release_context(loop::ThreadLoop)
    return lock(loop.state_lock) do
        loop.context_count -= 1
        @assert loop.context_count >= 0
        return nothing
    end
end
