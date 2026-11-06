using PipeWireAO, Test
include("private_core.jl")

function command_test_filter(; remote=nothing)
    format = NdArrayFormat(NdArray.U8, (1,); layout=NdArray.COLUMN_MAJOR,
        rate=SPA.Fraction(10, 1))
    port = NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format;
        schema="org.pipewireao.test.command/1")
    return NdArrayFilter("test.command.endpoint", (port,); remote,
        on_process=(filter, inputs, outputs) -> nothing)
end

function iterate_command_loop(filter)
    native = PipeWireAO.LibPipeWire
    loop = native.pw_ndarray_filter_get_loop(filter.handle)
    GC.@preserve filter begin
        native.pw_loop_enter(loop)
        try
            @test native.pw_loop_iterate(loop, 0) >= 0
        finally
            native.pw_loop_leave(loop)
        end
    end
    return nothing
end

function command_other_thread(action)
    return fetch(Threads.@spawn :default try
        action()
    catch error
        error
    end)
end

@testset "bounded owner command queue and native event dispatch" begin
    filter = command_test_filter()
    received = Tuple{Int,Int}[]
    receiver = command_endpoint(filter, message -> push!(received,
        (message, Threads.threadid())), Int; capacity=2)
    sender = commands(receiver)
    try
        @test sender isa CommandSender{Int}
        @test fieldnames(typeof(sender)) == (:channel, :wake)
        @test fieldnames(typeof(sender.wake)) == (:lock, :loop, :source, :accepting)
        @test isopen(sender) && isopen(receiver)
        @test_throws ArgumentError command_endpoint(filter, identity, Int; capacity=0)
        @test_throws InvalidStateException close(filter)
        @test try_send!(sender, 1) == COMMAND_ACCEPTED
        @test try_send!(sender, 2) == COMMAND_ACCEPTED
        @test try_send!(sender, 3) == COMMAND_FULL
        @test isempty(received)
        GC.gc() # The filter roots the receiver used as native callback userdata.
        iterate_command_loop(filter)
        @test received == [(1, Threads.threadid()), (2, Threads.threadid())]
        @test check_command_error(receiver) === nothing
        # A wake with no queued message must never block in take!.
        native = PipeWireAO.LibPipeWire
        @test native.pw_loop_signal_event(sender.wake.loop, sender.wake.source) == 0
        iterate_command_loop(filter)
        @test length(received) == 2
        @test command_other_thread(() -> close(receiver)) isa InvalidStateException
        @test command_other_thread(() -> command_endpoint(filter, identity, Int)) isa InvalidStateException
        @test command_other_thread(() -> check_command_error(receiver)) isa InvalidStateException
        @test try_send!(sender, 4) == COMMAND_ACCEPTED
        close(receiver) # Pending 4 is discarded, not delivered.
        close(receiver)
        @test !isopen(receiver) && !isopen(sender)
        @test try_send!(sender, 5) == COMMAND_CLOSED
        @test length(received) == 2
    finally
        close(receiver)
        close(filter)
    end
end

@testset "command drain bounds work under reentrant submission" begin
    filter = command_test_filter()
    received = Int[]
    sender_ref = Ref{CommandSender{Int}}()
    receiver = command_endpoint(filter, message -> begin
        push!(received, message)
        message <= 2 && @test try_send!(sender_ref[], message + 10) == COMMAND_ACCEPTED
        nothing
    end, Int; capacity=2)
    sender_ref[] = commands(receiver)
    try
        @test try_send!(sender_ref[], 1) == COMMAND_ACCEPTED
        @test try_send!(sender_ref[], 2) == COMMAND_ACCEPTED
        iterate_command_loop(filter)
        @test received == [1, 2]
        iterate_command_loop(filter)
        @test received == [1, 2, 11, 12]
    finally
        close(receiver)
        close(filter)
    end
end

