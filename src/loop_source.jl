"Notify when a file descriptor can be read."
const LOOP_IO_IN = UInt32(1 << 0)
"Notify when a file descriptor can be written."
const LOOP_IO_OUT = UInt32(1 << 2)
"Notify when a file descriptor reports an error."
const LOOP_IO_ERR = UInt32(1 << 3)
"Notify when a file descriptor reports a hangup."
const LOOP_IO_HUP = UInt32(1 << 4)

abstract type AbstractLoopSource end

function _loop_cint(value::Integer, description::AbstractString)
    typemin(Cint) <= value <= typemax(Cint) ||
        throw(ArgumentError("$description is outside Cint range"))
    return Cint(value)
end

function _loop_uint32(value::Integer, description::AbstractString)
    0 <= value <= typemax(UInt32) ||
        throw(ArgumentError("$description is outside UInt32 range"))
    return UInt32(value)
end

mutable struct EventSource{LoopType<:AbstractPipeWireLoop,Callback} <: AbstractLoopSource
    handle::Ptr{LibPipeWire.spa_source}
    loop::LoopType
    state_lock::ReentrantLock
    callback::Callback
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
end

mutable struct TimerSource{LoopType<:AbstractPipeWireLoop,Callback} <: AbstractLoopSource
    handle::Ptr{LibPipeWire.spa_source}
    loop::LoopType
    state_lock::ReentrantLock
    callback::Callback
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
end

mutable struct IdleSource{LoopType<:AbstractPipeWireLoop,Callback} <: AbstractLoopSource
    handle::Ptr{LibPipeWire.spa_source}
    loop::LoopType
    state_lock::ReentrantLock
    callback::Callback
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
end

mutable struct IOSource{LoopType<:AbstractPipeWireLoop,Callback} <: AbstractLoopSource
    handle::Ptr{LibPipeWire.spa_source}
    loop::LoopType
    state_lock::ReentrantLock
    callback::Callback
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
end

mutable struct SignalSource{LoopType<:AbstractPipeWireLoop,Callback} <: AbstractLoopSource
    handle::Ptr{LibPipeWire.spa_source}
    loop::LoopType
    state_lock::ReentrantLock
    callback::Callback
    callback_error::Base.RefValue{Any}
    callbacks_active::Bool
end

function _require_open(source::AbstractLoopSource)
    source.handle == C_NULL &&
        throw(InvalidStateException("the PipeWire loop source is closed", :closed))
    return source.handle
end

function Base.isopen(source::AbstractLoopSource)
    return lock(source.state_lock) do
        source.handle != C_NULL
    end
end

function _record_source_callback_error(source::AbstractLoopSource, error)
    return lock(source.state_lock) do
        source.callback_error[] === nothing && (source.callback_error[] = error)
        return nothing
    end
end

function _check_source_callback_error(source::AbstractLoopSource)
    error = lock(source.state_lock) do
        source.callback_error[]
    end
    error === nothing || throw(error)
    return nothing
end

function _invoke_source_callback(source::T, args...) where {T<:AbstractLoopSource}
    callback = lock(source.state_lock) do
        source.callbacks_active ? source.callback : nothing
    end
    callback === nothing && return nothing
    try
        callback(source, args...)
    catch error
        _record_source_callback_error(source, error)
    end
    return nothing
end

function _event_source_dispatch(source::T, count::UInt64)::Cvoid where {T<:EventSource}
    _invoke_source_callback(source, count)
    return nothing
end

function _timer_source_dispatch(source::T, count::UInt64)::Cvoid where {T<:TimerSource}
    _invoke_source_callback(source, count)
    return nothing
end

function _idle_source_dispatch(source::T)::Cvoid where {T<:IdleSource}
    _invoke_source_callback(source)
    return nothing
end

function _io_source_dispatch(
    source::T,
    fd::Cint,
    mask::UInt32,
)::Cvoid where {T<:IOSource}
    _invoke_source_callback(source, fd, mask)
    return nothing
end

function _signal_source_dispatch(source::T, signal_number::Cint)::Cvoid where {T<:SignalSource}
    _invoke_source_callback(source, signal_number)
    return nothing
end

function _event_source_callback(::T) where {T<:EventSource}
    return @cfunction(_event_source_dispatch, Cvoid, (Ref{T}, UInt64))
end

function _timer_source_callback(::T) where {T<:TimerSource}
    return @cfunction(_timer_source_dispatch, Cvoid, (Ref{T}, UInt64))
end

function _idle_source_callback(::T) where {T<:IdleSource}
    return @cfunction(_idle_source_dispatch, Cvoid, (Ref{T},))
end

function _io_source_callback(::T) where {T<:IOSource}
    return @cfunction(_io_source_dispatch, Cvoid, (Ref{T}, Cint, UInt32))
