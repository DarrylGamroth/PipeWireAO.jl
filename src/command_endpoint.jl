"The result of a bounded [`try_send!`](@ref) command submission."
@enum CommandSendStatus::UInt8 COMMAND_ACCEPTED COMMAND_FULL COMMAND_CLOSED

# This shared transport contains no Julia receiver, filter, or callback reference.
# Its lock serializes native signal calls with owner-thread source destruction.
mutable struct _CommandWake
    lock::ReentrantLock
    loop::Ptr{LibPipeWire.pw_loop}
    source::Ptr{LibPipeWire.spa_source}
    accepting::Bool
end

"""
    CommandSender{T}

A bounded command sender safe to share with other Julia threads. It retains only
a typed channel and synchronized native wake transport. Obtain it with
[`commands`](@ref); submit messages with [`try_send!`](@ref).
"""
struct CommandSender{T}
    channel::Channel{T}
    wake::_CommandWake
end

"""
    CommandReceiver

Owner-thread endpoint returned by [`command_endpoint`](@ref). The filter roots
its receivers until explicit `close(receiver)`. Keep this object, its callback,
and its filter on the constructing Julia thread; share only [`commands`](@ref).
"""
# Mutable identity supplies stable userdata storage for the native C callback.
mutable struct CommandReceiver{T,Filter<:NdArrayFilter,Callback} <: AbstractCommandReceiver
    sender::CommandSender{T}
    filter::Filter
    callback::Callback
    capacity::Int
    callback_error::Base.RefValue{Any}
end

"""
    command_endpoint(filter::NdArrayFilter, callback, ::Type{T}; capacity=1)

Create a bounded command receiver on the thread that constructed `filter`,
before `run!`. Each accepted message invokes `callback(message)` on that same
thread through the filter's native main-loop event source, including while
`run!` blocks. Messages sent before `run!` remain queued and wake its first
iteration. Each native dispatch drains at most `capacity` messages without
waiting for a channel item. Event counts do not prescribe queue reads.

The filter retains the receiver and callback during `run!`. Callback exceptions
are contained at the C boundary, seal the sender, stop the native loop, and are
rethrown by `run!` and [`check_command_error`](@ref). Close the receiver on its
owner thread after `run!` returns and before closing the filter. Closing discards
pending messages; acceptance confirms enqueueing, not execution or completion.

Requires a native SDK exporting `pw_ndarray_filter_get_loop`.
"""
function command_endpoint(
    filter::NdArrayFilter,
    callback,
    ::Type{T};
    capacity::Integer=1,
) where {T}
    0 < capacity <= typemax(Int) ||
        throw(ArgumentError("command capacity must be a positive Int"))
    return lock(filter.state_lock) do
        _require_owner_thread(filter, "command_endpoint")
        filter.running && throw(InvalidStateException(
            "create command receivers before running their ndarray filter", :running,
        ))
        loop = LibPipeWire.pw_ndarray_filter_get_loop(_require_open(filter))
        loop == C_NULL && throw(InvalidStateException(
            "the ndarray filter has no native owner loop", :unavailable,
        ))
        wake = _CommandWake(ReentrantLock(), loop, C_NULL, true)
        sender = CommandSender(Channel{T}(Int(capacity)), wake)
        receiver = CommandReceiver(sender, filter, callback, Int(capacity), Ref{Any}(nothing))
        callback_pointer = _command_event_callback(receiver)
        handle = GC.@preserve receiver LibPipeWire.pw_loop_add_event(
            loop, callback_pointer, pointer_from_objref(receiver),
        )
        if handle == C_NULL
            close(sender.channel)
            throw(PipeWireError(:pw_loop_add_event, -Base.Libc.errno()))
        end
        wake.source = handle
        filter.command_receivers[receiver] = nothing
        return receiver
    end
end

"Return the shareable typed sender for an owner-thread command receiver."
commands(receiver::CommandReceiver) = receiver.sender

