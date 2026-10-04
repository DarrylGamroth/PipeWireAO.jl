using PipeWireAO
using Test

function array_exchange_fixture(::Type{T}, count=4) where {T}
    native = PipeWireAO.LibPipeWire
    memory = zeros(UInt8, count * sizeof(T))
    chunk = Ref(native.spa_chunk(UInt32(0), UInt32(length(memory)), Int32(sizeof(T)), Int32(0)))
    header = Ref(native.spa_meta_header(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1)))
    acquisition = zeros(UInt64, Int(native.SPA_META_ACQUISITION_SIZE) ÷ sizeof(UInt64))
    metadata = native.spa_meta[
        native.spa_meta(native.SPA_META_Header, UInt32(sizeof(native.spa_meta_header)), Base.unsafe_convert(Ptr{Cvoid}, header)),
        native.spa_meta(native.SPA_META_Acquisition, UInt32(sizeof(acquisition)), Ptr{Cvoid}(pointer(acquisition))),
    ]
    data = Ref(native.spa_data(native.SPA_DATA_MemPtr, SPA.DATA_FLAG_READWRITE, Int64(-1), UInt32(0), UInt32(length(memory)), pointer(memory), Base.unsafe_convert(Ptr{native.spa_chunk}, chunk)))
    spa_buffer = Ref(native.spa_buffer(UInt32(2), UInt32(1), pointer(metadata), Base.unsafe_convert(Ptr{native.spa_data}, data)))
    native_buffer = Ref(native.pw_buffer(Base.unsafe_convert(Ptr{native.spa_buffer}, spa_buffer), C_NULL, UInt64(0), UInt64(0), UInt64(0)))
    buffer = StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer}, native_buffer))
    return (; memory, chunk, header, acquisition, metadata, data, spa_buffer, native_buffer, buffer)
end

@testset "prepared ndarray negotiation is exact" begin
    context = Context()
    core = CoreConnection(context; self=true)
    format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.ROW_MAJOR, rate=SPA.Fraction(1000, 1))
    try
        for changed in (
            NdArrayFormat(NdArray.U16_LE, (4,); layout=format.layout, rate=format.rate),
            NdArrayFormat(NdArray.F32_LE, (2, 2); layout=format.layout, rate=format.rate),
            NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.COLUMN_MAJOR, rate=format.rate),
            NdArrayFormat(NdArray.F32_LE, (4,); layout=format.layout, rate=SPA.Fraction(2000, 1)),
            format,
        )
            source = NdArraySource(core, "test.ndarray.negotiation", zeros(Float32, 4), format; schema="test.format/1")
            try
                parameter = ndarray_format(changed; id=SPA.PARAM_FORMAT, schema=changed === format ? "test.other/1" : "test.format/1")
                source.stream.callbacks.on_param_changed(source.stream, SPA.PARAM_FORMAT, parameter)
                @test source.state.phase[] == PipeWireAO._ARRAY_FAILED
                @test typeof(source.state.error) == ArgumentError
            finally
                close(source)
            end
        end
    finally
        close(core)
        close(context)
    end
end

function array_exchange_copy_allocations(write_state, read_state, buffer)
    PipeWireAO._array_write!(write_state, buffer)
    PipeWireAO._array_read!(read_state, buffer)
    return @allocated begin
        PipeWireAO._array_write!(write_state, buffer)
        PipeWireAO._array_read!(read_state, buffer)
    end
end

