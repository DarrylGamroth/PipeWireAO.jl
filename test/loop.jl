struct EventCounter
    count::Threads.Atomic{Int}
end

function (callback::EventCounter)(::EventSource, count::UInt64)
    Threads.atomic_add!(callback.count, Int(count))
    return nothing
end

struct IntegerCollector
    total::Threads.Atomic{Int}
end

function (callback::IntegerCollector)(::EventSource, value::Int)
    Threads.atomic_add!(callback.total, value)
    return nothing
end

struct TimerCounter
    count::Threads.Atomic{Int}
end

function (callback::TimerCounter)(::TimerSource, count::UInt64)
    Threads.atomic_add!(callback.count, Int(count))
    return nothing
end

struct SourceFailure end
(::SourceFailure)(::EventSource, ::UInt64) = error("loop source callback failed")

function invoke_idle_source(source::T) where {T<:IdleSource}
    callback = PipeWireAO._idle_source_callback(source)
    ccall(callback, Cvoid, (Ref{T},), source)
    return nothing
end

@testset "managed thread loop" begin
    loop = ThreadLoop("PipeWireAO.jl managed-loop test")
    @test isopen(loop)
    @test !isrunning(loop)
    @test !in_thread(loop)
    @test isconcretetype(typeof(loop))
    @test all(isconcretetype, fieldtypes(typeof(loop)))

    start!(loop)
    @test isrunning(loop)
    @test start!(loop) === loop
    value = with_thread_loop_lock(loop) do locked_loop
        @test locked_loop === loop
        return 42
    end
    @test value == 42
    stop!(loop)
    @test !isrunning(loop)
    @test stop!(loop) === loop

    context = Context(loop)
    core = CoreConnection(context; self=true)
    registry = Registry(core)
    roundtrip(registry)
    @test !isrunning(loop)
    @test !isempty(globals(registry))
    close(registry)
    close(core)
    close(context)
    close(loop)
    @test !isopen(loop)
end

@testset "owned loop sources" begin
    main_loop = MainLoop()
    main_event = EventSource(main_loop, EventCounter(Threads.Atomic{Int}(0)))
    @test isopen(main_event)
    @test isconcretetype(typeof(main_event))
    @test all(isconcretetype, fieldtypes(typeof(main_event)))
    @test_throws InvalidStateException close(main_loop)
    rooted_event = WeakRef(main_event)
    main_event = nothing
    GC.gc(true)
    @test rooted_event.value !== nothing
    main_event = rooted_event.value
    signal!(main_event)
    close(main_event)
    close(main_event)
    close(main_loop)

    loop = ThreadLoop("PipeWireAO.jl source test")
    event_count = Threads.Atomic{Int}(0)
    event = EventSource(loop, EventCounter(event_count))
    idle_count = Ref(0)
    idle = IdleSource(loop, (_source) -> (idle_count[] += 1); enabled=false)
    invoke_idle_source(idle)
    @test idle_count[] == 1
    enable!(idle, false)
    timer_count = Threads.Atomic{Int}(0)
    timer = TimerSource(loop, TimerCounter(timer_count); delay=0.01)

    @test all(isconcretetype, fieldtypes(typeof(event)))
    @test all(isconcretetype, fieldtypes(typeof(idle)))
    @test all(isconcretetype, fieldtypes(typeof(timer)))
    @test_throws ArgumentError update_timer!(timer; delay=-1)
    io_source = IOSource(loop, 0, LOOP_IO_IN, (_source, _fd, _mask) -> nothing)
    @test_throws ArgumentError update_io!(io_source, -1)

    start!(loop)
    signal!(event)
    @test Base.timedwait(() -> event_count[] == 1, 5) === :ok
    @test Base.timedwait(() -> timer_count[] >= 1, 5) === :ok
    update_timer!(timer; delay=nothing)
    stop!(loop)

    close(event)
    close(idle)
    close(timer)
    close(io_source)

    failure = EventSource(loop, SourceFailure())
    start!(loop)
    signal!(failure)
    @test Base.timedwait(
        () -> getfield(failure, :callback_error)[] !== nothing,
        5,
    ) === :ok
    @test_throws ErrorException signal!(failure)
    stop!(loop)
    close(failure)
    close(loop)
end

@testset "typed loop channel" begin
    loop = ThreadLoop("PipeWireAO.jl loop-channel test")
    total = Threads.Atomic{Int}(0)
    channel = LoopChannel{Int}(loop, IntegerCollector(total); capacity=4)
    @test isopen(channel)
    @test isconcretetype(typeof(channel))
    @test all(isconcretetype, fieldtypes(typeof(channel)))
    @test all(isconcretetype, fieldtypes(typeof(getfield(channel, :source))))

    start!(loop)
    @test put!(channel, 2) === channel
    @test put!(channel, 3) === channel
    @test Base.timedwait(() -> total[] == 5, 5) === :ok
    stop!(loop)
    close(channel)
    @test !isopen(channel)
    close(channel)
    close(loop)

    other_loop = ThreadLoop("PipeWireAO.jl loop-channel argument test")
    @test_throws ArgumentError LoopChannel{Int}(other_loop, IntegerCollector(total); capacity=0)
    close(other_loop)
end
