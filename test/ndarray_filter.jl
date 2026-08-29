using PipeWireAO
using Test

const NativeNdArrayFilterBuffer = PipeWireAO.LibPipeWire.pw_ndarray_filter_buffer

function ndarray_filter_test_process(
    ::Ptr{Cvoid},
    ::Ptr{PipeWireAO.LibPipeWire.pw_ndarray_filter_buffer},
    ::UInt32,
    ::Ptr{PipeWireAO.LibPipeWire.pw_ndarray_filter_buffer},
    ::UInt32,
)::Cint
    return Cint(0)
end

struct NdArrayFilterPrepareRecorder
    count::Base.RefValue{Int}
end

function (callback::NdArrayFilterPrepareRecorder)(::NdArrayFilter)
    callback.count[] += 1
    return nothing
end

struct NdArrayFilterProcessRecorder
    count::Base.RefValue{Int}
end

function (callback::NdArrayFilterProcessRecorder)(
    ::NdArrayFilter,
    inputs::NdArrayFilterBuffers{false},
    outputs::NdArrayFilterBuffers{true},
)
    input = inputs[1]
    output = outputs[1]
    input_bytes = bytes(input)
    output_bytes = bytes(output)
    @inbounds for index in eachindex(input_bytes, output_bytes)
        output_bytes[index] = input_bytes[index]
    end
    propagate_metadata!(output, input)
    callback.count[] += 1
    return nothing
end

struct NdArrayFilterDeactivateRecorder
    count::Base.RefValue{Int}
end

function (callback::NdArrayFilterDeactivateRecorder)(::NdArrayFilter)
    callback.count[] += 1
    return nothing
end

function native_ndarray_filter_buffer(
    data::Vector{UInt8};
    available=UInt32(0),
    valid=UInt32(0),
    sequence=UInt64(0),
)
    native = PipeWireAO.LibPipeWire
    storage = [
        native.pw_ndarray_filter_buffer(
            ntuple(_ -> UInt8(0), sizeof(native.pw_ndarray_filter_buffer)),
        ),
    ]
    GC.@preserve storage data begin
        buffer = pointer(storage)
        unsafe_store!(buffer.struct_size, UInt32(sizeof(native.pw_ndarray_filter_buffer)))
        unsafe_store!(buffer.flags, UInt32(0))
        unsafe_store!(buffer.data, Ptr{Cvoid}(pointer(data)))
        unsafe_store!(buffer.size, UInt32(length(data)))
        unsafe_store!(buffer.capacity, UInt32(length(data)))
        unsafe_store!(buffer.metadata_available, available)
        unsafe_store!(buffer.metadata_valid, valid)
        unsafe_store!(
            buffer.header,
            native.spa_meta_header(UInt32(0), UInt32(0), 10, 0, sequence),
        )
        native.spa_meta_acquisition_init(buffer.acquisition)
    end
    return storage
end

function invoke_ndarray_filter_prepare(events, filter::T) where {T<:NdArrayFilter}
    return ccall(events.prepare_process_thread, Cint, (Ref{T},), filter)
end

function invoke_ndarray_filter_process(
    events,
    filter::T,
    inputs::Vector{NativeNdArrayFilterBuffer},
    outputs::Vector{NativeNdArrayFilterBuffer},
) where {T<:NdArrayFilter}
    return GC.@preserve inputs outputs ccall(
        events.process,
        Cint,
        (
            Ref{T},
            Ptr{NativeNdArrayFilterBuffer},
            UInt32,
            Ptr{NativeNdArrayFilterBuffer},
            UInt32,
        ),
        filter,
        pointer(inputs),
        UInt32(length(inputs)),
        pointer(outputs),
        UInt32(length(outputs)),
    )
end

function invoke_ndarray_filter_deactivate(events, filter::T) where {T<:NdArrayFilter}
    return ccall(events.deactivate, Cint, (Ref{T},), filter)
end

