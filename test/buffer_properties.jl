include("native_sdk.jl")
using PipeWireAO, Test

function properties_fixture(capacity=256)
    native = PipeWireAO.LibPipeWire
    storage = zeros(UInt64, div(capacity, 8))
    metas = [native.spa_meta(native.SPA_META_Properties, UInt32(capacity), Ptr{Cvoid}(pointer(storage)))]
    spa_buffer = Ref(native.spa_buffer(UInt32(1), UInt32(0), pointer(metas), C_NULL))
    native_buffer = Ref(native.pw_buffer(
        Base.unsafe_convert(Ptr{native.spa_buffer}, spa_buffer), C_NULL, 0, 0, 0,
    ))
    buffer = StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer}, native_buffer))
    return (; storage, metas, spa_buffer, native_buffer, buffer)
end

function properties_hot_path(buffer, requirements)
    properties = initialize_buffer_properties!(buffer)
    set_optical_classification!(properties, OPTICAL_FRINGED)
    set_trigger_classification!(properties, ACQUISITION_TRIGGER_LOW)
    set_buffer_property!(properties, 20, Int64(42))
    buffer_properties_valid(properties, requirements)
    optical_classification(properties)
    buffer_property(properties, 20, Int64)
    return nothing
end

function properties_allocations(buffer, requirements)
    properties_hot_path(buffer, requirements)
    return @allocated properties_hot_path(buffer, requirements)
end

@testset "typed per-buffer properties and recycled outputs" begin
    native = PipeWireAO.LibPipeWire
    fixture = properties_fixture()
    requirements = (BufferPropertyRequirement(BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, SPA.Id),
        BufferPropertyRequirement(20, Int64))
    GC.@preserve fixture begin
        properties = buffer_properties(fixture.buffer)
        @test isbitstype(typeof(properties))
        @test !buffer_properties_valid(properties)
        @test initialize_buffer_properties!(properties) === properties
        @test buffer_properties_valid(properties)
        @test optical_classification(properties) === nothing
        @test !buffer_properties_valid(properties, requirements)
        for classification in (OPTICAL_ABSENT, OPTICAL_UNFRINGED, OPTICAL_FRINGED, OPTICAL_MIXED)
            initialize_buffer_properties!(properties)
            @test set_optical_classification!(properties, classification) === properties
            @test optical_classification(properties) === classification
        end
        set_trigger_classification!(properties, ACQUISITION_TRIGGER_LOW)
        @test optical_classification(properties) === OPTICAL_MIXED
        @test trigger_classification(properties) === ACQUISITION_TRIGGER_LOW

        values = (true, SPA.Id(7), Int32(-12), Int64(42), 1.25f0, 2.5)
        for (index, value) in enumerate(values)
            @test set_buffer_property!(properties, 19 + index, value) === properties
            result = buffer_property(properties, 19 + index, typeof(value))
            @test result === value
        end
        @test_throws ArgumentError buffer_property(properties, 20, Float32)
        @test_throws ArgumentError buffer_property(properties, 20, UInt64)
        @test_throws ArgumentError set_buffer_property!(properties, 20, Int32(0))
        @test_throws ArgumentError set_buffer_property!(properties, 1, SPA.Id(1))
        @test_throws MethodError set_optical_classification!(
            BufferProperties{false}(properties.metadata), OPTICAL_FRINGED,
        )
        @test properties_allocations(fixture.buffer, requirements) == 0
        @test buffer_properties_valid(properties, requirements)
        initialize_buffer_properties!(fixture.buffer)
        @test optical_classification(properties) === nothing
        @test buffer_property(properties, 20, Int64) === nothing
        @test all(iszero, @view(fixture.storage[3:end]))

        set_buffer_property!(properties, 20, Int64(5))
        pod = native.spa_meta_properties_find(Ref(properties.metadata), UInt32(20))
        flags = Ptr{UInt32}(Ptr{UInt8}(pod) - 4)
        unsafe_store!(flags, SPA.PROPERTY_MANDATORY)
        @test !buffer_properties_valid(properties)
        known = (BufferPropertyRequirement(20, Int64),)
        @test buffer_properties_valid(properties, known)
        supported = buffer_properties(fixture.buffer; required_buffer_properties=known)
        @test buffer_property(supported, 20, Int64) == 5
        @test !buffer_properties_valid(properties, (BufferPropertyRequirement(20, Int32),))
        unsafe_store!(Ptr{UInt32}(pod), typemax(UInt32))
        @test !buffer_properties_valid(properties, known)
        @test_throws InvalidStateException buffer_property(supported, 20, Int64)
    end

    tiny = properties_fixture(16)
    GC.@preserve tiny begin
        properties = initialize_buffer_properties!(tiny.buffer)
        @test_throws ArgumentError set_optical_classification!(properties, OPTICAL_FRINGED)
        @test buffer_properties_valid(properties)
    end
end

