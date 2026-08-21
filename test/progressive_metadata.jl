using PipeWireAO
using Test

function observe_progressive_hot_path(metadata)
    observation = progressive_observation(metadata)
    return (
        progressive_valid(metadata),
        progressive_snapshot(metadata),
        observation,
        progressive_data_index(metadata),
        progressive_payload_offset(metadata),
        progressive_payload_size(metadata),
        progressive_commit_granularity(metadata),
    )
end

function observe_progressive_allocations(metadata)
    observe_progressive_hot_path(metadata)
    return @allocated observe_progressive_hot_path(metadata)
end

function publish_progressive_hot_path(metadata)
    publish_progressive!(metadata, UInt32(16), PROGRESSIVE_ACTIVE)
    set_progressive_terminal_flags!(metadata, UInt32(0))
    return nothing
end

function publish_progressive_allocations(metadata)
    publish_progressive_hot_path(metadata)
    return @allocated publish_progressive_hot_path(metadata)
end

@testset "native shared-control ABI" begin
    native = PipeWireAO.LibPipeWire
    cache_line_size = Int(SPA.CACHE_LINE_SIZE)

    @test sizeof(native.spa_ringbuffer) == 8
    @test cache_line_size >= 64
    @test ispow2(cache_line_size)
    @test sizeof(native.spa_ringbuffer_shared_index) == cache_line_size
    @test sizeof(native.spa_ringbuffer_shared) == 2 * cache_line_size
    @test sizeof(native.spa_io_buffers_latest_submission) == cache_line_size
    @test sizeof(native.spa_io_buffers_latest) == 3 * cache_line_size + 64 * sizeof(UInt32)
    @test sizeof(native.spa_meta_progressive) == 48

    bytes = Vector{UInt8}(undef, sizeof(native.spa_io_buffers_latest))
    GC.@preserve bytes begin
        control = Ptr{native.spa_io_buffers_latest}(Base.pointer(bytes))
        base = UInt(control)
        @test UInt(control.submission) - base == 0
        @test UInt(control.completion) - base == cache_line_size
        @test UInt(control.completion.readindex) - base == cache_line_size
        @test UInt(control.completion.writeindex) - base == 2 * cache_line_size
        @test UInt(control.completion_ids) - base == 3 * cache_line_size
    end
end