mutable struct ForeignNdArrayFilterInvocation{T<:NdArrayFilter}
    events::PipeWireAO.LibPipeWire.pw_ndarray_filter_events
    filter::T
    inputs::Vector{NativeNdArrayFilterBuffer}
    outputs::Vector{NativeNdArrayFilterBuffer}
    result::Cint
end

function invoke_ndarray_filter_process_foreign(
    invocation::ForeignNdArrayFilterInvocation,
)::Cvoid
    try
        invocation.result = invoke_ndarray_filter_process(
            invocation.events,
            invocation.filter,
            invocation.inputs,
            invocation.outputs,
        )
    catch
        invocation.result = Cint(-Base.Libc.EFAULT)
    end
    return nothing
end

function invoke_ndarray_filter_process_on_foreign_thread(
    events,
    filter::T,
    inputs,
    outputs,
) where {T<:NdArrayFilter}
    invocation = ForeignNdArrayFilterInvocation(
        events,
        filter,
        inputs,
        outputs,
        Cint(-Base.Libc.EINPROGRESS),
    )
    thread = Ref{UInt}(0)
    worker = @cfunction(
        invoke_ndarray_filter_process_foreign,
        Cvoid,
        (Ref{ForeignNdArrayFilterInvocation{T}},),
    )
    GC.@preserve invocation begin
        @test ccall(
            :uv_thread_create,
            Cint,
            (Ref{UInt}, Ptr{Cvoid}, Ref{ForeignNdArrayFilterInvocation{T}}),
            thread,
            worker,
            invocation,
        ) == 0
        @test ccall(:uv_thread_join, Cint, (Ref{UInt},), thread) == 0
    end
    return invocation.result
end

struct NdArrayFilterThreadRecorder
    pool::Base.RefValue{Symbol}
end

function (callback::NdArrayFilterThreadRecorder)(
    ::NdArrayFilter,
    inputs::NdArrayFilterBuffers{false},
    outputs::NdArrayFilterBuffers{true},
)
    callback.pool[] = Threads.threadpool()
    copyto!(bytes(outputs[1]), bytes(inputs[1]))
    return nothing
end

const NDARRAY_FILTER_TEST_PROCESS = @cfunction(
    ndarray_filter_test_process,
    Cint,
    (
        Ptr{Cvoid},
        Ptr{PipeWireAO.LibPipeWire.pw_ndarray_filter_buffer},
        UInt32,
        Ptr{PipeWireAO.LibPipeWire.pw_ndarray_filter_buffer},
        UInt32,
    ),
)

@testset "native ndarray bindings remain private" begin
    @test !Base.isexported(PipeWireAO, :LibPipeWire)
    @test !Base.isexported(PipeWireAO, :pw_ndarray_filter)
    @test !Base.isexported(PipeWireAO, :pw_ndarray_filter_config)
    @test !Base.isexported(PipeWireAO, :pw_ndarray_filter_new)
end

