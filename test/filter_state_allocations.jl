using Test, PipeWireAO

function filter_state_bytes(filter)
    filter_state(filter)
    return @allocated for _ in 1:1000
        filter_state(filter)
    end
end

@testset "native filter state allocation and failures" begin
    context = Context()
    core = CoreConnection(context; self=true)
    filter = Filter(core, "filter-state-allocation-test")
    try
        @test filter_state(filter) == PipeWireAO.LibPipeWire.PW_FILTER_STATE_UNCONNECTED
        filter_state_bytes(filter)
        @test filter_state_bytes(filter) == 0
        @test set_error!(filter, -5, "filter state allocation test error") === filter
        reported = try
            filter_state(filter)
            nothing
        catch exception
            exception
        end
        @test reported isa PipeWireError
        @test reported.code == -5
        @test reported.detail == "filter state allocation test error"
        callback_failure = ErrorException("retained filter callback failure")
        lock(filter.callback_lock) do
            filter.callback_error[] = callback_failure
        end
        reported = try
            filter_state(filter)
            nothing
        catch exception
            exception
        end
        @test reported === callback_failure
    finally
        close(filter)
        close(core)
        close(context)
    end
    @test !isopen(filter)
    # A prior callback exception remains primary even after closure.
    @test_throws ErrorException filter_state(filter)

    context = Context()
    core = CoreConnection(context; self=true)
    filter = Filter(core, "closed-filter-state-test")
    close(filter)
    try
        @test_throws InvalidStateException filter_state(filter)
    finally
        close(core)
        close(context)
    end
end
