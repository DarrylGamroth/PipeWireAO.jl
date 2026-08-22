"Require SPA header metadata on every image buffer."
const IMAGE_SOURCE_REQUIRE_HEADER = LibPipeWire.PW_IMAGE_SOURCE_FLAG_REQUIRE_HEADER
"Require physical-acquisition metadata on every image buffer."
const IMAGE_SOURCE_REQUIRE_ACQUISITION =
    LibPipeWire.PW_IMAGE_SOURCE_FLAG_REQUIRE_ACQUISITION
"Permit progressive image publication."
const IMAGE_SOURCE_ALLOW_PROGRESSIVE = LibPipeWire.PW_IMAGE_SOURCE_FLAG_ALLOW_PROGRESSIVE
"Maximum fixed-pool size supported by the native image-source ABI."
const IMAGE_SOURCE_MAX_BUFFERS = 64

"Fixed bounds and metadata requirements for an [`ImageSource`](@ref)."
struct ImageSourceConfig
    min_buffers::UInt32
    max_buffers::UInt32
    flags::UInt32

    function ImageSourceConfig(
        min_buffers::Integer,
        max_buffers::Integer;
        flags::Integer=IMAGE_SOURCE_REQUIRE_HEADER,
    )
        1 <= min_buffers <= max_buffers <= IMAGE_SOURCE_MAX_BUFFERS ||
            throw(ArgumentError("image-source buffer bounds are invalid"))
        0 <= flags <= typemax(UInt32) ||
            throw(ArgumentError("image-source flags are outside UInt32 range"))
        UInt32(flags) & ~UInt32(LibPipeWire.PW_IMAGE_SOURCE_FLAG_ALL) == 0 ||
            throw(ArgumentError("image-source flags contain unsupported bits"))
        return new(UInt32(min_buffers), UInt32(max_buffers), UInt32(flags))
    end
end

"Native lifecycle state of one fixed image-pool slot."
@enum ImageBufferState::UInt32 begin
    IMAGE_BUFFER_UNUSED = LibPipeWire.PW_IMAGE_BUFFER_STATE_UNUSED
    IMAGE_BUFFER_AVAILABLE = LibPipeWire.PW_IMAGE_BUFFER_STATE_AVAILABLE
    IMAGE_BUFFER_PRODUCER = LibPipeWire.PW_IMAGE_BUFFER_STATE_PRODUCER
    IMAGE_BUFFER_PROGRESSIVE = LibPipeWire.PW_IMAGE_BUFFER_STATE_PROGRESSIVE
    IMAGE_BUFFER_PUBLISHED = LibPipeWire.PW_IMAGE_BUFFER_STATE_PUBLISHED
end

"Producer-supplied payload and observation metadata for one complete image."
struct ImageFrame{AcquisitionType}
    data_index::UInt32
    header_flags::UInt32
    chunk_flags::UInt32
    offset::UInt32
    size::UInt32
    stride::Int32
    sequence::UInt64
    pts::Int64
    acquisition::AcquisitionType
end

function ImageFrame(
    ;
    data_index::Integer=1,
    header_flags::Integer=0,
    chunk_flags::Integer=0,
    offset::Integer=0,
    size::Integer,
    stride::Integer=0,
    sequence::Integer,
    pts::Integer,
    acquisition::Union{Nothing,AcquisitionMetadata}=nothing,
)
    1 <= data_index <= typemax(UInt32) ||
        throw(ArgumentError("image data index is outside the one-based UInt32 range"))
    0 <= header_flags <= typemax(UInt32) ||
        throw(ArgumentError("image header flags are outside UInt32 range"))
    0 <= chunk_flags <= typemax(UInt32) ||
        throw(ArgumentError("image chunk flags are outside UInt32 range"))
    0 <= offset <= typemax(UInt32) ||
        throw(ArgumentError("image offset is outside UInt32 range"))
    0 <= size <= typemax(UInt32) ||
        throw(ArgumentError("image size is outside UInt32 range"))
    typemin(Int32) <= stride <= typemax(Int32) ||
        throw(ArgumentError("image stride is outside Int32 range"))
    0 <= sequence <= typemax(UInt64) ||
        throw(ArgumentError("image sequence is outside UInt64 range"))
    typemin(Int64) <= pts <= typemax(Int64) ||
        throw(ArgumentError("image PTS is outside Int64 range"))
    return ImageFrame(
        UInt32(data_index),
        UInt32(header_flags),
        UInt32(chunk_flags),
        UInt32(offset),
        UInt32(size),
        Int32(stride),
        UInt64(sequence),
        Int64(pts),
        acquisition,
    )
end

