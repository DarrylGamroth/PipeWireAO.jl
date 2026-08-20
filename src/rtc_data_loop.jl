@enum RTCIdle::UInt32 begin
    RTC_BUSY_SPIN = LibPipeWire.PW_RTC_DATA_LOOP_IDLE_BUSY_SPIN
    RTC_EVENTFD = LibPipeWire.PW_RTC_DATA_LOOP_IDLE_EVENTFD
    RTC_HYBRID = LibPipeWire.PW_RTC_DATA_LOOP_IDLE_HYBRID
end

@enum RTCScheduler::UInt32 begin
    RTC_SCHED_OTHER = LibPipeWire.PW_RTC_DATA_LOOP_SCHED_OTHER
    RTC_SCHED_FIFO = LibPipeWire.PW_RTC_DATA_LOOP_SCHED_FIFO
end

function _rtc_data_loop_config(
    idle::RTCIdle,
    scheduler::RTCScheduler,
    priority,
    hybrid_spin_iterations::Integer,
)
    native_priority = if priority === nothing
        scheduler == RTC_SCHED_FIFO ? Cint(-1) : Cint(0)
    else
        typemin(Cint) <= priority <= typemax(Cint) || throw(
            ArgumentError("RTC scheduler priority does not fit in Cint"),
        )
        Cint(priority)
    end
    if scheduler == RTC_SCHED_OTHER
        native_priority == 0 || throw(
            ArgumentError("RTC_SCHED_OTHER requires priority 0"),
        )
    else
        (native_priority == -1 || native_priority > 0) || throw(
            ArgumentError("RTC_SCHED_FIFO requires priority -1 or a positive value"),
        )
    end

    0 <= hybrid_spin_iterations <= typemax(UInt32) || throw(
        ArgumentError("hybrid_spin_iterations does not fit in UInt32"),
    )
    native_iterations = idle == RTC_HYBRID ? UInt32(hybrid_spin_iterations) : UInt32(0)
    idle != RTC_HYBRID || native_iterations > 0 || throw(
        ArgumentError("RTC_HYBRID requires at least one spin iteration"),
    )

    return LibPipeWire.pw_rtc_data_loop_config(
        UInt32(0),
        UInt32(idle),
        UInt32(scheduler),
        native_priority,
        native_iterations,
    )
end

"""
    RTCDataLoop(context, process; idle=RTC_BUSY_SPIN,
                scheduler=RTC_SCHED_OTHER, priority=nothing,
                hybrid_spin_iterations=0, properties=nothing)

Create an owning PipeWireAO RTC data loop. `process()` performs one bounded
duty cycle and must return a value representable as `Cint`: positive after
doing work, zero when idle, or a negative errno-style result to terminate.

The native C loop owns thread creation, affinity, scheduling, idle behavior,
and joining. The Julia object only roots `process` and guards its ownership
state. As with the C API, callers must serialize start, stop, and close
operations. The context main loop must run separately for protocol,
negotiation, topology, and other control events.

A Julia callback is not automatically real-time safe. Strict use requires
precompiled, allocation-free callback code and a deployment that excludes GC
from the RTC duty cycle. A native C or Rust callback can instead use the raw
[`LibPipeWire`](@ref) API.
"""
mutable struct RTCDataLoop{ContextType<:Context,ProcessType} <: AbstractPipeWireLoop
    handle::Ptr{LibPipeWire.pw_rtc_data_loop}
    context::ContextType
    state_lock::ReentrantLock
    process::ProcessType
    source_count::Int
    source_roots::IdDict{Any,Nothing}
end

@inline function _rtc_process(loop::RTCDataLoop)::Cint
    try
        return Cint(loop.process())
    catch
        return -Cint(Base.Libc.EFAULT)
    end
end

function _rtc_process_pointer(::T) where {T<:RTCDataLoop}
    return @cfunction(_rtc_process, Cint, (Ref{T},))
end

function RTCDataLoop(
    context::Context,
    process;
    idle::RTCIdle=RTC_BUSY_SPIN,
    scheduler::RTCScheduler=RTC_SCHED_OTHER,
    priority=nothing,
    hybrid_spin_iterations::Integer=0,
    properties=nothing,
)
    config = Ref(
        _rtc_data_loop_config(idle, scheduler, priority, hybrid_spin_iterations),
    )
    context_handle = _retain_rtc_data_loop(context)
    loop = RTCDataLoop(
        Ptr{LibPipeWire.pw_rtc_data_loop}(C_NULL),
        context,
        ReentrantLock(),
        process,
        0,
        IdDict{Any,Nothing}(),
    )
    process_pointer = _rtc_process_pointer(loop)
    try
        loop.handle = _with_properties_dict(properties) do dictionary
            GC.@preserve loop config LibPipeWire.pw_rtc_data_loop_new(
                context_handle,
                dictionary,
                Base.unsafe_convert(Ptr{LibPipeWire.pw_rtc_data_loop_config}, config),
                process_pointer,
                pointer_from_objref(loop),
            )
        end
    catch
        _release_rtc_data_loop(context)
        rethrow()
    end
    if loop.handle == C_NULL
        errno = Base.Libc.errno()
        _release_rtc_data_loop(context)
        throw(PipeWireError(:pw_rtc_data_loop_new, -errno))
    end
    finalizer(close, loop)
    return loop
