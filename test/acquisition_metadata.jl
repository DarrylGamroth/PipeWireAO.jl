using PipeWireAO
using Test

function acquisition_fixture(storage)
    native = PipeWireAO.LibPipeWire
    metas = native.spa_meta[
        native.spa_meta(
            native.SPA_META_Acquisition,
            UInt32(sizeof(native.spa_meta_acquisition)),
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
    buffer = StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer}, native_buffer))
    return (; buffer, metas, spa_buffer, native_buffer)
end

function update_acquisition_hot_path(metadata, identity)
    initialize_acquisition!(metadata)
    set_acquisition_identity!(metadata, identity)
    set_acquisition_exposure_start!(metadata, Int64(123_456), UInt64(9))
    set_acquisition_exposure_duration!(metadata, UInt64(5_000))
    acquisition_flags(metadata)
    acquisition_identity(metadata)
    acquisition_exposure_start(metadata)
    acquisition_timebase(metadata)
    acquisition_ptp_reference(metadata)
    acquisition_exposure_duration(metadata)
    return nothing
end

function acquisition_hot_path_allocations(metadata, identity)
    update_acquisition_hot_path(metadata, identity)
    return @allocated update_acquisition_hot_path(metadata, identity)
end

@testset "acquisition metadata" begin
    native = PipeWireAO.LibPipeWire
    words = div(Int(native.SPA_META_ACQUISITION_SIZE), sizeof(UInt64))
    storage_a = zeros(UInt64, words)
    storage_b = zeros(UInt64, words)
    fixture_a = acquisition_fixture(storage_a)
    fixture_b = acquisition_fixture(storage_b)

    domain_bytes = ntuple(
        index -> index == 1 ? UInt8(1) : UInt8(0),
        Val(ACQUISITION_DOMAIN_SIZE),
    )
    grandmaster_bytes = ntuple(
        index -> index == 1 ? UInt8(2) : UInt8(0),
        Val(ACQUISITION_PTP_CLOCK_ID_SIZE),
    )
    other_grandmaster_bytes = ntuple(
        index -> index == 1 ? UInt8(3) : UInt8(0),
        Val(ACQUISITION_PTP_CLOCK_ID_SIZE),
    )
    domain = AcquisitionDomain(domain_bytes)
    identity = AcquisitionIdentity(domain, UInt64(7), UInt64(42))
    grandmaster = PtpClockIdentity(grandmaster_bytes)
    reference = AcquisitionPtpReference(grandmaster, 7)

    @test_throws ArgumentError AcquisitionDomain(
        ntuple(_ -> UInt8(0), Val(ACQUISITION_DOMAIN_SIZE)),
    )
    @test_throws ArgumentError PtpClockIdentity(
        ntuple(_ -> UInt8(0), Val(ACQUISITION_PTP_CLOCK_ID_SIZE)),
    )
    @test_throws ArgumentError AcquisitionPtpReference(grandmaster, -1)
    @test_throws ArgumentError AcquisitionPtpReference(grandmaster, 256)
    @test isbitstype(AcquisitionDomain)
    @test isbitstype(AcquisitionIdentity)
    @test isbitstype(AcquisitionExposureStart)
    @test isbitstype(AcquisitionPtpReference)
    @test isbitstype(PtpClockIdentity)
    @test sizeof(native.spa_meta_acquisition) == Int(native.SPA_META_ACQUISITION_SIZE) == 96
    @test ACQUISITION_DOMAIN_SIZE == Int(native.SPA_META_ACQUISITION_DOMAIN_SIZE) == 16
    @test ACQUISITION_PTP_CLOCK_ID_SIZE ==
          Int(native.SPA_META_ACQUISITION_PTP_CLOCK_ID_SIZE) == 8
    @test ACQUISITION_WIRE_SIZE == Int(native.SPA_META_ACQUISITION_WIRE_SIZE) == 96
    @test ACQUISITION_FLAG_IDENTITY_VALID ==
          native.SPA_META_ACQUISITION_FLAG_IDENTITY_VALID
    @test ACQUISITION_FLAG_EXPOSURE_START_VALID ==
          native.SPA_META_ACQUISITION_FLAG_EXPOSURE_START_VALID
    @test ACQUISITION_FLAG_EXPOSURE_DURATION_VALID ==
          native.SPA_META_ACQUISITION_FLAG_EXPOSURE_DURATION_VALID
    @test ACQUISITION_FLAG_PTP_REFERENCE_VALID ==
          native.SPA_META_ACQUISITION_FLAG_PTP_REFERENCE_VALID

    GC.@preserve storage_a storage_b fixture_a fixture_b begin
        metadata_a = buffer_acquisition(fixture_a.buffer)
        metadata_b = buffer_acquisition(fixture_b.buffer)
        @test metadata_a isa AcquisitionMetadata{StreamBuffer}
        @test metadata_b isa AcquisitionMetadata{StreamBuffer}
        @test !acquisition_valid(metadata_a)

        pointer_a = Ptr{native.spa_meta_acquisition}(Base.pointer(storage_a))
        base = UInt(pointer_a)
        @test base & UInt(7) == 0
        @test UInt(pointer_a.timebase) - base == 12
        @test UInt(pointer_a.domain) - base == 16
        @test UInt(pointer_a.generation) - base == 32
        @test UInt(pointer_a.sequence) - base == 40
        @test UInt(pointer_a.exposure_start_nsec) - base == 48
        @test UInt(pointer_a.ptp_grandmaster_id) - base == 72
        @test UInt(pointer_a.ptp_domain_number) - base == 80
        @test UInt(pointer_a.reserved2) - base == 88

        @test initialize_acquisition!(metadata_a) === metadata_a
        @test initialize_acquisition!(metadata_b) === metadata_b
        @test acquisition_valid(metadata_a)
        @test unsafe_load(pointer_a.version) == native.SPA_META_ACQUISITION_VERSION_2
        @test acquisition_flags(metadata_a) == UInt32(0)
        @test acquisition_identity(metadata_a) === nothing
        @test acquisition_exposure_start(metadata_a) === nothing
        @test acquisition_timebase(metadata_a) === nothing
        @test acquisition_ptp_reference(metadata_a) === nothing
        @test acquisition_exposure_duration(metadata_a) === nothing
        @test !acquisition_identity_equal(metadata_a, metadata_b)

        @test set_acquisition_identity!(metadata_a, identity) === metadata_a
        @test set_acquisition_identity!(metadata_b, identity) === metadata_b
        @test acquisition_identity(metadata_a) == identity
        @test acquisition_identity_equal(metadata_a, metadata_b)

        @test set_acquisition_exposure_start!(metadata_a, 123_456, 9) === metadata_a
        @test set_acquisition_exposure_duration!(metadata_a, 5_000) === metadata_a
        @test acquisition_exposure_start(metadata_a) ==
              AcquisitionExposureStart(Int64(123_456), UInt64(9))
        @test acquisition_timebase(metadata_a) == ACQUISITION_TIMEBASE_MONOTONIC
        @test acquisition_ptp_reference(metadata_a) === nothing
        @test acquisition_exposure_duration(metadata_a) == UInt64(5_000)
        @test acquisition_valid(metadata_a)
        @test_throws ArgumentError set_acquisition_exposure_start!(metadata_a, -1, 0)
        @test_throws ArgumentError set_acquisition_exposure_duration!(metadata_a, 0)

        different = AcquisitionIdentity(domain, UInt64(7), UInt64(43))
        initialize_acquisition!(metadata_b)
        set_acquisition_identity!(metadata_b, different)
        @test !acquisition_identity_equal(metadata_a, metadata_b)

        update_acquisition_hot_path(metadata_a, identity)
        @test acquisition_hot_path_allocations(metadata_a, identity) == 0

        initialize_acquisition!(metadata_a)
        initialize_acquisition!(metadata_b)
        set_acquisition_identity!(metadata_a, identity)
        set_acquisition_identity!(metadata_b, identity)
        @test set_acquisition_exposure_start_ptp!(metadata_a, 123_456, 9, reference) ===
              metadata_a
        @test set_acquisition_exposure_start_ptp!(metadata_b, 123_500, 11, reference) ===
              metadata_b
        @test acquisition_timebase(metadata_a) == ACQUISITION_TIMEBASE_TAI
        @test acquisition_ptp_reference(metadata_a) == reference
        @test acquisition_time_difference(metadata_a, metadata_b) == (Int64(-44), UInt64(20))
        @test !acquisition_times_match(metadata_a, metadata_b, 23)
        @test acquisition_times_match(metadata_a, metadata_b, 24)
        @test_throws ArgumentError acquisition_times_match(metadata_a, metadata_b, -1)

        wire = acquisition_wire(metadata_a)
        @test length(wire) == ACQUISITION_WIRE_SIZE
        @test wire[1:4] == UInt8[0, 0, 0, 2]
        @test deserialize_acquisition!(metadata_b, wire) === metadata_b
        @test acquisition_identity(metadata_b) == identity
        @test acquisition_ptp_reference(metadata_b) == reference
        @test acquisition_time_difference(metadata_b, metadata_a) == (Int64(0), UInt64(18))

        malformed_wire = copy(wire)
        malformed_wire[82] = 1
        @test_throws ArgumentError deserialize_acquisition!(metadata_b, malformed_wire)
        @test acquisition_ptp_reference(metadata_b) == reference
        @test_throws ArgumentError deserialize_acquisition!(metadata_b, wire[1:(end - 1)])

        other_reference = AcquisitionPtpReference(
            PtpClockIdentity(other_grandmaster_bytes),
            7,
        )
        set_acquisition_exposure_start_ptp!(metadata_b, 123_500, 11, other_reference)
        @test acquisition_time_difference(metadata_a, metadata_b) === nothing
        @test !acquisition_times_match(metadata_a, metadata_b, typemax(UInt64))
        set_acquisition_exposure_start!(metadata_b, 123_500, 11)
        @test acquisition_timebase(metadata_b) == ACQUISITION_TIMEBASE_MONOTONIC
        @test acquisition_ptp_reference(metadata_b) === nothing
        @test acquisition_time_difference(metadata_a, metadata_b) === nothing

        initialize_acquisition!(metadata_a)
        unsafe_store!(pointer_a.version, native.SPA_META_ACQUISITION_VERSION_1)
        @test acquisition_valid(metadata_a)
        set_acquisition_exposure_start!(metadata_a, 123_456, 9)
        @test acquisition_timebase(metadata_a) == ACQUISITION_TIMEBASE_MONOTONIC
        @test_throws InvalidStateException acquisition_wire(metadata_a)

        initialize_acquisition!(metadata_a)
        set_acquisition_identity!(metadata_a, identity)
        unsafe_store!(
            pointer_a.reserved,
            ntuple(index -> index == 1 ? UInt8(1) : UInt8(0), Val(7)),
        )
        @test !acquisition_valid(metadata_a)
        @test_throws InvalidStateException acquisition_identity(metadata_a)
        initialize_acquisition!(metadata_a)
        set_acquisition_identity!(metadata_a, identity)
        unsafe_store!(pointer_a.flags, unsafe_load(pointer_a.flags) | UInt32(1 << 31))
        @test !acquisition_valid(metadata_a)
        initialize_acquisition!(metadata_a)
        set_acquisition_identity!(metadata_a, identity)
        unsafe_store!(pointer_a.domain, ntuple(_ -> UInt8(0), Val(ACQUISITION_DOMAIN_SIZE)))
        @test !acquisition_valid(metadata_a)

        fixture_a.metas[1] = native.spa_meta(
            native.SPA_META_Acquisition,
            UInt32(sizeof(native.spa_meta_acquisition) - 1),
            Ptr{Cvoid}(Base.pointer(storage_a)),
        )
        @test_throws InvalidStateException buffer_acquisition(fixture_a.buffer)
        fixture_a.metas[1] = native.spa_meta(
            native.SPA_META_Acquisition,
            UInt32(sizeof(native.spa_meta_acquisition)),
            Ptr{Cvoid}(Ptr{UInt8}(Base.pointer(storage_a)) + 1),
        )
        @test_throws InvalidStateException buffer_acquisition(fixture_a.buffer)
    end

    parameter = acquisition_metadata_param()
    properties = Dict(property.key => property for property in parameter.object.properties)
    @test pod_value(SPA.Id, properties[SPA.META_PARAM_TYPE].value) ==
          SPA.Id(SPA.META_ACQUISITION)
    @test pod_value(Int32, properties[SPA.META_PARAM_SIZE].value) ==
          Int32(native.SPA_META_ACQUISITION_SIZE)
    @test pod_value(Int32, properties[SPA.META_PARAM_FEATURES].value) ==
          Int32(native.SPA_META_FEATURE_ACQUISITION_CURRENT)
end