"Initial state for a progressive image publication."
struct ImageProgressive
    payload_size::UInt32
    commit_granularity::UInt32
    committed::UInt32

    function ImageProgressive(
        payload_size::Integer,
        commit_granularity::Integer;
        committed::Integer=0,
    )
        0 < payload_size <= typemax(UInt32) ||
            throw(ArgumentError("progressive payload size is outside UInt32 range"))
        0 < commit_granularity <= payload_size ||
            throw(ArgumentError("progressive commit granularity is invalid"))
        0 <= committed <= payload_size ||
            throw(ArgumentError("progressive committed prefix is invalid"))
        (committed == payload_size || committed % commit_granularity == 0) ||
            throw(ArgumentError("progressive committed prefix is not aligned"))
        return new(UInt32(payload_size), UInt32(commit_granularity), UInt32(committed))
    end
end

"One stable slot in a native PipeWireAO image-source pool."
mutable struct ImageBuffer <: AbstractPipeWireBuffer
    handle::Ptr{LibPipeWire.pw_buffer}
    image_handle::Ptr{LibPipeWire.pw_image_buffer}
    source_handle::Ptr{LibPipeWire.pw_image_source}
    index::UInt32
    frame::Base.RefValue{LibPipeWire.pw_image_frame}
    progressive::Base.RefValue{LibPipeWire.pw_image_progressive}
end

"A borrowed data plane belonging to an [`ImageBuffer`](@ref)."
struct ImageData <: AbstractPipeWireData
    buffer::ImageBuffer
    index::Int
end

"A bounded snapshot of native image-source counters."
struct ImageSourceStats
    prepare_calls::UInt64
    acquire_calls::UInt64
    available_acquisitions::UInt64
    reusable_acquisitions::UInt64
    pool_exhaustions::UInt64
    forced_reclaims::UInt64
    producer_returns::UInt64
    complete_publications::UInt64
    progressive_started::UInt64
    progressive_updates::UInt64
    progressive_completed::UInt64
    progressive_aborted::UInt64
    invalid_transitions::UInt64
    metadata_errors::UInt64
    teardown_returns::UInt64
    pool_size::UInt32
    max_available_probes::UInt32
end

"A fixed-pool image publisher tied to one connected PipeWireAO stream."
mutable struct ImageSource{StreamType<:Stream}
    handle::Ptr{LibPipeWire.pw_image_source}
    stream::StreamType
    buffers::Vector{ImageBuffer}
    output::Base.RefValue{Ptr{LibPipeWire.pw_image_buffer}}
    stats::Base.RefValue{LibPipeWire.pw_image_source_stats}
    prepared::Bool
    retained::Bool
end

function ImageSource(stream::Stream, config::ImageSourceConfig)
    native = Ref(
        LibPipeWire.pw_image_source_config(
            UInt32(0),
            config.min_buffers,
            config.max_buffers,
            config.flags,
        ),
    )
    handle = lock(stream.state_lock) do
        result = LibPipeWire.pw_image_source_new(_require_open(stream), native)
        result != C_NULL && (stream.image_source_count += 1)
        return result
    end
    handle == C_NULL && throw(PipeWireError(:pw_image_source_new, -Base.Libc.errno()))
    source = ImageSource(
        handle,
        stream,
        ImageBuffer[],
        Ref{Ptr{LibPipeWire.pw_image_buffer}}(C_NULL),
        Ref{LibPipeWire.pw_image_source_stats}(),
        false,
        true,
    )
    finalizer(_finalize!, source)
    return source
end

function _require_open(source::ImageSource)
    source.handle == C_NULL &&
        throw(InvalidStateException("the image source is closed", :closed))
    return source.handle
end

function Base.isopen(source::ImageSource)
    return source.handle != C_NULL
end

function _invalidate!(buffer::ImageBuffer)
    buffer.handle = Ptr{LibPipeWire.pw_buffer}(C_NULL)
    buffer.image_handle = Ptr{LibPipeWire.pw_image_buffer}(C_NULL)
    buffer.source_handle = Ptr{LibPipeWire.pw_image_source}(C_NULL)
    return buffer
end

function _invalidate_buffers!(source::ImageSource)
    for buffer in source.buffers
        _invalidate!(buffer)
    end
    empty!(source.buffers)
    return source
end

function _finalize!(source::ImageSource)
    source.handle == C_NULL && return nothing
    handle = source.handle
    source.handle = Ptr{LibPipeWire.pw_image_source}(C_NULL)
    source.prepared = false
    _invalidate_buffers!(source)
    LibPipeWire.pw_image_source_destroy(handle)
    if source.retained
        source.retained = false
        lock(source.stream.state_lock) do
            source.stream.image_source_count -= 1
        end
    end
    return nothing
end

function Base.close(source::ImageSource)
    _finalize!(source)
    return nothing
end

