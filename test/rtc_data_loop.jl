@testset "RTC data-loop configuration" begin
    native = PipeWireAO.LibPipeWire

    busy = PipeWireAO._rtc_data_loop_config(
        RTC_BUSY_SPIN,
        RTC_SCHED_OTHER,
        nothing,
        100,
    )
    @test busy.version == 0
    @test busy.idle == native.PW_RTC_DATA_LOOP_IDLE_BUSY_SPIN
    @test busy.scheduler == native.PW_RTC_DATA_LOOP_SCHED_OTHER
    @test busy.priority == 0
    @test busy.hybrid_spin_iterations == 0

    hybrid = PipeWireAO._rtc_data_loop_config(
        RTC_HYBRID,
        RTC_SCHED_FIFO,
        83,
        4096,
    )
    @test hybrid.idle == native.PW_RTC_DATA_LOOP_IDLE_HYBRID
    @test hybrid.scheduler == native.PW_RTC_DATA_LOOP_SCHED_FIFO
    @test hybrid.priority == 83
    @test hybrid.hybrid_spin_iterations == 4096

    @test_throws ArgumentError PipeWireAO._rtc_data_loop_config(
        RTC_HYBRID,
        RTC_SCHED_OTHER,
        nothing,
        0,
    )
    @test_throws ArgumentError PipeWireAO._rtc_data_loop_config(
        RTC_BUSY_SPIN,
        RTC_SCHED_OTHER,
        1,
        0,
    )
    @test_throws ArgumentError PipeWireAO._rtc_data_loop_config(
        RTC_BUSY_SPIN,
        RTC_SCHED_FIFO,
        0,
        0,
    )
end

struct RTCCountProcess
    count::Base.RefValue{Int}
end

function (process::RTCCountProcess)()
    process.count[] += 1
    return Cint(1)
end

struct RTCThrowProcess end
(::RTCThrowProcess)() = error("expected RTC callback failure")

function invoke_rtc_process(pointer::Ptr{Cvoid}, loop::T) where {T<:RTCDataLoop}
    return ccall(pointer, Cint, (Ref{T},), loop)
end

@testset "RTC Julia callback trampoline" begin
    context = Context()
    try
        count = Ref(0)
        loop = RTCDataLoop(
            Ptr{PipeWireAO.LibPipeWire.pw_rtc_data_loop}(C_NULL),
            context,
            ReentrantLock(),
            RTCCountProcess(count),
            0,
            IdDict{Any,Nothing}(),
        )
        pointer = PipeWireAO._rtc_process_pointer(loop)
        @test invoke_rtc_process(pointer, loop) == 1
        @test count[] == 1

        failing = RTCDataLoop(
            Ptr{PipeWireAO.LibPipeWire.pw_rtc_data_loop}(C_NULL),
            context,
            ReentrantLock(),
            RTCThrowProcess(),
            0,
            IdDict{Any,Nothing}(),
        )
        failing_pointer = PipeWireAO._rtc_process_pointer(failing)
        @test invoke_rtc_process(failing_pointer, failing) == -Base.Libc.EFAULT
    finally
        close(context)
    end
end

struct RTCNativeProcess
    count::Threads.Atomic{Int}
end

function (process::RTCNativeProcess)()
    count = Threads.atomic_add!(process.count, 1)
    return count >= 1023 ? -Cint(Base.Libc.ECANCELED) : Cint(1)
end

@testset "managed native RTC data loop" begin
    context = Context()
    process = RTCNativeProcess(Threads.Atomic{Int}(0))
    loop = RTCDataLoop(context, process)
    try
        @test start!(loop) === loop
        deadline = time() + 5
        while isrunning(loop) && time() < deadline
            sleep(0.001)
        end
        @test !isrunning(loop)
        @test process.count[] >= 1024
        @test terminal_result(loop) == -Base.Libc.ECANCELED
        @test_throws PipeWireError stop!(loop)
    finally
        close(loop)
        close(context)
    end
end