end

function _signal_source_callback(::T) where {T<:SignalSource}
    return @cfunction(_signal_source_dispatch, Cvoid, (Ref{T}, Cint))
end

function _finish_source_construction(source::AbstractLoopSource, handle)
    if handle == C_NULL
        _cancel_source(source.loop)
        throw(PipeWireError(:pw_loop_add_source, -Base.Libc.errno()))
    end
    source.handle = handle
    _register_source(source.loop, source)
    finalizer(close, source)
    return source
end

"""
    EventSource(loop, callback)

Create an owned event source. `callback(source, count)` runs in the PipeWire
loop context after [`signal!`](@ref) wakes the source. The callback type is part
of the concrete source type and its C trampoline receives an exact `Ref{T}`.
"""
function EventSource(loop::AbstractPipeWireLoop, callback)
    _retain_source(loop)
    source = EventSource(
        Ptr{LibPipeWire.spa_source}(C_NULL),
        loop,
        ReentrantLock(),
        callback,
        Ref{Any}(nothing),
        true,
    )
    handle = try
        callback_pointer = _event_source_callback(source)
        _with_loop_lock(loop) do native_loop
            GC.@preserve source LibPipeWire.pw_loop_add_event(
                native_loop,
                callback_pointer,
                pointer_from_objref(source),
            )
        end
    catch
        _cancel_source(loop)
        rethrow()
    end
    return _finish_source_construction(source, handle)
end

"""
    TimerSource(loop, callback; delay=nothing, interval=0, absolute=false)

Create an owned timer source. `callback(source, expirations)` runs when the
timer expires. A `delay` of `nothing` leaves the timer disarmed.
"""
function TimerSource(
    loop::AbstractPipeWireLoop,
    callback;
    delay::Union{Nothing,Real}=nothing,
    interval::Real=0,
    absolute::Bool=false,
)
    _retain_source(loop)
    source = TimerSource(
        Ptr{LibPipeWire.spa_source}(C_NULL),
        loop,
        ReentrantLock(),
        callback,
        Ref{Any}(nothing),
        true,
    )
    handle = try
        callback_pointer = _timer_source_callback(source)
        _with_loop_lock(loop) do native_loop
            GC.@preserve source LibPipeWire.pw_loop_add_timer(
                native_loop,
                callback_pointer,
                pointer_from_objref(source),
            )
        end
    catch
        _cancel_source(loop)
        rethrow()
    end
    _finish_source_construction(source, handle)
    try
        update_timer!(source; delay, interval, absolute)
    catch
        close(source)
        rethrow()
    end
    return source
end

"""
    IdleSource(loop, callback; enabled=true)

Create an owned idle source. `callback(source)` runs whenever the loop has no
higher-priority work while the source is enabled.
"""
function IdleSource(loop::AbstractPipeWireLoop, callback; enabled::Bool=true)
    _retain_source(loop)
    source = IdleSource(
        Ptr{LibPipeWire.spa_source}(C_NULL),
        loop,
        ReentrantLock(),
        callback,
        Ref{Any}(nothing),
        true,
    )
    handle = try
        callback_pointer = _idle_source_callback(source)
        _with_loop_lock(loop) do native_loop
            GC.@preserve source LibPipeWire.pw_loop_add_idle(
                native_loop,
                enabled,
                callback_pointer,
                pointer_from_objref(source),
            )
        end
    catch
        _cancel_source(loop)
        rethrow()
    end
    return _finish_source_construction(source, handle)
end

"""
    IOSource(loop, fd, mask, callback; close_fd=false)

Create an owned file-descriptor source. `callback(source, fd, mask)` runs for
the selected `LOOP_IO_*` conditions. When `close_fd` is true, PipeWire closes
the descriptor when the source is destroyed.
"""
function IOSource(
    loop::AbstractPipeWireLoop,
    fd::Integer,
    mask::Integer,
    callback;
    close_fd::Bool=false,
)
    native_fd = _loop_cint(fd, "file descriptor")
    native_mask = _loop_uint32(mask, "I/O mask")
    _retain_source(loop)
    source = IOSource(
        Ptr{LibPipeWire.spa_source}(C_NULL),
        loop,
        ReentrantLock(),
        callback,
        Ref{Any}(nothing),
        true,
    )
    handle = try
        callback_pointer = _io_source_callback(source)
        _with_loop_lock(loop) do native_loop
            GC.@preserve source LibPipeWire.pw_loop_add_io(
                native_loop,
                native_fd,
                native_mask,
                close_fd,
                callback_pointer,
                pointer_from_objref(source),
            )
        end
    catch
        _cancel_source(loop)
        rethrow()
    end
    return _finish_source_construction(source, handle)
end