@testset "generated ndarray filter ABI" begin
    native = PipeWireAO.LibPipeWire

    @test sizeof(native.pw_ndarray_filter_buffer) == 160
    @test sizeof(native.pw_ndarray_filter_format) == 40
    @test sizeof(native.pw_ndarray_filter_port) == 64
    @test sizeof(native.pw_ndarray_filter_events) == 32
    @test sizeof(native.pw_ndarray_filter_config) == 56
    @test native.PW_NDARRAY_FILTER_FLAG_NONE == UInt32(0)
    @test native.PW_NDARRAY_FILTER_FLAG_RT_PROCESS == UInt32(1)
    @test native.PW_NDARRAY_FILTER_METADATA_HEADER == UInt32(1)
    @test native.PW_NDARRAY_FILTER_METADATA_ACQUISITION == UInt32(2)

    shape = UInt32[8]
    names = ["input"]
    schemas = ["org.pipewireao.test.ndarray/1"]
    events = [
        native.pw_ndarray_filter_events(
            UInt32(0),
            C_NULL,
            NDARRAY_FILTER_TEST_PROCESS,
            C_NULL,
        ),
    ]
    ports = Vector{native.pw_ndarray_filter_port}(undef, 1)
    GC.@preserve shape names schemas begin
        ports[1] = native.pw_ndarray_filter_port(
            UInt32(sizeof(native.pw_ndarray_filter_port)),
            UInt32(0),
            native.SPA_DIRECTION_INPUT,
            UInt32(0),
            pointer(names[1]),
            native.pw_ndarray_filter_format(
                native.SPA_ELEMENT_TYPE_F32_LE,
                native.SPA_NDARRAY_LAYOUT_COLUMN_MAJOR,
                UInt32(0),
                UInt32(0),
                UInt32(1),
                pointer(shape),
                pointer(schemas[1]),
            ),
        )
    end

    result = Ref{Ptr{native.pw_ndarray_filter}}(C_NULL)
    node_name = "test.generated.ndarray.filter"
    GC.@preserve shape names schemas events ports node_name begin
        config = native.pw_ndarray_filter_config(
            UInt32(sizeof(native.pw_ndarray_filter_config)),
            UInt32(0),
            pointer(node_name),
            C_NULL,
            UInt32(1),
            UInt32(0),
            pointer(ports),
            pointer(events),
            C_NULL,
        )
        @test native.pw_ndarray_filter_new(Ref(config), result) == 0
    end
    @test result[] != C_NULL
    @test native.pw_ndarray_filter_get_state(result[]) ==
          native.PW_FILTER_STATE_UNCONNECTED
    @test native.pw_ndarray_filter_get_error(result[]) == 0
    @test native.pw_ndarray_filter_get_node_id(result[]) == typemax(UInt32)
    native.pw_ndarray_filter_destroy(result[])
end

@testset "idiomatic ndarray filter wrapper" begin
    schema = "org.pipewireao.test.vector/1"
    format = NdArrayFormat(
        NdArray.U8,
        (8,);
        layout=NdArray.COLUMN_MAJOR,
        rate=SPA.Fraction(UInt32(1_000), UInt32(1)),
    )
    input_port = NdArrayFilterPort(
        "input",
        PipeWireAO.DIRECTION_INPUT,
        format;
        schema,
    )
    output_port = NdArrayFilterPort(
        "output",
        PipeWireAO.DIRECTION_OUTPUT,
        format;
        schema,
    )
    prepare_count = Ref(0)
    process_count = Ref(0)
    deactivate_count = Ref(0)
    filter = NdArrayFilter(
        "test.idiomatic.ndarray.filter",
        (input_port, output_port);
        on_prepare=NdArrayFilterPrepareRecorder(prepare_count),
        on_process=NdArrayFilterProcessRecorder(process_count),
        on_deactivate=NdArrayFilterDeactivateRecorder(deactivate_count),
    )
    events = PipeWireAO._ndarray_filter_events(filter)

    @test isopen(filter)
    @test !isrunning(filter)
    @test filter_name(filter) == "test.idiomatic.ndarray.filter"
    @test filter_state(filter) == PipeWireAO.NDARRAY_FILTER_STATE_UNCONNECTED
    @test last_error(filter) === nothing
    @test node_id(filter) === nothing
    @test invoke_ndarray_filter_prepare(events, filter) == 0

    metadata = PipeWireAO.LibPipeWire.PW_NDARRAY_FILTER_METADATA_HEADER |
               PipeWireAO.LibPipeWire.PW_NDARRAY_FILTER_METADATA_ACQUISITION
    input_data = collect(UInt8, 1:8)
    output_data = zeros(UInt8, 8)
    input = native_ndarray_filter_buffer(
        input_data;
        available=metadata,
        valid=metadata,
        sequence=17,
    )
    output = native_ndarray_filter_buffer(output_data; available=metadata)
    GC.@preserve input_data output_data input output begin
        input_buffers = NdArrayFilterBuffers{false}(
            Ptr{Cvoid}(pointer(input)),
            UInt32(length(input)),
        )
        @test size(input_buffers) == (1,)
        @test Base.IndexStyle(typeof(input_buffers)) == IndexLinear()
        @test capacity(input_buffers[1]) == length(input_data)

        @test invoke_ndarray_filter_process(events, filter, input, output) == 0
        @test output_data == input_data
        @test unsafe_load(pointer(output).metadata_valid) == metadata
        @test unsafe_load(pointer(output).header).seq == 17

        invoke_ndarray_filter_process(events, filter, input, output)
        @test @allocated(invoke_ndarray_filter_process(events, filter, input, output)) == 0
    end
    @test prepare_count[] == 1
    @test process_count[] == 3
    @test invoke_ndarray_filter_deactivate(events, filter) == 0
    @test deactivate_count[] == 1

    close(filter)
    @test !isopen(filter)
    @test close(filter) === nothing

    remote_filter = NdArrayFilter(
        "test.idiomatic.ndarray.remote-filter",
        (input_port, output_port);
        remote="test.remote",
        on_process=NdArrayFilterProcessRecorder(Ref(0)),
    )
    @test_throws InvalidStateException run!(remote_filter)
    close(remote_filter)
    @test_throws InvalidStateException connect!(remote_filter)