@testset "sender and owner close serialize native source lifetime" begin
    filter = command_test_filter()
    receiver = command_endpoint(filter, identity, Int; capacity=4)
    sender = commands(receiver)
    started = Channel{Nothing}(1)
    sender_task = Threads.@spawn :default begin
        statuses = CommandSendStatus[try_send!(sender, 1)]
        put!(started, nothing)
        for value in 2:10_000
            status = try_send!(sender, value)
            push!(statuses, status)
            status == COMMAND_CLOSED && break
            yield()
        end
        statuses
    end
    try
        take!(started)
        close(receiver)
        statuses = fetch(sender_task)
        @test !isempty(statuses)
        @test first(statuses) == COMMAND_ACCEPTED
        @test all(status -> status in (COMMAND_ACCEPTED, COMMAND_FULL, COMMAND_CLOSED), statuses)
        @test try_send!(sender, 0) == COMMAND_CLOSED
        @test sender.wake.source == C_NULL
        @test sender.wake.loop == C_NULL
    finally
        close(receiver)
        close(filter)
        wait(sender_task)
    end
end

@testset "nothing is a command payload" begin
    filter = command_test_filter()
    count = Ref(0)
    receiver = command_endpoint(filter, _ -> (count[] += 1), Nothing)
    try
        @test try_send!(commands(receiver), nothing) == COMMAND_ACCEPTED
        iterate_command_loop(filter)
        @test count[] == 1
    finally
        close(receiver)
        close(filter)
    end
end

# The watchdog uses the existing cross-thread quit! API only as a bounded test
# escape. The normal sender below holds no filter or callback reference.
function wait_command_condition(condition)
    deadline = time_ns() + UInt64(10_000_000_000)
    while !condition()
        time_ns() >= deadline && return false
        # These tests intentionally block the interactive thread in native run!.
        # Julia Timer/timedwait requires its libuv poller; use a native sleep.
        @ccall gc_safe=true usleep(1000::Cuint)::Cint
        yield()
    end
    return true
end

function run_commands_with_deadline(filter)
    done = Threads.Atomic{Bool}(false)
    watchdog = Threads.@spawn :default begin
        expired = !wait_command_condition(() -> done[])
        expired && quit!(filter)
        expired
    end
    try
        run!(filter)
    finally
        done[] = true
        @test !fetch(watchdog)
    end
end

@testset "commands wake a blocking native filter owner" begin
    with_array_exchange_private_core() do remote
        filter = command_test_filter(; remote)
        received = Tuple{Int,Int}[]
        receiver = command_endpoint(filter, message -> begin
            push!(received, (message, Threads.threadid()))
            @test isrunning(filter)
            @test_throws InvalidStateException close(receiver_ref[])
            quit!(filter)
        end, Int)
        receiver_ref = Ref(receiver)
        sender = commands(receiver)
        try
            connect!(filter)
            # Enqueue before native run begins: its initial poll must observe it.
            @test try_send!(sender, 7) == COMMAND_ACCEPTED
            run_commands_with_deadline(filter)
            @test received == [(7, Threads.threadid())]
        finally
            close(receiver)
            close(filter)
        end

        filter = command_test_filter(; remote)
        entered = Threads.Atomic{Bool}(false)
        received = Tuple{Int,Int}[]
        receiver = command_endpoint(filter, message -> begin
            @test isrunning(filter)
            if message == 0
                entered[] = true
                return nothing
            end
            push!(received, (message, Threads.threadid()))
            quit!(filter)
        end, Int)
        sender = commands(receiver)
        # Unlike the watchdog, this producer has only the sender capability.
        producer = Threads.@spawn :default begin
            @test wait_command_condition(() -> entered[])
            try_send!(sender, 8)
        end
        try
            connect!(filter)
            @test try_send!(sender, 0) == COMMAND_ACCEPTED
            run_commands_with_deadline(filter)
            @test fetch(producer) == COMMAND_ACCEPTED
            @test received == [(8, Threads.threadid())]
        finally
            close(receiver)
            close(filter)
            wait(producer)
        end
    end
end

@testset "command callback exceptions stop and surface from native run" begin
    with_array_exchange_private_core() do remote
        filter = command_test_filter(; remote)
        failure = ErrorException("command callback failure")
        receiver = command_endpoint(filter, _ -> throw(failure), Int)
        sender = commands(receiver)
        try
            connect!(filter)
            @test try_send!(sender, 1) == COMMAND_ACCEPTED
            caught = try
                run_commands_with_deadline(filter)
                nothing
            catch error
                error
            end
            @test caught === failure
            @test !isrunning(filter)
            @test !isopen(sender)
            @test try_send!(sender, 2) == COMMAND_CLOSED
            @test_throws failure check_command_error(receiver)
        finally
            close(receiver)
            close(filter)
        end
    end
end