function prepare!(source::ImageSource)
    source.prepared &&
        throw(InvalidStateException("the image source is already prepared", :prepared))
    result = LibPipeWire.pw_image_source_prepare(_require_open(source))
    _check_result(:pw_image_source_prepare, result)
    result > 0 || throw(PipeWireError(:pw_image_source_prepare, Cint(-Base.Libc.EPROTO)))
    source.prepared = true
    try
        count = Int(LibPipeWire.pw_image_source_get_n_buffers(source.handle))
        count == result ||
            throw(PipeWireError(:pw_image_source_prepare, Cint(-Base.Libc.EPROTO)))
        _invalidate_buffers!(source)
        sizehint!(source.buffers, count)
        for index in 0:(count - 1)
            image_handle = LibPipeWire.pw_image_source_get_buffer(source.handle, UInt32(index))
            image_handle == C_NULL &&
                throw(PipeWireError(:pw_image_source_get_buffer, Cint(-Base.Libc.EPROTO)))
            handle = LibPipeWire.pw_image_buffer_get_pw_buffer(image_handle)
            handle == C_NULL &&
                throw(PipeWireError(:pw_image_buffer_get_pw_buffer, Cint(-Base.Libc.EPROTO)))
            push!(
                source.buffers,
                ImageBuffer(
                    handle,
                    image_handle,
                    source.handle,
                    UInt32(index + 1),
                    Ref{LibPipeWire.pw_image_frame}(),
                    Ref{LibPipeWire.pw_image_progressive}(),
                ),
            )
        end
        return count
    catch
        LibPipeWire.pw_image_source_teardown(source.handle)
        source.prepared = false
        _invalidate_buffers!(source)
        rethrow()
    end
end

function teardown!(source::ImageSource)
    source.prepared || return source
    _check_result(
        :pw_image_source_teardown,
        LibPipeWire.pw_image_source_teardown(_require_open(source)),
    )
    source.prepared = false
    _invalidate_buffers!(source)
    return source
end

function _require_available(buffer::ImageBuffer)
    buffer.handle == C_NULL &&
        throw(InvalidStateException("the image buffer is unavailable", :unavailable))
    state = image_buffer_state(buffer)
    state in (IMAGE_BUFFER_PRODUCER, IMAGE_BUFFER_PROGRESSIVE) || throw(
        InvalidStateException("the image buffer is not producer-owned", Symbol(lowercase(string(state)))),
    )
    return buffer.handle
end

image_buffer_index(buffer::ImageBuffer) = Int(buffer.index)

function image_buffer_state(buffer::ImageBuffer)
    buffer.image_handle == C_NULL &&
        throw(InvalidStateException("the image buffer is unavailable", :unavailable))
    return ImageBufferState(LibPipeWire.pw_image_buffer_get_state(buffer.image_handle))
end

function buffer_data(buffer::ImageBuffer, index::Integer=1)
    native = unsafe_load(_require_available(buffer)).buffer
    native == C_NULL &&
        throw(InvalidStateException("the image buffer has no SPA buffer", :no_buffer))
    count = Int(unsafe_load(native).n_datas)
    1 <= index <= count || throw(BoundsError(1:count, index))
    return ImageData(buffer, Int(index))
end

function _native_data(data::ImageData)
    native = unsafe_load(_require_available(data.buffer)).buffer
    buffer = unsafe_load(native)
    return unsafe_load(buffer.datas, data.index)
end

function _acquired_buffer(source::ImageSource, operation, operation_name::Symbol)
    source.prepared ||
        throw(InvalidStateException("the image source is not prepared", :unprepared))
    source.output[] = Ptr{LibPipeWire.pw_image_buffer}(C_NULL)
    result = operation(_require_open(source), source.output)
    result in (0, -Base.Libc.EPIPE) && return nothing
    _check_result(operation_name, result)
    result == 1 || throw(PipeWireError(operation_name, Cint(-Base.Libc.EPROTO)))
    handle = source.output[]
    handle == C_NULL && throw(PipeWireError(operation_name, Cint(-Base.Libc.EPROTO)))
    index = Int(LibPipeWire.pw_image_buffer_get_index(handle)) + 1
    1 <= index <= length(source.buffers) ||
        throw(PipeWireError(operation_name, Cint(-Base.Libc.EPROTO)))
    buffer = source.buffers[index]
    buffer.image_handle == handle ||
        throw(PipeWireError(operation_name, Cint(-Base.Libc.EPROTO)))
    return buffer
end

"Acquire one producer-owned image slot, or return `nothing` on pool exhaustion or subscriber loss."
try_acquire!(source::ImageSource) = _acquired_buffer(
    source,
    LibPipeWire.pw_image_source_try_acquire,
    :pw_image_source_try_acquire,
)