end

@testset "ndarray callback adopts a foreign data-loop thread" begin
    format = NdArrayFormat(NdArray.U8, (1,); layout=NdArray.COLUMN_MAJOR)
    ports = (
        NdArrayFilterPort("input", PipeWireAO.DIRECTION_INPUT, format),
        NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format),
    )
    pool = Ref(:unset)
    filter = NdArrayFilter(
        "test.ndarray.filter.foreign-thread",
        ports;
        on_process=NdArrayFilterThreadRecorder(pool),
    )
    events = PipeWireAO._ndarray_filter_events(filter)
    input_data = UInt8[23]
    output_data = UInt8[0]
    input = native_ndarray_filter_buffer(input_data)
    output = native_ndarray_filter_buffer(output_data)
    GC.@preserve input_data output_data input output begin
        @test invoke_ndarray_filter_process_on_foreign_thread(
            events,
            filter,
            input,
            output,
        ) == 0
    end
    @test pool[] === :foreign
    @test output_data == input_data
    close(filter)
end

@testset "ndarray filter callback exceptions are contained" begin
    format = NdArrayFormat(NdArray.U8, (1,); layout=NdArray.COLUMN_MAJOR)
    input_port =
        NdArrayFilterPort("input", PipeWireAO.DIRECTION_INPUT, format)
    output_port =
        NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format)
    filter = NdArrayFilter(
        "test.ndarray.filter.exception",
        (input_port, output_port);
        on_prepare=filter -> error("contained prepare error"),
        on_process=(filter, inputs, outputs) -> error("contained callback error"),
        on_deactivate=filter -> error("contained deactivate error"),
    )
    events = PipeWireAO._ndarray_filter_events(filter)
    input_data = UInt8[1]
    output_data = UInt8[0]
    input = native_ndarray_filter_buffer(input_data)
    output = native_ndarray_filter_buffer(output_data)
    GC.@preserve input_data output_data input output begin
        @test invoke_ndarray_filter_process_on_foreign_thread(
            events,
            filter,
            input,
            output,
        ) == -Base.Libc.EFAULT
    end
    @test filter.callback_error[] isa ErrorException
    @test sprint(showerror, filter.callback_error[]) == "contained callback error"
    @test invoke_ndarray_filter_prepare(events, filter) == -Base.Libc.EFAULT
    @test invoke_ndarray_filter_deactivate(events, filter) == -Base.Libc.EFAULT
    @test sprint(showerror, filter.callback_error[]) == "contained callback error"
    close(filter)
end