@testset "prepared ndarray native packed-stride compatibility" begin
    native = PipeWireAO.LibPipeWire
    for (shape, layout, packed_stride) in (((277,), NdArray.ROW_MAJOR, 1108),
                                          ((2, 3), NdArray.ROW_MAJOR, 12),
                                          ((2, 3), NdArray.COLUMN_MAJOR, 8))
        format = NdArrayFormat(NdArray.F32_LE, shape; layout)
        values = collect(Float32, 1:element_count(format))
        writer = PipeWireAO._ArrayExchangeState(values, format, nothing)
        reader = PipeWireAO._ArrayExchangeState(zeros(Float32, length(values)), format, nothing)
        writer.header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1))
        reader.expected = UInt64(1)
        @test @inferred(PipeWireAO._array_packed_stride(reader)) == packed_stride
        # These exact allocation parameters are used both at connect and after
        # negotiated Format. Absence of stride lets the native peer's fixed
        # contiguous-axis stride survive SPA parameter filtering.
        declaration = first(PipeWireAO._array_buffer_parameters(writer))
        object = pod_value(SPA.Parameter, declaration).object
        @test !haskey(object, native.SPA_PARAM_BUFFERS_stride)
        @test pod_value(Int32, object[native.SPA_PARAM_BUFFERS_size].value) == payload_size(format)
        @test pod_value(Int32, object[native.SPA_PARAM_BUFFERS_blocks].value) == 1
        fixture = array_exchange_fixture(Float32, length(values))
        GC.@preserve fixture begin
            PipeWireAO._array_write!(writer, fixture.buffer)
            @test chunk_info(buffer_data(fixture.buffer)).stride == sizeof(Float32)
            set_chunk!(buffer_data(fixture.buffer); size=payload_size(format), stride=packed_stride)
            @test @inferred(PipeWireAO._array_read!(reader, fixture.buffer)) === nothing
            @test reader.values == values
            @test @allocated(PipeWireAO._array_read!(reader, fixture.buffer)) == 0
            # Native FGN outputs may leave the external chunk stride at zero;
            # the exact ndarray Format still defines packed storage.
            set_chunk!(buffer_data(fixture.buffer); size=payload_size(format), stride=0)
            @test @inferred(PipeWireAO._array_read!(reader, fixture.buffer)) === nothing
            @test reader.values == values
            @test @allocated(PipeWireAO._array_read!(reader, fixture.buffer)) == 0
            set_chunk!(buffer_data(fixture.buffer); size=payload_size(format), stride=-sizeof(Float32))
            @test_throws ArgumentError PipeWireAO._array_read!(reader, fixture.buffer)
            set_chunk!(buffer_data(fixture.buffer); size=payload_size(format), stride=packed_stride + sizeof(Float32))
            @test_throws ArgumentError PipeWireAO._array_read!(reader, fixture.buffer)
            set_chunk!(buffer_data(fixture.buffer); size=0, stride=0)
            @test_throws ArgumentError PipeWireAO._array_read!(reader, fixture.buffer)
            set_chunk!(buffer_data(fixture.buffer); size=payload_size(format) - sizeof(Float32), stride=0)
            @test_throws ArgumentError PipeWireAO._array_read!(reader, fixture.buffer)
            fixture.chunk[] = native.spa_chunk(UInt32(0), UInt32(payload_size(format) + sizeof(Float32)), Int32(0), Int32(0))
            @test_throws ArgumentError PipeWireAO._array_read!(reader, fixture.buffer)
        end
    end
end

