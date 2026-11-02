using PipeWireAO, Test
const _METADATA_TEST_DOMAIN=ntuple(UInt8,16)
function records_fixture(;custom=true)
    native=PipeWireAO.LibPipeWire
    types=(SPA.META_HEADER,SPA.META_ACQUISITION_IDENTITY,SPA.META_EXPOSURE_TIMING,
        SPA.META_ABSOLUTE_TIME,SPA.META_OPTICAL_CHOPPING,SPA.META_ELECTRICAL_TRIGGER)
    entries=[type=>zeros(UInt8,Int(native.spa_meta_record_size(type))) for type in types]
    custom && push!(entries,UInt32(0x900)=>UInt8[1,2,3,4,5,6,7,8])
    snapshot=MetadataSnapshot(entries)
    spa=Ref(native.spa_buffer(snapshot.count,0,pointer(snapshot.descriptors),C_NULL))
    packet=Ref(native.pw_buffer(Base.unsafe_convert(Ptr{native.spa_buffer},spa),C_NULL,0,0,0))
    buffer=StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer},packet))
    return (;snapshot,spa,packet,buffer)
end
function records_update!(buffer,identity,time)
    initialize_metadata!(buffer)
    set_acquisition_identity!(buffer,identity)
    set_exposure_timing!(buffer,ExposureTiming(123;clock=METADATA_CLOCK_MODEL,clock_domain=_METADATA_TEST_DOMAIN,
        duration_nanoseconds=5000,uncertainty_nanoseconds=0))
    set_absolute_times!(buffer,(time,))
    set_optical_classification!(buffer,OPTICAL_FRINGED)
    set_trigger_classification!(buffer,ACQUISITION_TRIGGER_LOW)
    acquisition_identity(buffer)
    exposure_timing(buffer)
    absolute_times(buffer)
    optical_classification(buffer)
    trigger_classification(buffer)
    return nothing
end
function records_allocations(buffer,identity,time,snapshot)
    records_update!(buffer,identity,time)
    capture_metadata!(snapshot,buffer)
    return @allocated begin
        records_update!(buffer,identity,time)
        capture_metadata!(snapshot,buffer)
    end
end
@testset "independent metadata ABI and validity" begin
    n=PipeWireAO.LibPipeWire
    @test sizeof(n.spa_meta_acquisition_identity)==40
    @test sizeof(n.spa_meta_exposure_timing)==64
    @test sizeof(n.spa_meta_absolute_time_event)==80
    @test sizeof(n.spa_meta_absolute_time)==336
    @test sizeof(n.spa_meta_optical_chopping)==8
    @test sizeof(n.pw_ndarray_filter_buffer)==40
    @test fieldnames(n.pw_ndarray_filter_buffer)==(:struct_size,:flags,:data,:size,:capacity,:n_metas,:reserved,:metas)
    @test isbitstype(AbsoluteTime) && isbitstype(ExposureTiming) && isbitstype(AbsoluteTimes)
    @test !isdefined(PipeWireAO,:BufferProperties)
    @test !isdefined(PipeWireAO,:set_acquisition_exposure_start_ptp!)
    @test_throws ArgumentError MetadataRequirement(11,16)
    @test_throws ArgumentError MetadataRequirement(11 << 16,0)
    @test_throws ArgumentError MetadataRequirement(0x10000,8)
    @test MetadataRequirement(0x10000,0).size==0
    @test validate_metadata_requirements((MetadataRequirement(0x10000,0),))===nothing
    @test_throws ArgumentError validate_metadata_requirements(ntuple(i -> MetadataRequirement(0x900+i,0),64))
    @test_throws ArgumentError validate_metadata_requirements((MetadataRequirement(0x900,4065),))
    @test validate_metadata_requirements((MetadataRequirement(0x900,4064),))===nothing
    @test_throws ArgumentError MetadataRequirement(SPA.META_ACQUISITION_IDENTITY,41)
    @test_throws ArgumentError AbsoluteClock(METADATA_CLOCK_TAI)
    @test_throws ArgumentError AbsoluteTime(0,1_000_000_000;event=TIME_EVENT_PRODUCTION,origin=_METADATA_TEST_DOMAIN,clock_domain=_METADATA_TEST_DOMAIN)
    @test_throws ArgumentError MetadataSnapshot((UInt32(0x900)=>zeros(UInt8,4096),UInt32(0x901)=>UInt8[1]))
    @test_throws ArgumentError MetadataSnapshot((UInt32(0x900)=>UInt8[],UInt32(0x900)=>UInt8[]))
    fixture=records_fixture()
    retained=MetadataSnapshot()
    stamp=AbsoluteTime(typemax(Int64),999_999_999;event=TIME_EVENT_PRODUCTION,
        origin=_METADATA_TEST_DOMAIN,clock_domain=_METADATA_TEST_DOMAIN,uncertainty_nanoseconds=typemax(UInt64))
    GC.@preserve fixture begin
        buffer=fixture.buffer
        @test metadata_records_valid(buffer)
        @test metadata_fits(buffer,(MetadataRequirement(0x901,8),))
        @test !metadata_fits(buffer,(MetadataRequirement(0x901,8;required=true),))
        @test !metadata_fits(buffer,(MetadataRequirement(0x900,16),))
        @test !metadata_records_valid(buffer,(MetadataRequirement(SPA.META_ACQUISITION_IDENTITY;required=true),))
        @test acquisition_identity(buffer)===nothing
        @test exposure_timing(buffer)===nothing
        @test isempty(absolute_times(buffer))
        @test optical_classification(buffer)===nothing
        for value in (UInt64(0),UInt64(1)<<63,typemax(UInt64))
            identity=AcquisitionIdentity(AcquisitionDomain(_METADATA_TEST_DOMAIN),value,value)
            records_update!(buffer,identity,stamp)
            @test acquisition_identity(buffer)==identity
            @test exposure_timing(buffer).clock==METADATA_CLOCK_MODEL
            @test absolute_times(buffer)[1]==stamp
        end
        @test records_allocations(buffer,AcquisitionIdentity(AcquisitionDomain(_METADATA_TEST_DOMAIN),1,2),stamp,retained)==0
        @test metadata_count(retained)==7
        @test_throws ArgumentError set_absolute_times!(buffer,(PipeWireAO._EMPTY_ABSOLUTE_TIME,))
        @test absolute_times(buffer)[1]==stamp
        initialize_metadata!(buffer)
        @test acquisition_identity(buffer)===nothing
        @test optical_classification(buffer)===nothing
        set_optical_classification!(buffer,OPTICAL_ABSENT)
        @test optical_classification(buffer)===OPTICAL_ABSENT
        @test acquisition_identity(retained)!==nothing
        @test metadata_bytes(retained,7)==zeros(UInt8,8) # initializer cleared the optional output slot
        @test metadata_fits(buffer,retained)
        copy_metadata!(buffer,retained)
        @test absolute_times(buffer)[1]==stamp
        before=copy(metadata_bytes(retained,1))
        bad=MetadataSnapshot((UInt32(0x999)=>UInt8[9],))
        @test !metadata_fits(buffer,bad)
        @test_throws InvalidStateException copy_metadata!(buffer,bad)
        @test copy(metadata_bytes(fixture.snapshot,1))==before
        readonly=metadata_records(retained)
        @test_throws MethodError initialize_metadata!(readonly)
    end
