function stream_state_bytes(stream)
    stream_state(stream)
    return @allocated for _ in 1:1000
        stream_state(stream)
    end
end

@testset "native stream state allocation" begin
    context = Context()
    core = CoreConnection(context; self=true)
    stream = Stream(core, "state-allocation-test")
    try
        @test stream_state(stream) == PipeWireAO.LibPipeWire.PW_STREAM_STATE_UNCONNECTED
        stream_state_bytes(stream)
        @test stream_state_bytes(stream) == 0
        @test set_error!(stream, -5, "state allocation test error") === stream
        reported = try
            stream_state(stream)
            nothing
        catch exception
            exception
        end
        @test reported isa PipeWireError
        @test reported.code == -5
        @test reported.detail == "state allocation test error"
    finally
        close(stream)
        close(core)
        close(context)
    end
    @test !isopen(stream)
    @test_throws InvalidStateException stream_state(stream)
end
