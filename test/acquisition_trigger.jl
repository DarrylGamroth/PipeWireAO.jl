using PipeWireAO, Test
include("native_sdk.jl")

@testset "borrowed callback Properties retain acquisition facts" begin
    native = PipeWireAO.LibPipeWire
    storage = native_ndarray_filter_buffer(zeros(UInt8, 16);
        available=native.PW_NDARRAY_FILTER_METADATA_HEADER | native.PW_NDARRAY_FILTER_METADATA_PROPERTIES,
        valid=native.PW_NDARRAY_FILTER_METADATA_HEADER | native.PW_NDARRAY_FILTER_METADATA_PROPERTIES,
        sequence=UInt64(999))
    GC.@preserve storage begin
        output = NdArrayFilterBuffer{true}(Ptr{Cvoid}(pointer(storage)))
        input = NdArrayFilterBuffer{false}(Ptr{Cvoid}(pointer(storage)))
        identity = AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8, 16)), UInt64(0), typemax(UInt64))
        for trigger in (ACQUISITION_TRIGGER_ABSENT, ACQUISITION_TRIGGER_LOW,
                ACQUISITION_TRIGGER_HIGH, ACQUISITION_TRIGGER_MIXED)
            properties = initialize_buffer_properties!(output)
            @test trigger_classification(properties) === nothing
            set_optical_classification!(properties, OPTICAL_FRINGED)
            set_trigger_classification!(properties, trigger)
            set_acquisition_identity!(properties, identity)
            set_acquisition_exposure_duration!(properties, typemax(UInt64))
            borrowed = buffer_properties(input)
            @test borrowed isa BufferProperties{false}
            @test acquisition_identity(borrowed) == identity
            @test acquisition_exposure_duration(borrowed) == typemax(UInt64)
            @test trigger_classification(borrowed) === trigger
            @test optical_classification(borrowed) === OPTICAL_FRINGED
            @test buffer_header(input).sequence == 999 != identity.sequence
            @test_throws MethodError initialize_buffer_properties!(borrowed)
            @test_throws MethodError set_trigger_classification!(borrowed, ACQUISITION_TRIGGER_LOW)
            @test_throws MethodError set_acquisition_identity!(borrowed, identity)
        end
        initialize_buffer_properties!(output)
        borrowed = buffer_properties(input)
        @test acquisition_identity(borrowed) === nothing
        @test acquisition_exposure_duration(borrowed) === nothing
        @test optical_classification(borrowed) === nothing
        @test trigger_classification(borrowed) === nothing
        @test !acquisition_identity_equal(borrowed, borrowed)
        @test acquisition_time_difference(borrowed, borrowed) === nothing
        @test !acquisition_times_match(borrowed, borrowed, 0)
    end
end

clear_metadata_allocations(buffer) = @allocated clear_buffer_metadata!(buffer)

@testset "cleared derived callback output cannot expose stale facts" begin
    native = PipeWireAO.LibPipeWire
    mask = native.PW_NDARRAY_FILTER_METADATA_HEADER | native.PW_NDARRAY_FILTER_METADATA_PROPERTIES
    storage = native_ndarray_filter_buffer(UInt8[1]; available=mask, valid=mask, sequence=UInt64(9))
    GC.@preserve storage begin
        output = NdArrayFilterBuffer{true}(Ptr{Cvoid}(pointer(storage)))
        input = NdArrayFilterBuffer{false}(Ptr{Cvoid}(pointer(storage)))
        properties = initialize_buffer_properties!(output)
        set_trigger_classification!(properties, ACQUISITION_TRIGGER_HIGH)
        set_acquisition_identity!(properties, AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8, 16)), UInt64(3), UInt64(7)))
        @test clear_buffer_metadata!(output) === output
        @test buffer_properties(input) === nothing
        @test buffer_header(input) === nothing
        @test unsafe_load(pointer(storage)).metadata_valid == 0
        @test all(iszero, @view(storage.properties[3:end]))
        @test clear_metadata_allocations(output) == 0
        properties = initialize_buffer_properties!(output)
        @test buffer_properties(input) isa BufferProperties{false}
        @test buffer_header(input) === nothing
        @test acquisition_identity(properties) === nothing
        @test trigger_classification(properties) === nothing
        @test_throws MethodError clear_buffer_metadata!(input)
    end
end