@testset "prepared ndarray encoding and captured metadata" begin
    domain = AcquisitionDomain(ntuple(i -> UInt8(i), ACQUISITION_DOMAIN_SIZE))
    identity = AcquisitionIdentity(domain, UInt64(5), UInt64(1))
    for (T, element, values) in ((Float32, NdArray.F32_LE, Float32[1, -2, 3, 4]),
                                 (UInt16, NdArray.U16_LE, UInt16[0, 1, 255, 65535]),
                                 (Bool, NdArray.BOOL8, Bool[false, true, true, false]))
        format = NdArrayFormat(element, (2, 2); layout=NdArray.ROW_MAJOR, rate=SPA.Fraction(1000, 1))
        write_state = PipeWireAO._ArrayExchangeState(values, format, "test.ndarray/1")
        read_state = PipeWireAO._ArrayExchangeState(zeros(T, 4), format, "test.ndarray/1")
        values[1] = zero(T)
        @test write_state.values !== values
        write_state.header = BufferHeader(UInt32(0), UInt32(0), Int64(4), Int64(0), UInt64(1))
        write_state.identity = identity
        write_state.duration = UInt64(10)
        read_state.expected = identity
        read_state.expected_duration = UInt64(10)
        fixture = array_exchange_fixture(T)
        GC.@preserve fixture begin
            @test @inferred(PipeWireAO._array_write!(write_state, fixture.buffer)) === nothing
            @test @inferred(PipeWireAO._array_read!(read_state, fixture.buffer)) === nothing
            @test read_state.values == write_state.values
            @test read_state.header == write_state.header
            @test read_state.identity == identity
            @test read_state.duration == UInt64(10)
            @test fixture.memory == collect(reinterpret(UInt8, write_state.values))
            @test array_exchange_copy_allocations(write_state, read_state, fixture.buffer) == 0

            read_state.expected = AcquisitionIdentity(domain, UInt64(6), UInt64(1))
            @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)
            read_state.expected = UInt64(2)
            @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)
            read_state.expected = UInt64(1)
            read_state.expected_duration = UInt64(11)
            @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)
            read_state.expected_duration = nothing
            set_chunk!(buffer_data(fixture.buffer); offset=1, size=sizeof(T)*4-1, stride=sizeof(T))
            @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)
            set_chunk!(buffer_data(fixture.buffer); size=sizeof(T)*4, stride=0)
            @test PipeWireAO._array_read!(read_state, fixture.buffer) === nothing
            PipeWireAO._array_write!(write_state, fixture.buffer)
            fill!(fixture.acquisition, UInt64(0))
            @test_throws InvalidStateException PipeWireAO._array_read!(read_state, fixture.buffer)
            PipeWireAO._array_write!(write_state, fixture.buffer)
            if T == Bool
                fixture.memory[1] = 2
                @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)
            end
        end
    end
    @test_throws ArgumentError PipeWireAO._ArrayExchangeState(zeros(Float64, 4), NdArrayFormat(NdArray.F64_LE, (4,); layout=NdArray.ROW_MAJOR), nothing)
    @test_throws ArgumentError PipeWireAO._ArrayExchangeState(zeros(Float32, 4), NdArrayFormat(NdArray.U16_LE, (4,); layout=NdArray.ROW_MAJOR), nothing)
    @test_throws DimensionMismatch PipeWireAO._ArrayExchangeState(zeros(Float32, 3), NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.ROW_MAJOR), nothing)
end

@testset "zero Header sequence is explicitly opt-in" begin
    format = NdArrayFormat(NdArray.F32_LE, (1,); layout=NdArray.ROW_MAJOR)
    domain = AcquisitionDomain(ntuple(i -> UInt8(i), ACQUISITION_DOMAIN_SIZE))
    context = Context()
    core = CoreConnection(context; self=true)
    sink = NdArraySink(core, "test.ndarray.zero.sequence", zeros(Float32, 1), format)
    try
        @test_throws ArgumentError arm_array_sink!(sink, UInt64(0))
        sink.state.started = true
        arm_array_sink!(sink, UInt64(0); allow_zero_sequence=true)
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(0); allow_zero_sequence=true)
        sink.state.phase[] = PipeWireAO._ARRAY_COMPLETE
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(0); allow_zero_sequence=true)
        sink.state.acknowledged = true
        @test arm_array_sink!(sink, UInt64(0); allow_zero_sequence=true) === sink

        @test_throws ArgumentError PipeWireAO._array_validate_expected_sequence(
            AcquisitionIdentity(domain, UInt64(1), UInt64(0)), true)
    finally
        close(sink)
        close(core)
        close(context)
    end

    write_state = PipeWireAO._ArrayExchangeState(Float32[7], format, nothing)
    read_state = PipeWireAO._ArrayExchangeState(Float32[0], format, nothing)
    write_state.header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(0))
    read_state.expected = UInt64(0)
    fixture = array_exchange_fixture(Float32, 1)
    GC.@preserve fixture begin
        PipeWireAO._array_write!(write_state, fixture.buffer)
        @test PipeWireAO._array_read!(read_state, fixture.buffer) === nothing
        @test read_state.header == write_state.header
        @test read_state.values == Float32[7]

        write_state.values[1] = 8
        PipeWireAO._array_write!(write_state, fixture.buffer)
        @test PipeWireAO._array_read!(read_state, fixture.buffer) === nothing
        @test read_state.values == Float32[8]

        write_state.header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1))
        PipeWireAO._array_write!(write_state, fixture.buffer)
        @test_throws ArgumentError PipeWireAO._array_read!(read_state, fixture.buffer)

        identity = AcquisitionIdentity(domain, UInt64(2), UInt64(1))
        write_state.header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1))
        write_state.identity = identity
        read_state.expected = identity
        PipeWireAO._array_write!(write_state, fixture.buffer)
        @test PipeWireAO._array_read!(read_state, fixture.buffer) === nothing
        @test read_state.identity == identity
    end