end

@testset "owned snapshots exclude transport state and retain their byte views" begin
    native=PipeWireAO.LibPipeWire
    fixture=records_fixture()
    busy=UInt64[0x0000000700000001]
    sync=UInt64[0x0000000000000001,7,8]
    descriptors=vcat(fixture.snapshot.descriptors[1:Int(fixture.snapshot.count)],
        [native.spa_meta(SPA.META_BUSY,8,Ptr{Cvoid}(pointer(busy))),
         native.spa_meta(SPA.META_SYNC_TIMELINE,24,Ptr{Cvoid}(pointer(sync))),
         native.spa_meta(UInt32(0x10001),0,C_NULL)])
    spa=Ref(native.spa_buffer(UInt32(length(descriptors)),0,pointer(descriptors),C_NULL))
    packet=Ref(native.pw_buffer(Base.unsafe_convert(Ptr{native.spa_buffer},spa),C_NULL,0,0,0))
    source=StreamBuffer(Base.unsafe_convert(Ptr{native.pw_buffer},packet))
    snapshot=MetadataSnapshot()
    GC.@preserve fixture busy sync descriptors spa packet source begin
        initialize_metadata!(source)
        @test busy==UInt64[0x0000000700000001]
        @test sync==UInt64[1,7,8]
        capture_metadata!(snapshot,source)
        @test metadata_count(snapshot)==7
        @test all(record -> metadata_type(record) ∉ (SPA.META_BUSY,SPA.META_SYNC_TIMELINE,UInt32(0x10001)),metadata_records(snapshot))
        copy_metadata!(source,snapshot)
        @test busy==UInt64[0x0000000700000001]
        @test sync==UInt64[1,7,8]
    end
    @test_throws ArgumentError MetadataSnapshot((SPA.META_BUSY=>zeros(UInt8,8),))
    owner=MetadataSnapshot((UInt32(0x900)=>UInt8[1,2,3],))
    view=metadata_bytes(owner,1)
    records=metadata_records(owner)
    owner=nothing
    GC.gc()
    @test view==UInt8[1,2,3]
    @test metadata_bytes(something(metadata_record(records,UInt32(0x900))))==view
    @test_throws Base.CanonicalIndexError setindex!(view,UInt8(9),1)
end
