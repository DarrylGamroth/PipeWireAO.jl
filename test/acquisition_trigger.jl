using PipeWireAO
using Test

@testset "whole-exposure trigger metadata" begin
    native = PipeWireAO.LibPipeWire
    storage = zeros(UInt64, 12)
    fixture = acquisition_fixture(storage)
    GC.@preserve storage fixture begin
        metadata = buffer_acquisition(fixture.buffer)
        initialize_acquisition!(metadata)
        @test acquisition_version(metadata) == 2
        @test acquisition_trigger_state(metadata) == ACQUISITION_TRIGGER_ABSENT
        domain = AcquisitionDomain(ntuple(i -> UInt8(i), 16))
        identity = AcquisitionIdentity(domain, UInt64(2), UInt64(8))
        set_acquisition_identity!(metadata, identity)
        set_acquisition_exposure_duration!(metadata, 10_000)
        for state in (ACQUISITION_TRIGGER_ABSENT, ACQUISITION_TRIGGER_LOW,
                ACQUISITION_TRIGGER_HIGH, ACQUISITION_TRIGGER_MIXED)
            @test set_acquisition_trigger_state!(metadata, state) === metadata
            @test acquisition_version(metadata) == 3
            @test acquisition_trigger_state(metadata) == state
            @test acquisition_identity(metadata) == identity
            @test acquisition_exposure_duration(metadata) == 10_000
            @test acquisition_exposure_start(metadata) === nothing
        end
        ptr = Ptr{native.spa_meta_acquisition}(pointer(storage))
        unsafe_store!(ptr.reserved2, UInt64(4))
        @test !acquisition_valid(metadata)
        @test_throws InvalidStateException acquisition_trigger_state(metadata)
        initialize_acquisition!(metadata)
        unsafe_store!(ptr.version, UInt32(1))
        @test acquisition_valid(metadata)
        @test_throws ArgumentError set_acquisition_trigger_state!(metadata, ACQUISITION_TRIGGER_HIGH)
        initialize_acquisition!(metadata; version=3)
        @test acquisition_valid(metadata)
        @test acquisition_trigger_state(metadata) == ACQUISITION_TRIGGER_ABSENT
        @test_throws ArgumentError initialize_acquisition!(metadata; version=4)
    end
    format = NdArrayFormat(NdArray.F32_LE, (4,); layout=NdArray.COLUMN_MAJOR)
    port = NdArrayFilterPort("frame", PipeWireAO.DIRECTION_INPUT, format; acquisition_version=3)
    ports = PipeWireAO._native_ndarray_filter_ports(NdArrayFilterPort[port])
    @test only(ports.native).flags == native.PW_NDARRAY_FILTER_PORT_FLAG_ACQUISITION_V3
    @test_throws ArgumentError NdArrayFilterPort("frame", PipeWireAO.DIRECTION_INPUT, format; acquisition_version=1)
    @test_throws ArgumentError acquisition_metadata_param(; version=4)
    @test sizeof(native.spa_meta_acquisition) == 96
end

@testset "ndarray borrowed acquisition record" begin
    native = PipeWireAO.LibPipeWire
    storage = native_ndarray_filter_buffer(zeros(UInt8, 16);
        available=native.PW_NDARRAY_FILTER_METADATA_ACQUISITION)
    GC.@preserve storage begin
        output = NdArrayFilterBuffer{true}(Ptr{Cvoid}(pointer(storage)))
        input = NdArrayFilterBuffer{false}(Ptr{Cvoid}(pointer(storage)))
        @test buffer_acquisition(input) === nothing
        record = buffer_acquisition(output)
        @test initialize_acquisition!(record; version=3) === record
        @test acquisition_valid(record)
        domain = AcquisitionDomain(ntuple(i -> UInt8(i), 16))
        identity = AcquisitionIdentity(domain, UInt64(4), UInt64(7))
        set_acquisition_identity!(record, identity)
        set_acquisition_exposure_duration!(record, 5_000)
        set_acquisition_trigger_state!(record, ACQUISITION_TRIGGER_MIXED)
        borrowed = buffer_acquisition(input)
        @test acquisition_identity(borrowed) == identity
        @test acquisition_exposure_duration(borrowed) == 5_000
        @test acquisition_trigger_state(borrowed) == ACQUISITION_TRIGGER_MIXED
        @test_throws MethodError set_acquisition_trigger_state!(borrowed, ACQUISITION_TRIGGER_HIGH)
        @test_throws MethodError initialize_acquisition!(borrowed)
        clear_buffer_acquisition!(output)
        @test buffer_acquisition(input) === nothing
        initialize_acquisition!(output)
        @test acquisition_version(buffer_acquisition(input)) == 2
        @test acquisition_trigger_state(buffer_acquisition(input)) == ACQUISITION_TRIGGER_ABSENT
    end
end

function acquisition_comparison_allocations(a, b)
    acquisition_identity_equal(a, b)
    acquisition_time_difference(a, b)
    acquisition_times_match(a, b, 0)
    return @allocated begin
        acquisition_identity_equal(a, b)
        acquisition_time_difference(a, b)
        acquisition_times_match(a, b, 0)
    end
end

@testset "cleared ndarray acquisition records cannot compare stale fields" begin
    native = PipeWireAO.LibPipeWire
    storage = native_ndarray_filter_buffer(zeros(UInt8, 16);
        available=native.PW_NDARRAY_FILTER_METADATA_ACQUISITION)
    other_storage = native_ndarray_filter_buffer(zeros(UInt8, 16);
        available=native.PW_NDARRAY_FILTER_METADATA_ACQUISITION)
    GC.@preserve storage other_storage begin
        output = NdArrayFilterBuffer{true}(Ptr{Cvoid}(pointer(storage)))
        other_output = NdArrayFilterBuffer{true}(Ptr{Cvoid}(pointer(other_storage)))
        record = initialize_acquisition!(output; version=3)
        other = initialize_acquisition!(other_output; version=3)
        identity = AcquisitionIdentity(AcquisitionDomain(ntuple(UInt8, 16)), UInt64(4), UInt64(7))
        reference = AcquisitionPtpReference(PtpClockIdentity(ntuple(UInt8, 8)), 3)
        for value in (record, other)
            set_acquisition_identity!(value, identity)
            set_acquisition_exposure_start_ptp!(value, 100, 2, reference)
        end
        @test acquisition_identity_equal(record, other)
        @test acquisition_time_difference(record, other) == (Int64(0), UInt64(4))
        @test acquisition_times_match(record, other, 0)
        @test acquisition_comparison_allocations(record, other) == 0
        clear_buffer_acquisition!(output)
        @test !acquisition_valid(record)
        for (a, b) in ((record, record), (record, other), (other, record))
            @test !acquisition_identity_equal(a, b)
            @test acquisition_time_difference(a, b) === nothing
            @test !acquisition_times_match(a, b, 0)
        end
        @test_throws ArgumentError acquisition_times_match(record, other, -1)
    end
end
