"""
    PipeWireError

An error code returned by the PipeWire C API. PipeWire reports failures as
negative `errno` values; `code` preserves that original value.
"""
struct PipeWireError <: Exception
    operation::Symbol
    code::Cint
    detail::Union{Nothing,String}
end

PipeWireError(operation::Symbol, code::Cint) = PipeWireError(operation, code, nothing)

function Base.showerror(io::IO, error::PipeWireError)
    message = if error.detail !== nothing
        error.detail
    elseif error.code < 0
        Base.Libc.strerror(-error.code)
    else
        "unknown error"
    end
    return print(io, error.operation, " failed: ", message, " (", error.code, ')')
end

function _check_result(operation::Symbol, result::Cint)
    result < 0 && throw(PipeWireError(operation, result))
    return result
end

abstract type AbstractPipeWireLoop end

"""
    MainLoop()

Create an owning PipeWire main loop. Call [`close`](@ref) when it is no longer
needed, or use [`with_main_loop`](@ref) for scoped ownership.
"""

mutable struct MainLoop <: AbstractPipeWireLoop
    handle::Ptr{LibPipeWire.pw_main_loop}
    state_lock::ReentrantLock
    running::Bool
    context_count::Int
    source_count::Int
    source_roots::IdDict{Any,Nothing}

    function MainLoop()
        LibPipeWire.pw_init(C_NULL, C_NULL)
        handle = LibPipeWire.pw_main_loop_new(C_NULL)
        if handle == C_NULL
            errno = Base.Libc.errno()
            LibPipeWire.pw_deinit()
            throw(PipeWireError(:pw_main_loop_new, -errno))
        end

        loop = new(handle, ReentrantLock(), false, 0, 0, IdDict{Any,Nothing}())
        finalizer(close, loop)
        return loop
    end
end

function _require_open(loop::MainLoop)
    loop.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire main loop is closed", :closed))
    return loop.handle
end

"""
    isopen(loop::MainLoop) -> Bool

Return whether `loop` still owns a native PipeWire main loop.
"""
function Base.isopen(loop::MainLoop)
    return lock(loop.state_lock) do
        loop.handle != C_NULL
    end
end

"""
    close(loop::MainLoop)

Destroy the native main loop and release its PipeWire initialization reference.
This operation is idempotent. A running loop must first be stopped with
[`quit!`](@ref).
"""
function Base.close(loop::MainLoop)
    return lock(loop.state_lock) do
        loop.handle == C_NULL && return nothing
        loop.running && throw(
            InvalidStateException(
                "cannot close a running PipeWire main loop; call quit! first",
                :running,
            ),
        )
        loop.context_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire main loop while contexts are open",
                :open_contexts,
            ),
        )
        loop.source_count == 0 || throw(
            InvalidStateException(
                "cannot close a PipeWire main loop while loop sources are open",
                :open_sources,
            ),
        )

        handle = loop.handle
        loop.handle = Ptr{LibPipeWire.pw_main_loop}(C_NULL)
        LibPipeWire.pw_main_loop_destroy(handle)
        LibPipeWire.pw_deinit()
        return nothing
    end
end

function _retain_source(loop::MainLoop)
    return lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.running && throw(
            InvalidStateException(
                "create loop sources before running a PipeWire main loop",
                :running,
            ),
        )
        loop.source_count += 1
        return LibPipeWire.pw_main_loop_get_loop(handle)
    end
end

function _register_source(loop::MainLoop, source)
    return lock(loop.state_lock) do
        loop.source_roots[source] = nothing
        return nothing
    end
end

function _cancel_source(loop::MainLoop)
    return lock(loop.state_lock) do
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _release_source(loop::MainLoop, source)
    return lock(loop.state_lock) do
        delete!(loop.source_roots, source)
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _with_loop_lock(f, loop::MainLoop)
    return lock(loop.state_lock) do
        loop.running && throw(
            InvalidStateException(
                "modify loop sources only while a PipeWire main loop is stopped",
                :running,
            ),
        )
        handle = _require_open(loop)
        return f(LibPipeWire.pw_main_loop_get_loop(handle))
    end
end

function _retain_context(loop::MainLoop)
    return lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.context_count += 1
        return LibPipeWire.pw_main_loop_get_loop(handle)
    end
end

function _release_context(loop::MainLoop)
    return lock(loop.state_lock) do
        loop.context_count -= 1
        @assert loop.context_count >= 0
        return nothing
    end
end

"""
    run!(loop::MainLoop)

Run `loop` until another task or thread calls [`quit!`](@ref). This call blocks
the calling Julia thread while permitting GC. Use [`roundtrip`](@ref) for
finite client operations.
"""
function run!(loop::MainLoop)
    handle = lock(loop.state_lock) do
        handle = _require_open(loop)
        loop.running &&
            throw(InvalidStateException("the PipeWire main loop is already running", :running))
        loop.running = true
        return handle
    end

    result = try
        @ccall gc_safe=true LibPipeWire.libpipewire_ao.pw_main_loop_run(
            handle::Ptr{LibPipeWire.pw_main_loop}
        )::Cint
    finally
        lock(loop.state_lock) do
            loop.running = false
        end
    end

    _check_result(:pw_main_loop_run, result)
    return nothing
end

"""
    quit!(loop::MainLoop)

Request that a running main loop stop. It is safe to call this from a different
task or thread than [`run!`](@ref).
"""
function quit!(loop::MainLoop)
    result = lock(loop.state_lock) do
        LibPipeWire.pw_main_loop_quit(_require_open(loop))
    end
    _check_result(:pw_main_loop_quit, result)
    return nothing
end

"""
    with_main_loop(f)

Create a [`MainLoop`](@ref), call `f(loop)`, and close the loop even if `f`
throws.
"""
function with_main_loop(f)
    loop = MainLoop()
    try
        return f(loop)
    finally
        close(loop)
    end
end
