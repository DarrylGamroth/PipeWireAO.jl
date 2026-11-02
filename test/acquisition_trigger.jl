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