end

@testset "prepared ndarray lifecycle and bounded waits" begin
    context = Context()
    core = CoreConnection(context; self=true)
    format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.COLUMN_MAJOR)
    source = NdArraySource(core, "test.ndarray.source", zeros(Float32, 4), format)
    sink = NdArraySink(core, "test.ndarray.sink", zeros(Float32, 4), format)
    header = BufferHeader(UInt32(0), UInt32(0), Int64(0), Int64(0), UInt64(1))
    try
        @test isconcretetype(typeof(source))
        @test isconcretetype(typeof(sink))
        @test !isrunning(source)
        @test !isrunning(sink)
        @test_throws InvalidStateException submit_array!(source, ones(Float32, 4), header)
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(1))
        start!(source)
        start!(sink)
        @test_throws InvalidStateException close(core)
        token = submit_array!(source, ones(Float32, 4), header)
        @test token == 1
        @test_throws InvalidStateException submit_array!(source, ones(Float32, 4), header)
        @test_throws InvalidStateException start!(source)
        @test_throws ArgumentError wait_array_source!(source, UInt64(2); timeout_ns=1_000_000)
        source.state.phase[] = PipeWireAO._ARRAY_COMPLETE
        @test wait_array_source!(source, token; timeout_ns=1_000_000_000) == token
        @test submit_array!(source, ones(Float32, 4), header) == 2
        source_waiter = @async wait_array_source!(source, UInt64(2); timeout_ns=1_000_000_000)
        @test timedwait(() -> source.state.waiting[], 1; pollint=0.001) == :ok
        @test_throws InvalidStateException wait_array_source!(source, UInt64(2); timeout_ns=1_000_000_000)
        @test source.state.phase[] == PipeWireAO._ARRAY_PENDING
        source.state.phase[] = PipeWireAO._ARRAY_COMPLETE
        PipeWireAO._array_notify!(source.state)
        @test fetch(source_waiter) == 2
        arm_array_sink!(sink, UInt64(1))
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(2))
        @test_throws InvalidStateException array_values(sink)
        sink.state.header = header
        sink.state.phase[] = PipeWireAO._ARRAY_COMPLETE
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(2))
        @test wait_array_sink!(sink; timeout_ns=1_000_000_000).header == header
        @test @inferred(array_values(sink)) === sink.state.values
        @test @inferred(array_receipt(sink)).header == header
        @test array_receipt(sink) == array_receipt(sink)
        arm_array_sink!(sink, UInt64(2))
        @test_throws InvalidStateException wait_array_sink!(sink; timeout_ns=1_000_000)
        @test sink.state.phase[] == PipeWireAO._ARRAY_FAILED
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(3))
        @test isopen(core)
    finally
        close(source)
        close(sink)
        @test !isopen(source)
        @test !isopen(sink)
        @test close(source) === nothing
        @test_throws InvalidStateException start!(source)
        @test_throws InvalidStateException submit_array!(source, ones(Float32, 4), header)
        @test_throws InvalidStateException arm_array_sink!(sink, UInt64(1))
        close(core)
        close(context)
    end
end

@testset "prepared ndarray disconnect and close wake waiters" begin
    for disconnect in (false, true)
        context = Context()
        core = CoreConnection(context; self=true)
        format = NdArrayFormat(NdArray.F32_LE, (1,); layout=NdArray.ROW_MAJOR)
        sink = NdArraySink(core, "test.ndarray.wake", zeros(Float32, 1), format)
        try
            start!(sink)
            arm_array_sink!(sink, UInt64(1))
            waiter = @async try
                wait_array_sink!(sink; timeout_ns=10_000_000_000)
            catch error
                error
            end
            @test timedwait(() -> sink.state.waiting[], 1; pollint=0.001) == :ok
            @test_throws InvalidStateException wait_array_sink!(sink; timeout_ns=1_000_000_000)
            if disconnect
                disconnect!(sink.stream)
            else
                close(sink)
            end
            @test timedwait(() -> istaskdone(waiter), 1; pollint=0.001) == :ok
            error = fetch(waiter)
            @test typeof(error) == InvalidStateException
            @test error.state == (disconnect ? :disconnected : :closed)
        finally
            close(sink)
            close(core)
            close(context)
        end
    end
end