"Withdraw at most one visible, unclaimed image under explicit lossy policy, or return `nothing`."
try_reclaim!(source::ImageSource) = _acquired_buffer(
    source,
    LibPipeWire.pw_image_source_try_reclaim,
    :pw_image_source_try_reclaim,
)

"Return an unpublished producer-owned image slot to the local pool."
function return_buffer!(buffer::ImageBuffer)
    _require_available(buffer)
    _check_result(
        :pw_image_source_return_buffer,
        LibPipeWire.pw_image_source_return_buffer(buffer.source_handle, buffer.image_handle),
    )
    return buffer
end

function _raw_frame(buffer::ImageBuffer, frame::ImageFrame)
    acquisition = if frame.acquisition === nothing
        Ptr{LibPipeWire.spa_meta_acquisition}(C_NULL)
    else
        frame.acquisition.metadata.buffer === buffer || throw(
            ArgumentError("image acquisition metadata belongs to a different buffer"),
        )
        _acquisition_storage_pointer(frame.acquisition)
    end
    return LibPipeWire.pw_image_frame(
        UInt32(0),
        frame.data_index - UInt32(1),
        frame.header_flags,
        frame.chunk_flags,
        frame.offset,
        frame.size,
        frame.stride,
        UInt32(0),
        frame.sequence,
        frame.pts,
        acquisition,
    )
end

"Publish one terminal complete image without copying its payload."
function publish_complete!(buffer::ImageBuffer, frame::ImageFrame)
    _require_available(buffer)
    buffer.frame[] = _raw_frame(buffer, frame)
    _check_result(
        :pw_image_source_publish_complete,
        LibPipeWire.pw_image_source_publish_complete(
            buffer.source_handle,
            buffer.image_handle,
            buffer.frame,
        ),
    )
    return buffer
end

"Begin progressive publication of a mapped host-memory image."
function begin_progressive!(
    buffer::ImageBuffer,
    frame::ImageFrame,
    progressive::ImageProgressive,
)
    _require_available(buffer)
    buffer.frame[] = _raw_frame(buffer, frame)
    buffer.progressive[] = LibPipeWire.pw_image_progressive(
        UInt32(0),
        progressive.payload_size,
        progressive.commit_granularity,
        progressive.committed,
    )
    _check_result(
        :pw_image_source_begin_progressive,
        LibPipeWire.pw_image_source_begin_progressive(
            buffer.source_handle,
            buffer.image_handle,
            buffer.frame,
            buffer.progressive,
        ),
    )
    return buffer
end

"Release-publish a larger immutable prefix of a progressive image."
function update_progressive!(buffer::ImageBuffer, committed::Integer)
    _require_available(buffer)
    0 <= committed <= typemax(UInt32) ||
        throw(ArgumentError("progressive committed prefix is outside UInt32 range"))
    result = LibPipeWire.pw_image_source_update_progressive(
        buffer.source_handle,
        buffer.image_handle,
        UInt32(committed),
    )
    _check_result(:pw_image_source_update_progressive, result)
    return result == 1
end

"Finish a progressive image in the complete or aborted state."
function finish_progressive!(
    buffer::ImageBuffer,
    committed::Integer,
    state::ProgressiveState;
    terminal_flags::Integer=0,
)
    _require_available(buffer)
    state in (PROGRESSIVE_COMPLETE, PROGRESSIVE_ABORTED) ||
        throw(ArgumentError("a progressive image must finish complete or aborted"))
    0 <= committed <= typemax(UInt32) ||
        throw(ArgumentError("progressive committed prefix is outside UInt32 range"))
    0 <= terminal_flags <= typemax(UInt32) ||
        throw(ArgumentError("progressive terminal flags are outside UInt32 range"))
    _check_result(
        :pw_image_source_finish_progressive,
        LibPipeWire.pw_image_source_finish_progressive(
            buffer.source_handle,
            buffer.image_handle,
            UInt32(committed),
            UInt32(state),
            UInt32(terminal_flags),
        ),
    )
    return buffer
end

function image_source_stats(source::ImageSource)
    _check_result(
        :pw_image_source_get_stats,
        LibPipeWire.pw_image_source_get_stats(
            _require_open(source),
            source.stats,
            Csize_t(sizeof(LibPipeWire.pw_image_source_stats)),
        ),
    )
    raw = source.stats[]
    return ImageSourceStats(
        raw.prepare_calls,
        raw.acquire_calls,
        raw.available_acquisitions,
        raw.reusable_acquisitions,
        raw.pool_exhaustions,
        raw.forced_reclaims,
        raw.producer_returns,
        raw.complete_publications,
        raw.progressive_started,
        raw.progressive_updates,
        raw.progressive_completed,
        raw.progressive_aborted,
        raw.invalid_transitions,
        raw.metadata_errors,
        raw.teardown_returns,
        raw.pool_size,
        raw.max_available_probes,
    )
end