@testset "progressive metadata" begin
    native = PipeWireAO.LibPipeWire
    storage = zeros(UInt64, 6)
    metas = native.spa_meta[
        native.spa_meta(
            native.SPA_META_Progressive,
            UInt32(sizeof(native.spa_meta_progressive)),
            Ptr{Cvoid}(Base.pointer(storage)),
        ),
    ]
    spa_buffer = Ref(native.spa_buffer(UInt32(1), UInt32(0), pointer(metas), C_NULL))
    native_buffer = Ref(
        native.pw_buffer(
            Base.unsafe_convert(Ptr{native.spa_buffer}, spa_buffer),
            C_NULL,
            UInt64(0),
            UInt64(0),
            UInt64(0),
        ),
    )

    GC.@preserve storage metas spa_buffer native_buffer begin
        buffer = StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer}, native_buffer))
        metadata = buffer_progressive(buffer)
        @test metadata isa ProgressiveMetadata{StreamBuffer}
        @test !progressive_valid(metadata)

        @test initialize_progressive!(metadata, 2, 128, 64, 16) === metadata
        @test progressive_valid(metadata)
        @test progressive_data_index(metadata) == 2
        @test progressive_payload_offset(metadata) == 128
        @test progressive_payload_size(metadata) == 64
        @test progressive_commit_granularity(metadata) == 16
        @test progressive_snapshot(metadata) == ProgressiveSnapshot(0, PROGRESSIVE_PREPARED)
        @test progressive_observation(metadata) ==
              ProgressiveObservation(ProgressiveSnapshot(0, PROGRESSIVE_PREPARED), 0)
        @test isbitstype(ProgressiveState)
        @test isbitstype(ProgressiveSnapshot)
        @test isbitstype(ProgressiveObservation)
        @test UInt32(PROGRESSIVE_PREPARED) == 0
        @test UInt32(PROGRESSIVE_ACTIVE) == 1
        @test UInt32(PROGRESSIVE_COMPLETE) == 2
        @test UInt32(PROGRESSIVE_ABORTED) == 3
        @test PROGRESSIVE_FLAG_INCOMPLETE == UInt32(1 << 0)
        @test PROGRESSIVE_FLAG_INVALID_LAYOUT == UInt32(1 << 1)
        @test PROGRESSIVE_FLAG_CANCELLED == UInt32(1 << 2)
        @test PROGRESSIVE_FLAG_DEVICE_ERROR == UInt32(1 << 3)
        @test PROGRESSIVE_FLAG_CORRUPTED == UInt32(1 << 4)
        @test PROGRESSIVE_FLAG_PROTOCOL_ERROR == UInt32(1 << 5)

        @test publish_progressive!(metadata, 0) === metadata
        @test progressive_snapshot(metadata) == ProgressiveSnapshot(0, PROGRESSIVE_ACTIVE)
        @test_throws InvalidStateException publish_progressive!(metadata, 7)
        @test publish_progressive!(metadata, 16) === metadata
        @test_throws InvalidStateException publish_progressive!(metadata, 8)
        @test_throws InvalidStateException publish_progressive!(
            metadata,
            16,
            PROGRESSIVE_COMPLETE,
        )

        terminal_flags = PROGRESSIVE_FLAG_INCOMPLETE | PROGRESSIVE_FLAG_CORRUPTED
        @test set_progressive_terminal_flags!(metadata, terminal_flags) === metadata
        @test progressive_observation(metadata).terminal_flags == 0
        @test publish_progressive!(metadata, 16, PROGRESSIVE_ABORTED) === metadata
        terminal = progressive_observation(metadata)
        @test terminal.snapshot == ProgressiveSnapshot(16, PROGRESSIVE_ABORTED)
        @test terminal.terminal_flags == terminal_flags
        @test_throws InvalidStateException publish_progressive!(
            metadata,
            16,
            PROGRESSIVE_ABORTED,
        )
        @test_throws InvalidStateException set_progressive_terminal_flags!(metadata, 0)

        initialize_progressive!(metadata, 2, 128, 64, 16)
        @test_throws InvalidStateException publish_progressive!(
            metadata,
            64,
            PROGRESSIVE_COMPLETE,
        )
        publish_progressive!(metadata, 0)
        publish_progressive!(metadata, 64, PROGRESSIVE_COMPLETE)
        @test progressive_observation(metadata).terminal_flags == 0

        initialize_progressive!(metadata, 2, 128, 64, 16)
        publish_progressive!(metadata, 0)
        publish_progressive!(metadata, 16)
        @test observe_progressive_allocations(metadata) == 0
        @test publish_progressive_allocations(metadata) == 0

        progressive_pointer = Ptr{native.spa_meta_progressive}(Base.pointer(storage))
        unsafe_store!(progressive_pointer.reserved0, UInt32(1))
        @test !progressive_valid(metadata)
        @test_throws InvalidStateException progressive_snapshot(metadata)
        unsafe_store!(progressive_pointer.reserved0, UInt32(0))
        @test progressive_valid(metadata)

        unsafe_store!(progressive_pointer.version, UInt32(2))
        @test !progressive_valid(metadata)
        unsafe_store!(progressive_pointer.version, UInt32(1))
        @test progressive_valid(metadata)

        valid_snapshot = unsafe_load(progressive_pointer.snapshot, :acquire)
        unsafe_store!(progressive_pointer.snapshot, valid_snapshot | UInt64(1 << 34), :release)
        @test !progressive_valid(metadata)
        unsafe_store!(progressive_pointer.snapshot, valid_snapshot, :release)
        @test progressive_valid(metadata)

        metas[1] = native.spa_meta(
            native.SPA_META_Progressive,
            UInt32(sizeof(native.spa_meta_progressive) - 1),
            Ptr{Cvoid}(Base.pointer(storage)),
        )
        @test_throws InvalidStateException buffer_progressive(buffer)
        metas[1] = native.spa_meta(
            native.SPA_META_Progressive,
            UInt32(sizeof(native.spa_meta_progressive)),
            Ptr{Cvoid}(Ptr{UInt8}(Base.pointer(storage)) + 1),
        )
        @test_throws InvalidStateException buffer_progressive(buffer)
    end

    parameter = progressive_metadata_param()
    properties = Dict(property.key => property for property in parameter.object.properties)
    @test pod_value(SPA.Id, properties[SPA.META_PARAM_TYPE].value) ==
          SPA.Id(SPA.META_PROGRESSIVE)
    @test pod_value(Int32, properties[SPA.META_PARAM_SIZE].value) == 48
    @test pod_value(Int32, properties[SPA.META_PARAM_FEATURES].value) == 1
end
