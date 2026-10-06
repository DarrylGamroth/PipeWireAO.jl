thread_loop_noop(loop) = nothing

function thread_loop_lock_bytes(loop)
    with_thread_loop_lock(thread_loop_noop,loop)
    return @allocated begin
        for _ in 1:1000
            with_thread_loop_lock(thread_loop_noop,loop)
        end
    end
end

@testset "prepared native thread-loop lock allocation" begin
    loop = ThreadLoop("lock-allocation-test")
    try
        start!(loop)
        thread_loop_lock_bytes(loop)
        @test thread_loop_lock_bytes(loop) == 0
        @test with_thread_loop_lock(loop) do locked
            locked === loop
        end
        @test_throws ErrorException with_thread_loop_lock(_->error("fixture"),loop)
        @test with_thread_loop_lock(thread_loop_noop,loop) === nothing
        @test loop.native_access_count == 0
        @test with_thread_loop_lock(loop) do outer
            with_thread_loop_lock(outer) do inner
                inner.native_access_count == 2
            end
        end
        @test with_thread_loop_lock(loop) do outer
            @test_throws ErrorException with_thread_loop_lock(_->error("nested fixture"),outer)
            outer.native_access_count == 1
        end
        @test loop.native_access_count == 0
    finally
        close(loop)
    end
    @test !isopen(loop)
end