end

function _require_open(loop::RTCDataLoop)
    loop.handle == C_NULL && throw(
        InvalidStateException("the PipeWireAO RTC data loop is closed", :closed),
    )
    return loop.handle
end

function Base.isopen(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        loop.handle != C_NULL
    end
end

"Return whether the native RTC duty-cycle loop is running."
function isrunning(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        loop.handle != C_NULL && LibPipeWire.pw_rtc_data_loop_is_running(loop.handle)
    end
end

"Return whether the caller is the native RTC data-loop thread."
function in_thread(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        LibPipeWire.pw_rtc_data_loop_in_thread(_require_open(loop))
    end
end

"Start the native RTC data loop and return `loop`."
function start!(loop::RTCDataLoop)
    handle = lock(loop.state_lock) do
        _require_open(loop)
    end
    result = LibPipeWire.pw_rtc_data_loop_start(handle)
    _check_result(:pw_rtc_data_loop_start, result)
    return loop
end

"Request native RTC loop exit without joining and return `loop`."
function request_exit!(loop::RTCDataLoop)
    handle = loop.handle
    handle == C_NULL && throw(
        InvalidStateException("the PipeWireAO RTC data loop is closed", :closed),
    )
    LibPipeWire.pw_rtc_data_loop_exit(handle)
    return loop
end

quit!(loop::RTCDataLoop) = request_exit!(loop)

"Stop and join the native RTC data loop and return `loop`."
function stop!(loop::RTCDataLoop)
    handle = lock(loop.state_lock) do
        handle = _require_open(loop)
        LibPipeWire.pw_rtc_data_loop_in_thread(handle) && throw(
            InvalidStateException(
                "the PipeWireAO RTC data loop cannot stop itself",
                :loop_thread,
            ),
        )
        return handle
    end
    result = LibPipeWire.pw_rtc_data_loop_stop(handle)
    _check_result(:pw_rtc_data_loop_stop, result)
    return loop
end

"Return the terminal process or event-loop result without changing lifecycle."
function terminal_result(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        LibPipeWire.pw_rtc_data_loop_get_result(_require_open(loop))
    end
end

function Base.close(loop::RTCDataLoop)
    handle = lock(loop.state_lock) do
        loop.handle == C_NULL && return Ptr{LibPipeWire.pw_rtc_data_loop}(C_NULL)
        loop.source_count == 0 || throw(
            InvalidStateException(
                "cannot close an RTC data loop while loop sources are open",
                :open_sources,
            ),
        )
        LibPipeWire.pw_rtc_data_loop_in_thread(loop.handle) && throw(
            InvalidStateException(
                "the PipeWireAO RTC data loop cannot close itself",
                :loop_thread,
            ),
        )
        return loop.handle
    end
    handle == C_NULL && return nothing

    result = LibPipeWire.pw_rtc_data_loop_stop(handle)
    LibPipeWire.pw_rtc_data_loop_get_thread(handle) == C_NULL ||
        throw(PipeWireError(:pw_rtc_data_loop_stop, result))
    lock(loop.state_lock) do
        loop.handle == handle || throw(
            InvalidStateException("concurrent RTC data-loop lifecycle operation", :race),
        )
        loop.handle = Ptr{LibPipeWire.pw_rtc_data_loop}(C_NULL)
    end
    LibPipeWire.pw_rtc_data_loop_destroy(handle)
    _release_rtc_data_loop(loop.context)
    return nothing
end

function _retain_source(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        handle = _require_open(loop)
        LibPipeWire.pw_rtc_data_loop_get_thread(handle) == C_NULL || throw(
            InvalidStateException(
                "RTC data-loop sources must be installed before the loop starts",
                :loop_started,
            ),
        )
        loop.source_count += 1
        return LibPipeWire.pw_rtc_data_loop_get_loop(handle)
    end
end

function _register_source(loop::RTCDataLoop, source)
    return lock(loop.state_lock) do
        loop.source_roots[source] = nothing
        return nothing
    end
end

function _cancel_source(loop::RTCDataLoop)
    return lock(loop.state_lock) do
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _release_source(loop::RTCDataLoop, source)
    return lock(loop.state_lock) do
        delete!(loop.source_roots, source)
        loop.source_count -= 1
        @assert loop.source_count >= 0
        return nothing
    end
end

function _with_loop_lock(f, loop::RTCDataLoop)
    return lock(loop.state_lock) do
        return f(LibPipeWire.pw_rtc_data_loop_get_loop(_require_open(loop)))
    end
end

function _retain_context(::RTCDataLoop)
    throw(
        ArgumentError(
            "an RTC data loop cannot host a PipeWire context; use its control main loop",
        ),
    )
end
