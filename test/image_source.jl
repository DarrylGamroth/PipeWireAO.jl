@testset "image-source API" begin
    config = ImageSourceConfig(
        3,
        8;
        flags=IMAGE_SOURCE_REQUIRE_HEADER | IMAGE_SOURCE_REQUIRE_ACQUISITION,
    )
    @test config.min_buffers == 3
    @test config.max_buffers == 8
    @test config.flags ==
          IMAGE_SOURCE_REQUIRE_HEADER | IMAGE_SOURCE_REQUIRE_ACQUISITION
    @test_throws ArgumentError ImageSourceConfig(0, 1)
    @test_throws ArgumentError ImageSourceConfig(2, 1)
    @test_throws ArgumentError ImageSourceConfig(1, IMAGE_SOURCE_MAX_BUFFERS + 1)
    @test_throws ArgumentError ImageSourceConfig(1, 1; flags=1 << 20)

    frame = ImageFrame(size=4096, stride=128, sequence=42, pts=123_456)
    @test frame.data_index == 1
    @test frame.size == 4096
    @test frame.stride == 128
    @test frame.sequence == 42
    @test frame.pts == 123_456
    @test frame.acquisition === nothing
    @test_throws ArgumentError ImageFrame(
        data_index=0,
        size=1,
        sequence=1,
        pts=1,
    )

    progressive = ImageProgressive(4096, 256; committed=512)
    @test progressive.payload_size == 4096
    @test progressive.commit_granularity == 256
    @test progressive.committed == 512
    @test_throws ArgumentError ImageProgressive(0, 1)
    @test_throws ArgumentError ImageProgressive(4096, 0)
    @test_throws ArgumentError ImageProgressive(4096, 256; committed=3)

    if get(ENV, "PIPEWIREAO_IMAGE_SOURCE_TESTS", "false") == "true"
        context = Context()
        core = CoreConnection(context; self=true)
        stream = Stream(core, "julia-image-source-test")
        source = ImageSource(stream, config)
        @test isopen(source)
        @test !getfield(source, :prepared)
        @test_throws InvalidStateException close(stream)
        close(source)
        @test !isopen(source)
        close(source)
        close(stream)
        close(core)
        close(context)
    end
end
