using PipeWireAO
using Test

struct StreamParamRecorder
    id::Base.RefValue{UInt32}
    value::Base.RefValue{Union{Nothing,Pod}}
    calls::Base.RefValue{Int}
end

function (recorder::StreamParamRecorder)(::Stream, id::UInt32, pod::Pod)
    recorder.id[] = id
    recorder.value[] = pod
    recorder.calls[] += 1
    return nothing
end

struct StreamParamOverflowRecorder
    value::Base.RefValue{Tuple{UInt32,Int}}
    calls::Base.RefValue{Int}
end

function (recorder::StreamParamOverflowRecorder)(::Stream, id::UInt32, total_size::Int)
    recorder.value[] = (id, total_size)
    recorder.calls[] += 1
    return nothing
end

function invoke_stream_param_changed(stream::T, id::UInt32, pod::Pod) where {T<:Stream}
    events = getfield(stream, :events)[]
    GC.@preserve stream pod ccall(
        events.param_changed,
        Cvoid,
        (Ref{T}, UInt32, Ptr{PipeWireAO.LibPipeWire.spa_pod}),
        stream,
        id,
        PipeWireAO._pod_pointer(pod),
    )
    return nothing
end

function stream_overflow_bytes(stream, id, pod)
    return @allocated invoke_stream_param_changed(stream, id, pod)
end

@testset "stream parameter overflow callback" begin
    context = Context()
    core = CoreConnection(context; self=true)
    buffer = PodBuffer(512)
    param_recorder = StreamParamRecorder(Ref(UInt32(0)), Ref{Union{Nothing,Pod}}(nothing), Ref(0))
    overflow_recorder = StreamParamOverflowRecorder(Ref((UInt32(0), 0)), Ref(0))
    stream = Stream(
        core,
        "pipewireao-param-overflow-test";
        param_buffer=buffer,
        on_param_changed=param_recorder,
        on_param_overflow=overflow_recorder,
    )

    try
        format = NdArrayFormat(NdArray.F32_LE, (2,); layout=NdArray.ROW_MAJOR)
        format_pod = ndarray_format(format; id=SPA.PARAM_FORMAT)
        oversized_pod = Pod("x"^2048)
        before_overflow = copy(buffer.pod.data)

        @test invoke_stream_param_changed(stream, SPA.PARAM_FORMAT, oversized_pod) === nothing
        @test overflow_recorder.calls[] == 1
        @test overflow_recorder.value[] == (SPA.PARAM_FORMAT, sizeof(oversized_pod))
        @test param_recorder.calls[] == 0
        @test buffer.pod.data == before_overflow
        @test stream.callback_error[] === nothing

        # The same format callback remains usable after an overflow rejection.
        @test invoke_stream_param_changed(stream, SPA.PARAM_FORMAT, format_pod) === nothing
        @test param_recorder.calls[] == 1
        @test param_recorder.id[] == SPA.PARAM_FORMAT
        @test something(param_recorder.value[]) == format_pod
        @test stream.callback_error[] === nothing

        # Warm then measure only repeated oversized callback dispatch.
        @test invoke_stream_param_changed(stream, SPA.PARAM_FORMAT, oversized_pod) === nothing
        @test stream_overflow_bytes(stream, SPA.PARAM_FORMAT, oversized_pod) == 0
        @test overflow_recorder.calls[] == 3
        @test stream.callback_error[] === nothing
    finally
        close(stream)
        close(core)
        close(context)
    end
end