"""
    SignalSource(loop, signal_number, callback)

Create an owned Unix signal source. `callback(source, signal_number)` runs in
the loop context. Signal sources are not supported on Windows.
"""
function SignalSource(loop::AbstractPipeWireLoop, signal_number::Integer, callback)
    native_signal = _loop_cint(signal_number, "signal number")
    _retain_source(loop)
    source = SignalSource(
        Ptr{LibPipeWire.spa_source}(C_NULL),
        loop,
        ReentrantLock(),
        callback,
        Ref{Any}(nothing),
        true,
    )
    handle = try
        callback_pointer = _signal_source_callback(source)
        _with_loop_lock(loop) do native_loop
            GC.@preserve source LibPipeWire.pw_loop_add_signal(
                native_loop,
                native_signal,
                callback_pointer,
                pointer_from_objref(source),
            )
        end
    catch
        _cancel_source(loop)
        rethrow()
    end
    return _finish_source_construction(source, handle)
end

function Base.close(source::AbstractLoopSource)
    already_closed = lock(source.state_lock) do
        source.handle == C_NULL
    end
    already_closed && return nothing
    destroyed = _with_loop_lock(source.loop) do native_loop
        return lock(source.state_lock) do
            source.handle == C_NULL && return false
            LibPipeWire.pw_loop_destroy_source(native_loop, source.handle)
            source.handle = Ptr{LibPipeWire.spa_source}(C_NULL)
            source.callbacks_active = false
            return true
        end
    end
    destroyed && _release_source(source.loop, source)
    return nothing
end

"Wake an event source. Calls from any thread are supported by PipeWireAO."
function signal!(source::EventSource)
    _check_source_callback_error(source)
    result = _signal_event(source.loop, source)
    _check_result(:pw_loop_signal_event, result)
    return source
end

function _signal_event(loop::MainLoop, source::EventSource)
    return lock(loop.state_lock) do
        native_loop = LibPipeWire.pw_main_loop_get_loop(_require_open(loop))
        handle = lock(source.state_lock) do
            _require_open(source)
        end
        return LibPipeWire.pw_loop_signal_event(native_loop, handle)
    end
end

function _signal_event(loop::ThreadLoop, source::EventSource)
    return _with_loop_lock(loop) do native_loop
        handle = lock(source.state_lock) do
            _require_open(source)
        end
        return LibPipeWire.pw_loop_signal_event(native_loop, handle)
    end
end

"Enable or disable an idle source."
function enable!(source::IdleSource, enabled::Bool=true)
    _check_source_callback_error(source)
    result = _with_loop_lock(source.loop) do native_loop
        LibPipeWire.pw_loop_enable_idle(native_loop, _require_open(source), enabled)
    end
    _check_result(:pw_loop_enable_idle, result)
    return source
end

"Change the conditions monitored by an I/O source."
function update_io!(source::IOSource, mask::Integer)
    _check_source_callback_error(source)
    native_mask = _loop_uint32(mask, "I/O mask")
    result = _with_loop_lock(source.loop) do native_loop
        LibPipeWire.pw_loop_update_io(native_loop, _require_open(source), native_mask)
    end
    _check_result(:pw_loop_update_io, result)
    return source
end

function _timespec(seconds::Real, description::AbstractString)
    value = Float64(seconds)
    isfinite(value) || throw(ArgumentError("$description must be finite"))
    value >= 0 || throw(ArgumentError("$description must be nonnegative"))
    whole = floor(Int64, value)
    nanoseconds = round(Int64, (value - whole) * 1_000_000_000)
    if nanoseconds == 1_000_000_000
        whole += 1
        nanoseconds = 0
    end
    return LibPipeWire.timespec(whole, nanoseconds)
end

"""
    update_timer!(source; delay, interval=0, absolute=false)

Arm a timer in seconds, or disarm it with `delay=nothing`. Set `absolute=true`
when `delay` is an absolute value in the loop clock rather than a relative
delay.
"""
function update_timer!(
    source::TimerSource;
    delay::Union{Nothing,Real},
    interval::Real=0,
    absolute::Bool=false,
)
    _check_source_callback_error(source)
    interval_value = _timespec(interval, "timer interval")
    result = if delay === nothing
        _with_loop_lock(source.loop) do native_loop
            LibPipeWire.pw_loop_update_timer(
                native_loop,
                _require_open(source),
                C_NULL,
                C_NULL,
                false,
            )
        end
    else
        delay_value = _timespec(delay, "timer delay")
        _with_loop_lock(source.loop) do native_loop
            GC.@preserve delay_value interval_value LibPipeWire.pw_loop_update_timer(
                native_loop,
                _require_open(source),
                Ref(delay_value),
                Ref(interval_value),
                absolute,
            )
        end
    end
    _check_result(:pw_loop_update_timer, result)
    return source
end
