using PipeWireAO, Test
include("native_sdk.jl")

function acquisition_update!(properties, identity)
    initialize_buffer_properties!(properties)
    set_acquisition_identity!(properties, identity)
    set_acquisition_exposure_duration!(properties, UInt64(5_000))
    set_acquisition_exposure_start!(properties, Int64(123_456), UInt64(9))
    acquisition_identity(properties)
    acquisition_exposure_start(properties)
    acquisition_timebase(properties)
    acquisition_ptp_reference(properties)
    acquisition_exposure_duration(properties)
    return nothing
end

function acquisition_allocations(properties, identity)
    acquisition_update!(properties, identity)
    return @allocated acquisition_update!(properties, identity)
end

@testset "complete acquisition facts in Properties" begin
    native = PipeWireAO.LibPipeWire
    a, b = properties_fixture(512), properties_fixture(512)
    domain = AcquisitionDomain(ntuple(UInt8, 16))
    grandmaster = PtpClockIdentity(ntuple(UInt8, 8))
    reference = AcquisitionPtpReference(grandmaster, 255)
    @test ACQUISITION_DOMAIN_SIZE == native.SPA_ACQUISITION_DOMAIN_SIZE == 16
    @test ACQUISITION_PTP_CLOCK_ID_SIZE == native.SPA_EXPOSURE_PTP_CLOCK_ID_SIZE == 8
    @test isbitstype(AcquisitionIdentity) && isbitstype(AcquisitionExposureStart)
    @test isbitstype(AcquisitionDomain) && isbitstype(AcquisitionPtpReference)
    @test_throws ArgumentError AcquisitionDomain(ntuple(_ -> UInt8(0), 16))
    @test_throws ArgumentError PtpClockIdentity(ntuple(_ -> UInt8(0), 8))
    @test_throws ArgumentError AcquisitionPtpReference(grandmaster, -1)
    @test_throws ArgumentError AcquisitionPtpReference(grandmaster, 256)
    GC.@preserve a b begin
        left, right = initialize_buffer_properties!(a.buffer), initialize_buffer_properties!(b.buffer)
        @test acquisition_identity(left) === nothing
        @test acquisition_exposure_start(left) === nothing
        @test acquisition_exposure_duration(left) === nothing
        @test acquisition_timebase(left) === nothing
        @test acquisition_ptp_reference(left) === nothing
        @test !acquisition_identity_equal(left, right)
        for value in (UInt64(0), UInt64(typemax(Int64)), UInt64(1) << 63, typemax(UInt64))
            identity = AcquisitionIdentity(domain, value, value)
            initialize_buffer_properties!(left)
            @test set_acquisition_identity!(left, identity) === left
            @test acquisition_identity(left) == identity
            @test set_acquisition_exposure_duration!(left, typemax(UInt64)) === left
            @test acquisition_exposure_duration(left) == typemax(UInt64)
            @test buffer_properties_valid(left)
        end
        identity = AcquisitionIdentity(domain, UInt64(7), UInt64(42))
        acquisition_update!(left, identity)
        @test acquisition_exposure_start(left) == AcquisitionExposureStart(123_456, UInt64(9))
        @test acquisition_timebase(left) == ACQUISITION_TIMEBASE_MONOTONIC
        @test acquisition_ptp_reference(left) === nothing
        @test acquisition_allocations(left, identity) == 0
        for bad in (-1, big(typemax(UInt64)) + 1)
            @test_throws ArgumentError set_acquisition_exposure_duration!(left, bad)
        end
        @test_throws ArgumentError set_acquisition_exposure_duration!(left, 0)
        @test_throws ArgumentError set_acquisition_exposure_start!(left, -1, 0)
        @test_throws ArgumentError set_acquisition_exposure_start!(left, 0, -1)
        initialize_buffer_properties!(left)
        set_buffer_property!(left, BUFFER_PROPERTY_ACQUISITION_DOMAIN, domain.bytes)
        @test !buffer_properties_valid(left)
        @test_throws InvalidStateException acquisition_identity(left)
        set_buffer_property!(left, BUFFER_PROPERTY_ACQUISITION_GENERATION, typemax(UInt64))
        @test !buffer_properties_valid(left)
        set_buffer_property!(left, BUFFER_PROPERTY_ACQUISITION_SEQUENCE, UInt64(0))
        @test buffer_properties_valid(left)
        @test acquisition_identity(left) == AcquisitionIdentity(domain, typemax(UInt64), UInt64(0))
        for (start, error) in ((Int64(123_456), UInt64(9)), (typemax(Int64), typemax(UInt64)))
            initialize_buffer_properties!(left)
            initialize_buffer_properties!(right)
            set_acquisition_exposure_start_ptp!(left, start, error, reference)
            set_acquisition_exposure_start_ptp!(right, start, error, reference)
            @test acquisition_ptp_reference(left) == reference
            @test acquisition_timebase(left) == ACQUISITION_TIMEBASE_TAI
            expected_error = error == typemax(UInt64) ? typemax(UInt64) : 2error
            @test acquisition_time_difference(left, right) == (Int64(0), expected_error)
            @test acquisition_times_match(left, right, typemax(UInt64))
        end
        initialize_buffer_properties!(left); initialize_buffer_properties!(right)
        set_acquisition_exposure_start_ptp!(left, 123_456, 9, reference)
        set_acquisition_exposure_start_ptp!(right, 123_500, 11, reference)
        @test acquisition_time_difference(left, right) == (Int64(-44), UInt64(20))
        @test !acquisition_times_match(left, right, 23)
        @test acquisition_times_match(left, right, 24)
        @test_throws ArgumentError acquisition_times_match(left, right, -1)
        initialize_buffer_properties!(right)
        set_acquisition_exposure_start_ptp!(right, 123_500, 11, AcquisitionPtpReference(grandmaster, 254))
        @test acquisition_time_difference(left, right) === nothing
        initialize_buffer_properties!(right)
        other_clock = PtpClockIdentity(ntuple(i -> UInt8(i + 1), 8))
        set_acquisition_exposure_start_ptp!(right, 123_500, 11, AcquisitionPtpReference(other_clock, 255))
        @test acquisition_time_difference(left, right) === nothing
        initialize_buffer_properties!(right)
        set_acquisition_exposure_start!(right, 123_500, 11)
        @test acquisition_time_difference(left, right) === nothing
        @test !acquisition_times_match(left, right, typemax(UInt64))
        initialize_buffer_properties!(left)
        set_buffer_property!(left, BUFFER_PROPERTY_EXPOSURE_START, Int64(0))
        @test !buffer_properties_valid(left)
        set_buffer_property!(left, BUFFER_PROPERTY_EXPOSURE_TIMEBASE, SPA.Id(UInt32(ACQUISITION_TIMEBASE_TAI)))
        set_buffer_property!(left, BUFFER_PROPERTY_TIMESTAMP_UNCERTAINTY, UInt64(0))
        @test !buffer_properties_valid(left)
        set_buffer_property!(left, BUFFER_PROPERTY_PTP_GRANDMASTER_IDENTITY, grandmaster.bytes)
        @test !buffer_properties_valid(left)
        set_buffer_property!(left, BUFFER_PROPERTY_PTP_DOMAIN_NUMBER, SPA.Id(UInt32(255)))
        @test buffer_properties_valid(left)
        initialize_buffer_properties!(left)
        set_buffer_property!(left, 20, UInt64(0x0102030405060708))
        pod = native.spa_meta_properties_find(Ref(left.metadata), UInt32(20))
        @test unsafe_load(Ptr{NTuple{8,UInt8}}(Ptr{UInt8}(pod) + sizeof(native.spa_pod))) ==
            (0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01)
        @test buffer_property(left, 20, UInt64) == UInt64(0x0102030405060708)
        initialize_buffer_properties!(left)
        @test acquisition_identity(left) === nothing
        @test acquisition_exposure_start(left) === nothing
        @test !acquisition_identity_equal(left, right)
    end
end