@testset "properties metadata requests and ndarray port opt-in" begin
    native = PipeWireAO.LibPipeWire
    format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.COLUMN_MAJOR)
    requirement = BufferPropertyRequirement(BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, SPA.Id)
    default = NdArrayFilterPort("default", PipeWireAO.DIRECTION_OUTPUT, format)
    @test default.buffer_properties_capacity == 512
    @test isempty(default.required_buffer_properties)
    for capacity in (40, 64, 4064)
        port = NdArrayFilterPort("properties", PipeWireAO.DIRECTION_OUTPUT, format;
            buffer_properties_capacity=capacity, required_buffer_properties=(requirement,))
        @test port.buffer_properties_capacity == capacity
        @test only(port.required_buffer_properties).key == BUFFER_PROPERTY_OPTICAL_CLASSIFICATION
        filter = NdArrayFilter("test.properties.$capacity", (port,); on_process=(args...) -> nothing)
        @test isopen(filter)
        close(filter)
    end
    too_small = NdArrayFilterPort("properties",PipeWireAO.DIRECTION_OUTPUT,format;
        buffer_properties_capacity=16,required_buffer_properties=(requirement,))
    @test_throws PipeWireError NdArrayFilter("test.properties.too-small",(too_small,);on_process=(args...)->nothing)
    parameter = buffer_properties_metadata_param(4096)
    properties = Dict(property.key => property for property in parameter.object.properties)
    @test pod_value(SPA.Id, properties[SPA.META_PARAM_TYPE].value) == SPA.Id(SPA.META_PROPERTIES)
    @test pod_value(Int32, properties[SPA.META_PARAM_SIZE].value) == 4096
    @test pod_value(Int32, properties[SPA.META_PARAM_FEATURES].value) == native.SPA_META_FEATURE_PROPERTIES_VERSION_1
    for capacity in (-1, 0, 8, 17, 4104)
        @test_throws ArgumentError buffer_properties_metadata_param(capacity)
    end
    @test_throws ArgumentError BufferPropertyRequirement(0, SPA.Id)
    @test_throws ArgumentError BufferPropertyRequirement(BUFFER_PROPERTY_OPTICAL_CLASSIFICATION, Int32)
    @test_throws MethodError BufferPropertyRequirement(2, UInt16)
    @test NdArrayFilterPort("required", PipeWireAO.DIRECTION_INPUT, format;
        required_buffer_properties=(requirement,)).buffer_properties_capacity == 512
    @test_throws ArgumentError NdArrayFilterPort("bad", PipeWireAO.DIRECTION_INPUT, format;
        buffer_properties_capacity=4096)
    @test_throws ArgumentError NdArrayFilterPort("bad", PipeWireAO.DIRECTION_INPUT, format;
        buffer_properties_capacity=64, required_buffer_properties=(requirement, requirement))
    @test sizeof(native.spa_meta_property_requirement) == 8
end

@testset "independent optical and electrical classification" begin
    fixture = properties_fixture()
    GC.@preserve fixture begin
        properties = initialize_buffer_properties!(fixture.buffer)
        @test trigger_classification(properties) === nothing
        for trigger in (ACQUISITION_TRIGGER_ABSENT, ACQUISITION_TRIGGER_LOW,
                ACQUISITION_TRIGGER_HIGH, ACQUISITION_TRIGGER_MIXED)
            initialize_buffer_properties!(properties)
            set_optical_classification!(properties, OPTICAL_UNFRINGED)
            @test set_trigger_classification!(properties, trigger) === properties
            @test trigger_classification(properties) === trigger
            @test optical_classification(properties) === OPTICAL_UNFRINGED
            @test buffer_properties_valid(properties)
        end
        initialize_buffer_properties!(properties)
        @test_throws ArgumentError set_buffer_property!(properties, BUFFER_PROPERTY_TRIGGER_CLASSIFICATION, Int32(1))
        @test_throws ArgumentError set_buffer_property!(properties, BUFFER_PROPERTY_TRIGGER_CLASSIFICATION, SPA.Id(4))
        @test_throws ArgumentError BufferPropertyRequirement(BUFFER_PROPERTY_TRIGGER_CLASSIFICATION, Int32)
        @test_throws MethodError set_trigger_classification!(BufferProperties{false}(properties.metadata), ACQUISITION_TRIGGER_HIGH)
        @test trigger_classification(properties) === nothing
    end
end

@testset "complete optional property propagation" begin
    input = properties_fixture(128)
    output = properties_fixture(256)
    small = properties_fixture(16)
    GC.@preserve input output small begin
        properties = initialize_buffer_properties!(input.buffer)
        set_optical_classification!(properties, OPTICAL_UNFRINGED)
        set_buffer_property!(properties, 25, Int64(991))
        PipeWireAO._propagate_buffer_properties!(output.buffer, input.buffer)
        copied = buffer_properties(output.buffer)
        @test optical_classification(copied) === OPTICAL_UNFRINGED
        @test buffer_property(copied, 25, Int64) == 991
        @test buffer_properties_valid(copied)
        @test_throws ArgumentError PipeWireAO._propagate_buffer_properties!(small.buffer, input.buffer)
        initialize_buffer_properties!(input.buffer)
        PipeWireAO._propagate_buffer_properties!(output.buffer, input.buffer)
        @test optical_classification(copied) === nothing
        @test buffer_property(copied, 25, Int64) === nothing
    end
end

@testset "callback port indices exclude Parameter Ports" begin
    format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.COLUMN_MAJOR)
    parameter = NdArrayFilterPort("parameter", PipeWireAO.DIRECTION_INPUT, format; parameter=true)
    input = NdArrayFilterPort("frame", PipeWireAO.DIRECTION_INPUT, format; buffer_properties_capacity=64)
    output = NdArrayFilterPort("output", PipeWireAO.DIRECTION_OUTPUT, format)
    filter = NdArrayFilter("test.properties.indices", (parameter, input, output);
        on_process=(args...) -> nothing, on_parameter=(args...) -> true)
    try
        @test filter.input_port_indices == UInt32[1]
        @test filter.output_port_indices == UInt32[0]
        buffer = NdArrayFilterBuffer{false}(C_NULL, filter.handle, UInt32(PipeWireAO.DIRECTION_INPUT), UInt32(1))
        @test_throws InvalidStateException buffer_properties(buffer)
        @test_throws ArgumentError NdArrayFilterPort("parameter", PipeWireAO.DIRECTION_INPUT, format;
            parameter=true, buffer_properties_capacity=64)
    finally
        close(filter)
    end
end