"""
    try_send!(sender::CommandSender{T}, message::T) -> CommandSendStatus

Enqueue and wake the native owner loop, returning `COMMAND_ACCEPTED`,
`COMMAND_FULL`, or `COMMAND_CLOSED`. This operation never waits for channel
capacity or command execution. A short transport lock orders concurrent senders
with close. A native wake failure seals the endpoint and throws `PipeWireError`.
"""
function try_send!(sender::CommandSender{T}, message::T) where {T}
    return lock(sender.wake.lock) do
        sender.wake.accepting || return COMMAND_CLOSED
        accepted = lock(sender.channel) do
            isopen(sender.channel) || return COMMAND_CLOSED
            Base.isfull(sender.channel) && return COMMAND_FULL
            put!(sender.channel, message)
            return COMMAND_ACCEPTED
        end
        accepted == COMMAND_ACCEPTED || return accepted
        result = LibPipeWire.pw_loop_signal_event(sender.wake.loop, sender.wake.source)
        if result < 0
            sender.wake.accepting = false
            close(sender.channel)
            throw(PipeWireError(:pw_loop_signal_event, result))
        end
        return COMMAND_ACCEPTED
    end
end

Base.isopen(sender::CommandSender) = lock(sender.wake.lock) do
    sender.wake.accepting
end

Base.isopen(receiver::CommandReceiver) = lock(receiver.sender.wake.lock) do
    receiver.sender.wake.source != C_NULL
end

function _take_command(receiver::CommandReceiver)
    sender = receiver.sender
    return lock(sender.wake.lock) do
        sender.wake.accepting || return nothing
        lock(sender.channel) do
            isready(sender.channel) || return nothing
            return Some(take!(sender.channel))
        end
    end
end

function _command_event_dispatch(receiver::R, ::UInt64)::Cvoid where {R<:CommandReceiver}
    try
        _require_owner_thread(receiver.filter, "command callback")
        for _ in 1:receiver.capacity
            item = _take_command(receiver)
            item === nothing && break
            receiver.callback(something(item))
        end
    catch error
        # No exception, including an error during failure handling, may cross C.
        try
            lock(receiver.sender.wake.lock) do
                receiver.callback_error[] === nothing && (receiver.callback_error[] = error)
                receiver.sender.wake.accepting = false
                close(receiver.sender.channel)
            end
            _record_ndarray_filter_callback_error(receiver.filter, error)
            quit!(receiver.filter)
        catch
            # The first callback error remains available to the owner.
        end
    end
    return nothing
end

function _command_event_callback(::R) where {R<:CommandReceiver}
    return @cfunction(_command_event_dispatch, Cvoid, (Ref{R}, UInt64))
end

"Rethrow the receiver's first contained callback exception, if any."
function check_command_error(receiver::CommandReceiver)
    _require_owner_thread(receiver.filter, "check_command_error")
    error = lock(receiver.sender.wake.lock) do
        receiver.callback_error[]
    end
    error === nothing || throw(error)
    return nothing
end

"""
    close(receiver::CommandReceiver)

Seal all senders, discard queued commands, and destroy the native event source.
Call on the constructing thread while the filter is stopped. Idempotent;
concurrent sends return accepted before sealing or closed after sealing.
"""
function Base.close(receiver::CommandReceiver)
    filter = receiver.filter
    return lock(filter.state_lock) do
        _require_owner_thread(filter, "close command receiver")
        filter.running && throw(InvalidStateException(
            "close command receivers after their ndarray filter stops", :running,
        ))
        sender = receiver.sender
        lock(sender.wake.lock) do
            sender.wake.source == C_NULL && return nothing
            sender.wake.accepting = false
            close(sender.channel)
            while isready(sender.channel)
                take!(sender.channel)
            end
            LibPipeWire.pw_loop_destroy_source(sender.wake.loop, sender.wake.source)
            sender.wake.source = C_NULL
            sender.wake.loop = C_NULL
        end
        delete!(filter.command_receivers, receiver)
        return nothing
    end
end
