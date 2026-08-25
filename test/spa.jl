using PipeWireAO
using Test

function pod_value_allocations(::Type{T}, pod) where {T}
    pod_value(T, pod)
    return @allocated pod_value(T, pod)
end

@testset "public SPA identifiers" begin
    identifiers = (
        SPA.POD_OBJECT,
        SPA.PARAM_PROPS,
        SPA.OBJECT_PROPS,
        SPA.MEDIA_TYPE_AUDIO,
        SPA.MEDIA_SUBTYPE_RAW,
        SPA.FORMAT_AUDIO_RATE,
        SPA.PROP_VOLUME,
        SPA.DATA_MEM_PTR,
        SPA.DATA_FLAG_NONE,
        SPA.DATA_FLAG_READABLE,
        SPA.DATA_FLAG_WRITABLE,
        SPA.DATA_FLAG_DYNAMIC,
        SPA.DATA_FLAG_READWRITE,
        SPA.DATA_FLAG_MAPPABLE,
        SPA.DATA_FLAG_HUGE_PAGES,
        SPA.DATA_FLAG_HUGE_2MB,
        SPA.DATA_FLAG_HUGE_1GB,
        SPA.META_HEADER,
        SPA.META_HEADER_FLAG_CORRUPTED,
        SPA.META_HEADER_FLAG_GAP,
        SPA.META_TRANSFORM_90,
        SPA.IO_BUFFERS,
        SPA.BUFFERS_COUNT,
        SPA.BUFFERS_PAGE_SIZE_HINT,
        SPA.META_PARAM_TYPE,
        SPA.IO_PARAM_ID,
        SPA.LATENCY_DIRECTION,
        SPA.PROCESS_LATENCY_NS,
        SPA.PORT_CONFIG_MODE_DSP,
        SPA.PORT_CONFIG_DIRECTION,
        SPA.PROFILE_INDEX,
        SPA.PROP_INFO_ID,
        SPA.ROUTE_INDEX,
        SPA.TAG_DIRECTION,
        SPA.NODE_COMMAND_START,
        SPA.NODE_EVENT_REQUEST_PROCESS,
    )
    @test all(identifier -> identifier isa UInt32, identifiers)
    @test SPA.PARAM_PROPS == UInt32(2)
    @test SPA.PARAM_FORMAT == UInt32(4)
    @test SPA.OBJECT_PROPS == UInt32(0x0004_0002)
    @test SPA.DATA_FLAG_NONE == UInt32(0)
    @test SPA.DATA_FLAG_READABLE == UInt32(1 << 0)
    @test SPA.DATA_FLAG_WRITABLE == UInt32(1 << 1)
    @test SPA.DATA_FLAG_DYNAMIC == UInt32(1 << 2)
    @test SPA.DATA_FLAG_READWRITE ==
          SPA.DATA_FLAG_READABLE | SPA.DATA_FLAG_WRITABLE
    @test SPA.DATA_FLAG_MAPPABLE == UInt32(1 << 3)
    @test SPA.DATA_FLAG_HUGE_PAGES == UInt32(1 << 4)
    @test SPA.DATA_FLAG_HUGE_2MB == UInt32(1 << 5)
    @test SPA.DATA_FLAG_HUGE_1GB == UInt32(1 << 6)
    @test SPA.META_HEADER_FLAG_DISCONT == UInt32(1 << 0)
    @test SPA.META_HEADER_FLAG_CORRUPTED == UInt32(1 << 1)
    @test SPA.META_HEADER_FLAG_MARKER == UInt32(1 << 2)
    @test SPA.META_HEADER_FLAG_HEADER == UInt32(1 << 3)
    @test SPA.META_HEADER_FLAG_GAP == UInt32(1 << 4)
    @test SPA.META_HEADER_FLAG_DELTA_UNIT == UInt32(1 << 5)
    @test SPA.CHUNK_FLAG_NONE === Int32(0)
    @test SPA.CHUNK_FLAG_CORRUPTED === Int32(1 << 0)
    @test SPA.CHUNK_FLAG_EMPTY === Int32(1 << 1)

    header = BufferHeader(
        SPA.META_HEADER_FLAG_CORRUPTED | SPA.META_HEADER_FLAG_GAP,
        0,
        0,
        0,
        0,
    )
    @test !iszero(header.flags & SPA.META_HEADER_FLAG_CORRUPTED)
    chunk = BufferChunk(0, 1, 0, SPA.CHUNK_FLAG_CORRUPTED)
    @test !iszero(chunk.flags & SPA.CHUNK_FLAG_CORRUPTED)

    volume = @inferred SPA.Property(SPA.PROP_VOLUME, 0.5f0)
    parameter = @inferred SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, volume)
    @test parameter.object.id == SPA.PARAM_PROPS
    @test parameter.object.type == SPA.OBJECT_PROPS

    readme = read(joinpath(@__DIR__, "..", "README.md"), String)
    @test !occursin("PipeWireAO.LibPipeWire.SPA_", readme)
    examples = (
        joinpath(@__DIR__, "..", "examples", "audio_sine.jl"),
        joinpath(@__DIR__, "..", "examples", "video_capture.jl"),
    )
    @test all(path -> !occursin("PipeWireAO.LibPipeWire", read(path, String)), examples)
end

@testset "property parameters" begin
    exposure_type = Pod(SPA.Choice(
        SPA.CHOICE_RANGE,
        Float64[1_000.0, 10.0, 1_000_000.0],
    ))
    info = SPA.PropInfo(
        "genicam.ExposureTime",
        exposure_type;
        description="Camera exposure duration",
        group="AcquisitionControl",
        params=true,
    )
    info_parameter = @inferred prop_info_param(info)
    parsed_info = @inferred SPA.PropInfo(Pod(info_parameter))
    @test parsed_info.name == info.name
    @test parsed_info.type == info.type
    @test parsed_info.description == info.description
    @test parsed_info.group == info.group
    @test parsed_info.params

    trigger = SPA.PropInfo(
        "genicam.TriggerMode",
        Pod(SPA.Choice(SPA.CHOICE_ENUM, Int32[0, 0, 1]));
        labels=[Int32(0) => "Off", Int32(1) => "On"],
        params=true,
    )
    @test SPA.PropInfo(Pod(prop_info_param(trigger))).labels == trigger.labels

    values = SPA.Props(
        "egrabber.enabled" => true,
        "genicam.ExposureTime" => 2_500.0,
        "genicam.TriggerMode" => Int32(1),
    )
    values_parameter = @inferred props_param(values)
    parsed_values = @inferred SPA.Props(Pod(values_parameter))
    @test first.(parsed_values.values) == first.(values.values)
    @test pod_value(Bool, parsed_values.values[1].second)
    @test pod_value(Float64, parsed_values.values[2].second) == 2_500.0
    @test pod_value(Int32, parsed_values.values[3].second) == 1

    @test_throws ArgumentError SPA.PropInfo("", Pod(false))
    @test_throws ArgumentError SPA.Props("" => true)
    @test_throws ArgumentError SPA.PropInfo(Pod(values_parameter))
    @test_throws ArgumentError SPA.Props(Pod(info_parameter))
end

@testset "native ndarray format" begin
    element_sizes = (
        NdArray.BOOL8 => 1,
        NdArray.I8 => 1,
        NdArray.U8 => 1,
        NdArray.I16_LE => 2,
        NdArray.U16_LE => 2,
        NdArray.I32_LE => 4,
        NdArray.U32_LE => 4,
        NdArray.I64_LE => 8,
        NdArray.U64_LE => 8,
        NdArray.I128_LE => 16,
        NdArray.U128_LE => 16,
        NdArray.F8_E4M3FN => 1,
        NdArray.F8_E4M3FNUZ => 1,
        NdArray.F8_E5M2 => 1,
        NdArray.F8_E5M2FNUZ => 1,
        NdArray.F16_LE => 2,
        NdArray.BF16_LE => 2,
        NdArray.F32_LE => 4,
        NdArray.F64_LE => 8,
        NdArray.F128_LE => 16,
        NdArray.COMPLEX_F16_LE => 4,
        NdArray.COMPLEX_BF16_LE => 4,
        NdArray.COMPLEX_F32_LE => 8,
        NdArray.COMPLEX_F64_LE => 16,
        NdArray.COMPLEX_F128_LE => 32,
    )
    @test length(instances(NdArray.ElementType)) == 27
    @test UInt32(NdArray.START_CUSTOM) == 0x0001_0000
    for (element_type, element_size) in element_sizes
        format = NdArrayFormat(element_type, (2, 3); layout=NdArray.ROW_MAJOR)
        @test element_count(format) == 6
        @test payload_size(format) == 6 * element_size
    end
    @test_throws ArgumentError payload_size(
        NdArrayFormat(NdArray.UNKNOWN, (1,); layout=NdArray.ROW_MAJOR),
    )
    @test_throws ArgumentError payload_size(
        NdArrayFormat(NdArray.START_CUSTOM, (1,); layout=NdArray.ROW_MAJOR),
    )

    rate = SPA.Fraction(1_000, 1)
    matrix = MatrixFormat(NdArray.F32_LE, 8, 12; rate)
    @test matrix.layout == NdArray.COLUMN_MAJOR
    matrix_pod = matrix_format(matrix)
    parsed_matrix = @inferred MatrixFormat(matrix_pod)
    @test parsed_matrix.element_type == matrix.element_type
    @test parsed_matrix.rows == matrix.rows
    @test parsed_matrix.columns == matrix.columns
    @test parsed_matrix.layout == matrix.layout
    @test parsed_matrix.rate == matrix.rate
    @test payload_size(parsed_matrix) == 8 * 12 * sizeof(Float32)

    row_major = MatrixFormat(NdArray.F64_LE, 3, 5; layout=NdArray.ROW_MAJOR)
    @test MatrixFormat(matrix_format_param(row_major)).layout == NdArray.ROW_MAJOR
    vector = VectorFormat(NdArray.U16_LE, 97)
    @test VectorFormat(vector_format_param(vector)).length == 97
    @test VectorFormat(vector_format_param(vector)).element_type == NdArray.U16_LE
    @test NdArrayFormat(ndarray_format_param(
        NdArray.COMPLEX_F32_LE,
        (2, 4, 8);
        layout=NdArray.COLUMN_MAJOR,
    )).shape == (2, 4, 8)

    @test_throws ArgumentError NdArrayFormat(
        NdArray.F32_LE,
        ();
        layout=NdArray.ROW_MAJOR,
    )
    @test_throws ArgumentError NdArrayFormat(
        NdArray.F32_LE,
        (2, 0);
        layout=NdArray.ROW_MAJOR,
    )
    @test_throws ArgumentError NdArrayFormat(
        NdArray.F32_LE,
        (typemax(Int32), typemax(Int32), typemax(Int32));
        layout=NdArray.ROW_MAJOR,
    )

    enum_matrix = MatrixEnumFormat(
        MatrixFormat(NdArray.F64_LE, 16, 16; rate=SPA.Fraction(1_000, 1));
        element_type_alternatives=[NdArray.F32_LE],
        layout_alternatives=[NdArray.ROW_MAJOR],
        rate_choice=NdArrayRateChoice(
            SPA.CHOICE_RANGE,
            [SPA.Fraction(500, 1), SPA.Fraction(2_000, 1)],
        ),
    )
    enum_matrix_parameter = matrix_format_param(enum_matrix)
    @test enum_matrix_parameter.object.id == SPA.PARAM_ENUM_FORMAT
    element_choice = pod_value(
        SPA.Choice{SPA.Id},
        enum_matrix_parameter.object[SPA.FORMAT_NDARRAY_ELEMENT_TYPE].value,
    )
    @test element_choice == SPA.Choice(
        SPA.CHOICE_ENUM,
        SPA.Id[
            SPA.Id(UInt32(NdArray.F64_LE)),
            SPA.Id(UInt32(NdArray.F64_LE)),
            SPA.Id(UInt32(NdArray.F32_LE)),
        ],
    )
    @test pod_value(
        SPA.Array{Int32},
        enum_matrix_parameter.object[SPA.FORMAT_NDARRAY_SHAPE].value,
    ) == SPA.Array(Int32[16, 16])
    @test pod_value(
        SPA.Choice{SPA.Id},
        enum_matrix_parameter.object[SPA.FORMAT_NDARRAY_LAYOUT].value,
    ) == SPA.Choice(
        SPA.CHOICE_ENUM,
        SPA.Id[
            SPA.Id(UInt32(NdArray.COLUMN_MAJOR)),
            SPA.Id(UInt32(NdArray.COLUMN_MAJOR)),
            SPA.Id(UInt32(NdArray.ROW_MAJOR)),
        ],
    )
    @test pod_value(
        SPA.Choice{SPA.Fraction},
        enum_matrix_parameter.object[SPA.FORMAT_NDARRAY_RATE].value,
    ) == SPA.Choice(
        SPA.CHOICE_RANGE,
        SPA.Fraction[
            SPA.Fraction(1_000, 1),
            SPA.Fraction(500, 1),
            SPA.Fraction(2_000, 1),
        ],
    )
    @test_throws ArgumentError MatrixFormat(enum_matrix_parameter)

    enum_vector = VectorEnumFormat(
        VectorFormat(NdArray.F32_LE, 64; rate=SPA.Fraction(2_000, 1));
        element_type_alternatives=[NdArray.F64_LE],
        rate_choice=NdArrayRateChoice(
            SPA.CHOICE_ENUM,
            [SPA.Fraction(1_000, 1), SPA.Fraction(500, 1)],
        ),
    )
    enum_vector_parameter = vector_format_param(enum_vector)
    @test pod_value(
        SPA.Id,
        enum_vector_parameter.object[SPA.FORMAT_NDARRAY_LAYOUT].value,
    ) == SPA.Id(UInt32(NdArray.ROW_MAJOR))
    @test pod_value(
        SPA.Choice{SPA.Fraction},
        enum_vector_parameter.object[SPA.FORMAT_NDARRAY_RATE].value,
    ).values == SPA.Fraction[
        SPA.Fraction(2_000, 1),
        SPA.Fraction(2_000, 1),
        SPA.Fraction(1_000, 1),
        SPA.Fraction(500, 1),
    ]

    @test_throws ArgumentError NdArrayRateChoice(SPA.CHOICE_ENUM, SPA.Fraction[])
    @test_throws ArgumentError NdArrayRateChoice(
        SPA.CHOICE_RANGE,
        [SPA.Fraction(500, 1)],
    )
    @test_throws ArgumentError NdArrayRateChoice(
        SPA.CHOICE_FLAGS,
        [SPA.Fraction(500, 1)],
    )
    @test_throws ArgumentError NdArrayEnumFormat(
        NdArrayFormat(NdArray.F32_LE, (8,); layout=NdArray.ROW_MAJOR);
        rate_choice=NdArrayRateChoice(
            SPA.CHOICE_RANGE,
            [SPA.Fraction(500, 1), SPA.Fraction(2_000, 1)],
        ),
    )
    @test_throws ArgumentError MatrixEnumFormat(
        MatrixFormat(NdArray.F32_LE, 8, 8; rate=SPA.Fraction(250, 1));
        rate_choice=NdArrayRateChoice(
            SPA.CHOICE_RANGE,
            [SPA.Fraction(500, 1), SPA.Fraction(2_000, 1)],
        ),
    )
    @test_throws ArgumentError NdArrayEnumFormat(
        NdArrayFormat(NdArray.F32_LE, (8,); layout=NdArray.ROW_MAJOR);
        element_type_alternatives=[NdArray.UNKNOWN],
    )
    @test_throws ArgumentError NdArrayEnumFormat(
        NdArrayFormat(NdArray.F32_LE, (8,); layout=NdArray.ROW_MAJOR);
        layout_alternatives=[NdArray.LAYOUT_UNKNOWN],
    )
end


@testset "scalar SPA POD values" begin
    scalar_values = (
        (Nothing, nothing, PipeWireAO.LibPipeWire.SPA_TYPE_None),
        (Bool, true, PipeWireAO.LibPipeWire.SPA_TYPE_Bool),
        (Bool, false, PipeWireAO.LibPipeWire.SPA_TYPE_Bool),
        (SPA.Id, SPA.Id(17), PipeWireAO.LibPipeWire.SPA_TYPE_Id),
        (Int32, Int32(-123), PipeWireAO.LibPipeWire.SPA_TYPE_Int),
        (Int64, Int64(1) << 40, PipeWireAO.LibPipeWire.SPA_TYPE_Long),
        (Float32, 1.25f0, PipeWireAO.LibPipeWire.SPA_TYPE_Float),
        (Float64, -2.5, PipeWireAO.LibPipeWire.SPA_TYPE_Double),
        (String, "PipeWire ✓", PipeWireAO.LibPipeWire.SPA_TYPE_String),
        (SPA.Bytes, SPA.Bytes(UInt8[0x00, 0x7f, 0xff]), PipeWireAO.LibPipeWire.SPA_TYPE_Bytes),
        (SPA.Fd, SPA.Fd(-1), PipeWireAO.LibPipeWire.SPA_TYPE_Fd),
        (
            SPA.Rectangle,
            SPA.Rectangle(1_920, 1_080),
            PipeWireAO.LibPipeWire.SPA_TYPE_Rectangle,
        ),
        (
            SPA.Fraction,
            SPA.Fraction(30_000, 1_001),
            PipeWireAO.LibPipeWire.SPA_TYPE_Fraction,
        ),
    )

    for (value_type, value, wire_type) in scalar_values
        pod = Pod(value)
        @test pod_type(pod) == wire_type
        @test pod_value(value_type, pod) == value
        @test pod_value(pod) == value
    end

    for value_type in (SPA.Id, SPA.Fd, SPA.Bytes, SPA.Rectangle, SPA.Fraction)
        @test isconcretetype(value_type)
        @test all(isconcretetype, fieldtypes(value_type))
    end
    @test all(isbitstype, (SPA.Id, SPA.Fd, SPA.Rectangle, SPA.Fraction))

    bytes_source = UInt8[1, 2, 3]
    bytes_value = SPA.Bytes(bytes_source)
    bytes_source[1] = 9
    @test bytes_value == SPA.Bytes(UInt8[1, 2, 3])
    @test isequal(bytes_value, SPA.Bytes(UInt8[1, 2, 3]))
    @test hash(bytes_value) == hash(SPA.Bytes(UInt8[1, 2, 3]))

    int_pod = Pod(Int32(-7))
    rectangle_pod = Pod(SPA.Rectangle(640, 480))
    @test @inferred(pod_value(Int32, int_pod)) == -7
    @test @inferred(pod_value(SPA.Rectangle, rectangle_pod)) == SPA.Rectangle(640, 480)
    @test pod_value_allocations(Int32, int_pod) == 0
    @test pod_value_allocations(SPA.Rectangle, rectangle_pod) == 0

    @test_throws ArgumentError pod_value(Int32, Pod(true))
    @test_throws ArgumentError SPA.Id(-1)
    @test_throws ArgumentError SPA.Id(big(typemax(UInt32)) + 1)
    @test_throws ArgumentError SPA.Fd(big(typemax(Int64)) + 1)
    @test_throws ArgumentError SPA.Rectangle(-1, 1)
    @test_throws ArgumentError SPA.Fraction(1, -1)
    @test_throws ArgumentError Pod("embedded\0null")

    malformed_string = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61],
    )
    embedded_null = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_String),
        UInt8[0x61, 0x00, 0x62, 0x00],
    )
    malformed_bool = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Bool),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(String, malformed_string)
    @test_throws ArgumentError pod_value(String, embedded_null)
    @test_throws ArgumentError pod_value(Bool, malformed_bool)
end

@testset "container SPA POD values" begin
    arrays = (
        SPA.Array(Bool[true, false, true]),
        SPA.Array(SPA.Id[SPA.Id(1), SPA.Id(7)]),
        SPA.Array(Int32[-1, 0, 1]),
        SPA.Array(Int64[-(Int64(1) << 40), Int64(1) << 40]),
        SPA.Array(Float32[-1.5, 2.25]),
        SPA.Array(Float64[-3.5, 4.75]),
        SPA.Array([SPA.Rectangle(640, 480), SPA.Rectangle(1_920, 1_080)]),
        SPA.Array([SPA.Fraction(24, 1), SPA.Fraction(30_000, 1_001)]),
        SPA.Array([SPA.Fd(-1), SPA.Fd(9)]),
        SPA.Array(Int32[]),
    )

    for array in arrays
        pod = Pod(array)
        @test pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Array
        @test pod_value(typeof(array), pod) == array
        @test pod_value(pod) == array
        @test isconcretetype(typeof(array))
        @test all(isconcretetype, fieldtypes(typeof(array)))
    end

    source = Int32[1, 2, 3]
    array = SPA.Array(source)
    source[1] = 9
    @test array.values == Int32[1, 2, 3]

    int_array_pod = Pod(SPA.Array(Int32[4, 5, 6]))
    @test @inferred(pod_value(SPA.Array{Int32}, int_array_pod)) ==
          SPA.Array(Int32[4, 5, 6])
    @test_throws ArgumentError pod_value(SPA.Array{Int64}, int_array_pod)
    @test_throws ArgumentError SPA.Array(Real[1, 2])
    @test_throws ArgumentError Pod(SPA.Array(["not", "fixed-size"]))

    children = [Pod(Int32(7)), Pod("hello"), Pod(SPA.Array(Int64[8, 9]))]
    value = SPA.Struct(children)
    children[1] = Pod(Int32(99))
    pod = Pod(value)
    @test pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Struct
    decoded = @inferred pod_value(SPA.Struct, pod)
    @test decoded == value
    @test pod_value(pod) == value
    @test isconcretetype(typeof(decoded))
    @test all(isconcretetype, fieldtypes(typeof(decoded)))
    @test pod_value(Int32, decoded.values[1]) == 7
    @test pod_value(String, decoded.values[2]) == "hello"
    @test pod_value(decoded.values[3]) == SPA.Array(Int64[8, 9])

    partial_array_body = UInt8[]
    PipeWireAO._append_bits!(partial_array_body, UInt32(sizeof(Int32)))
    PipeWireAO._append_bits!(partial_array_body, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Int))
    append!(partial_array_body, UInt8[1, 2, 3])
    partial_array = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Array),
        partial_array_body,
    )
    missing_array_header = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Array),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Array{Int32}, partial_array)
    @test_throws ArgumentError pod_value(SPA.Array, missing_array_header)

    unpadded_struct = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Struct),
        Pod(Int32(1)).data,
    )
    partial_struct = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Struct),
        UInt8[0x01],
    )
    @test_throws ArgumentError pod_value(SPA.Struct, unpadded_struct)
    @test_throws ArgumentError pod_value(SPA.Struct, partial_struct)

    oversized_header = UInt8[]
    PipeWireAO._append_bits!(oversized_header, UInt32(1 << 20))
    PipeWireAO._append_bits!(oversized_header, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Bytes))
    @test_throws ArgumentError Pod(oversized_header)
end

@testset "choice SPA POD values" begin
    choices = (
        SPA.Choice(SPA.CHOICE_NONE, Bool[true]),
        SPA.Choice(SPA.CHOICE_ENUM, SPA.Id[SPA.Id(1), SPA.Id(2), SPA.Id(7)]),
        SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000]),
        SPA.Choice(SPA.CHOICE_STEP, Int64[8, 0, 64, 8]),
        SPA.Choice(SPA.CHOICE_ENUM, Float32[1.0, 1.5, 2.0]; flags=3),
        SPA.Choice(SPA.CHOICE_RANGE, Float64[1.0, 0.5, 2.0]),
        SPA.Choice(
            SPA.CHOICE_RANGE,
            [
                SPA.Rectangle(1_920, 1_080),
                SPA.Rectangle(320, 240),
                SPA.Rectangle(3_840, 2_160),
            ],
        ),
        SPA.Choice(
            SPA.CHOICE_STEP,
            [
                SPA.Fraction(30_000, 1_001),
                SPA.Fraction(1, 1),
                SPA.Fraction(60, 1),
                SPA.Fraction(1, 1),
            ],
        ),
        SPA.Choice(SPA.CHOICE_FLAGS, [SPA.Fd(3)]),
    )

    for choice in choices
        pod = Pod(choice)
        @test pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Choice
        @test pod_value(typeof(choice), pod) == choice
        @test pod_value(pod) == choice
        @test isconcretetype(typeof(choice))
        @test all(isconcretetype, fieldtypes(typeof(choice)))
    end

    source = Int32[2, 1, 3]
    choice = SPA.Choice(SPA.CHOICE_RANGE, source)
    source[1] = 9
    @test choice.values == Int32[2, 1, 3]

    choice_pod = Pod(choice)
    @test @inferred(pod_value(SPA.Choice{Int32}, choice_pod)) == choice
    @test_throws ArgumentError pod_value(SPA.Choice{Int64}, choice_pod)
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_RANGE, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_RANGE, Int32[1, 2, 3, 4])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_STEP, Int32[1, 2, 3])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_STEP, Int32[1, 2, 3, 4, 5])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_ENUM, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_ENUM, Int32[1])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_FLAGS, Int32[])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_FLAGS, Int32[1, 2])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Real[1])
    @test_throws ArgumentError SPA.Choice(SPA.CHOICE_NONE, Int32[1]; flags=-1)
    @test_throws ArgumentError Pod(SPA.Choice(SPA.CHOICE_NONE, ["not fixed-size"]))

    unknown_kind_body = UInt8[]
    PipeWireAO._append_bits!(unknown_kind_body, UInt32(99))
    PipeWireAO._append_bits!(unknown_kind_body, UInt32(0))
    PipeWireAO._append_bits!(unknown_kind_body, UInt32(sizeof(Int32)))
    PipeWireAO._append_bits!(unknown_kind_body, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Int))
    PipeWireAO._append_bits!(unknown_kind_body, Int32(1))
    unknown_kind = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Choice),
        unknown_kind_body,
    )

    partial_choice_body = UInt8[]
    PipeWireAO._append_bits!(partial_choice_body, UInt32(SPA.CHOICE_NONE))
    PipeWireAO._append_bits!(partial_choice_body, UInt32(0))
    PipeWireAO._append_bits!(partial_choice_body, UInt32(sizeof(Int32)))
    PipeWireAO._append_bits!(partial_choice_body, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Int))
    append!(partial_choice_body, UInt8[1, 2, 3])
    partial_choice = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Choice),
        partial_choice_body,
    )

    missing_choice_header = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Choice),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Choice, unknown_kind)
    @test_throws ArgumentError pod_value(SPA.Choice{Int32}, partial_choice)
    @test_throws ArgumentError pod_value(SPA.Choice, missing_choice_header)
end

@testset "object SPA POD values" begin
    object = SPA.Object(
        0x40002,
        3,
        SPA.Property(1, SPA.Id(7); flags=SPA.PROPERTY_READONLY),
        SPA.Property(2, "audio"),
        SPA.Property(
            3,
            SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000]);
            flags=SPA.PROPERTY_MANDATORY | SPA.PROPERTY_DONT_FIXATE,
        ),
    )
    pod = Pod(object)
    @test pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Object
    decoded = @inferred pod_value(SPA.Object, pod)
    @test decoded == object
    @test pod_value(pod) == object
    @test isconcretetype(typeof(decoded))
    @test all(isconcretetype, fieldtypes(typeof(decoded)))
    @test isconcretetype(SPA.Property)
    @test all(isconcretetype, fieldtypes(SPA.Property))
    @test decoded.properties[1].flags == SPA.PROPERTY_READONLY
    @test pod_value(SPA.Id, decoded.properties[1].value) == SPA.Id(7)
    @test pod_value(String, decoded.properties[2].value) == "audio"
    @test pod_value(decoded.properties[3].value) ==
          SPA.Choice(SPA.CHOICE_RANGE, Int32[48_000, 8_000, 192_000])
    @test decoded[1] == decoded.properties[1]
    @test get(decoded, 2, nothing) == decoded.properties[2]
    @test get(decoded, 99, :missing) === :missing
    @test haskey(decoded, 3)
    @test !haskey(decoded, 99)
    @test_throws KeyError decoded[99]

    properties = [SPA.Property(1, Int32(2))]
    copied = SPA.Object(1, 2, properties)
    properties[1] = SPA.Property(1, Int32(9))
    @test pod_value(Int32, copied.properties[1].value) == 2

    format = pod_value(SPA.Object, audio_format())
    @test format.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test format.id == PipeWireAO.LibPipeWire.SPA_PARAM_EnumFormat
    @test length(format.properties) == 6
    @test map(property -> property.key, format.properties) == UInt32[
        PipeWireAO.LibPipeWire.SPA_FORMAT_mediaType,
        PipeWireAO.LibPipeWire.SPA_FORMAT_mediaSubtype,
        PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_format,
        PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_rate,
        PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_channels,
        PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_position,
    ]

    @test_throws ArgumentError SPA.Property(-1, Int32(1))
    @test_throws ArgumentError SPA.Property(1, Int32(1); flags=-1)
    @test_throws ArgumentError SPA.Object(-1, 1, SPA.Property[])
    @test_throws ArgumentError SPA.Object(1, -1, SPA.Property[])

    missing_object_header = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Object),
        UInt8[],
    )
    partial_property_body = UInt8[]
    PipeWireAO._append_bits!(partial_property_body, UInt32(1))
    PipeWireAO._append_bits!(partial_property_body, UInt32(2))
    push!(partial_property_body, 0x01)
    partial_property = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Object),
        partial_property_body,
    )
    truncated_value_body = UInt8[]
    PipeWireAO._append_bits!(truncated_value_body, UInt32(1))
    PipeWireAO._append_bits!(truncated_value_body, UInt32(2))
    PipeWireAO._append_bits!(truncated_value_body, UInt32(3))
    PipeWireAO._append_bits!(truncated_value_body, UInt32(0))
    PipeWireAO._append_bits!(truncated_value_body, UInt32(8))
    PipeWireAO._append_bits!(truncated_value_body, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Long))
    PipeWireAO._append_bits!(truncated_value_body, Int32(1))
    truncated_value = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Object),
        truncated_value_body,
    )
    @test_throws ArgumentError pod_value(SPA.Object, missing_object_header)
    @test_throws ArgumentError pod_value(SPA.Object, partial_property)
    @test_throws ArgumentError pod_value(SPA.Object, truncated_value)
end

@testset "sequence SPA POD values" begin
    sequence = SPA.Sequence(
        1,
        SPA.Control(0, 2, SPA.Bytes(UInt8[0x90, 0x40, 0x7f])),
        SPA.Control(128, 3, Float32(0.5)),
        SPA.Control(256, 4, SPA.Object(1, 2, SPA.Property(3, Int32(4)))),
    )
    pod = Pod(sequence)
    @test pod_type(pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Sequence
    decoded = @inferred pod_value(SPA.Sequence, pod)
    @test decoded == sequence
    @test pod_value(pod) == sequence
    @test isconcretetype(SPA.Control)
    @test all(isconcretetype, fieldtypes(SPA.Control))
    @test isconcretetype(SPA.Sequence)
    @test all(isconcretetype, fieldtypes(SPA.Sequence))
    @test pod_value(SPA.Bytes, decoded.controls[1].value) ==
          SPA.Bytes(UInt8[0x90, 0x40, 0x7f])
    @test pod_value(Float32, decoded.controls[2].value) == 0.5f0
    @test pod_value(SPA.Object, decoded.controls[3].value) ==
          SPA.Object(1, 2, SPA.Property(3, Int32(4)))

    controls = [SPA.Control(0, 1, Int32(2))]
    copied = SPA.Sequence(1, controls)
    controls[1] = SPA.Control(0, 1, Int32(9))
    @test pod_value(Int32, copied.controls[1].value) == 2

    @test_throws ArgumentError SPA.Control(-1, 1, Int32(1))
    @test_throws ArgumentError SPA.Control(1, -1, Int32(1))
    @test_throws ArgumentError SPA.Sequence(-1, SPA.Control[])

    missing_sequence_header = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Sequence),
        UInt8[],
    )
    nonzero_padding_body = UInt8[]
    PipeWireAO._append_bits!(nonzero_padding_body, UInt32(1))
    PipeWireAO._append_bits!(nonzero_padding_body, UInt32(1))
    nonzero_padding = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Sequence),
        nonzero_padding_body,
    )
    partial_control_body = UInt8[]
    PipeWireAO._append_bits!(partial_control_body, UInt32(1))
    PipeWireAO._append_bits!(partial_control_body, UInt32(0))
    push!(partial_control_body, 0x01)
    partial_control = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Sequence),
        partial_control_body,
    )
    truncated_control_body = UInt8[]
    PipeWireAO._append_bits!(truncated_control_body, UInt32(1))
    PipeWireAO._append_bits!(truncated_control_body, UInt32(0))
    PipeWireAO._append_bits!(truncated_control_body, UInt32(0))
    PipeWireAO._append_bits!(truncated_control_body, UInt32(2))
    PipeWireAO._append_bits!(truncated_control_body, UInt32(8))
    PipeWireAO._append_bits!(truncated_control_body, UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Long))
    PipeWireAO._append_bits!(truncated_control_body, Int32(1))
    truncated_control = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Sequence),
        truncated_control_body,
    )
    @test_throws ArgumentError pod_value(SPA.Sequence, missing_sequence_header)
    @test_throws ArgumentError pod_value(SPA.Sequence, nonzero_padding)
    @test_throws ArgumentError pod_value(SPA.Sequence, partial_control)
    @test_throws ArgumentError pod_value(SPA.Sequence, truncated_control)
end

@testset "raw video format" begin
    @test length(instances(Video.Format)) == 88
    @test Video.DSP_F32 == Video.RGBA_F32

    format = @inferred video_format()
    object = pod_value(SPA.Object, format)
    @test object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test object.id == PipeWireAO.LibPipeWire.SPA_PARAM_EnumFormat
    @test map(property -> property.key, object.properties) == UInt32[
        PipeWireAO.LibPipeWire.SPA_FORMAT_mediaType,
        PipeWireAO.LibPipeWire.SPA_FORMAT_mediaSubtype,
        PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_format,
        PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_size,
        PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_framerate,
    ]
    @test pod_value(SPA.Id, object.properties[1].value) ==
          SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_TYPE_video)
    @test pod_value(SPA.Id, object.properties[2].value) ==
          SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_SUBTYPE_raw)
    @test pod_value(SPA.Id, object.properties[3].value) == SPA.Id(UInt32(Video.RGBA))
    @test pod_value(SPA.Rectangle, object.properties[4].value) == SPA.Rectangle(640, 480)
    @test pod_value(SPA.Fraction, object.properties[5].value) == SPA.Fraction(30, 1)

    complete = pod_value(
        SPA.Object,
        video_format(
            format=Video.NV12,
            size=SPA.Rectangle(1_920, 1_080),
            framerate=SPA.Fraction(30_000, 1_001),
            modifier=0,
            max_framerate=SPA.Fraction(60, 1),
            views=2,
            interlace_mode=1,
            pixel_aspect_ratio=SPA.Fraction(1, 1),
            multiview_mode=2,
            multiview_flags=3,
            chroma_site=4,
            color_range=1,
            color_matrix=2,
            transfer_function=3,
            color_primaries=4,
            id=4,
        ),
    )
    @test complete.id == 4
    @test length(complete.properties) == 17
    property_by_key = Dict(property.key => property for property in complete.properties)
    @test pod_value(SPA.Id, property_by_key[PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_format].value) ==
          SPA.Id(UInt32(Video.NV12))
    @test pod_value(Int64, property_by_key[PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_modifier].value) == 0
    @test property_by_key[PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_modifier].flags ==
          SPA.PROPERTY_MANDATORY
    @test pod_value(Int32, property_by_key[PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_views].value) == 2
    @test pod_value(
        SPA.Fraction,
        property_by_key[PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_pixelAspectRatio].value,
    ) == SPA.Fraction(1, 1)

    no_rate = pod_value(SPA.Object, video_format(framerate=nothing))
    @test all(
        property -> property.key != PipeWireAO.LibPipeWire.SPA_FORMAT_VIDEO_framerate,
        no_rate.properties,
    )

    @test_throws ArgumentError video_format(size=SPA.Rectangle(0, 480))
    @test_throws ArgumentError video_format(framerate=SPA.Fraction(30, 0))
    @test_throws ArgumentError video_format(max_framerate=SPA.Fraction(60, 0))
    @test_throws ArgumentError video_format(pixel_aspect_ratio=SPA.Fraction(1, 0))
    @test_throws ArgumentError video_format(modifier=big(typemax(Int64)) + 1)
    @test_throws ArgumentError video_format(views=big(typemax(Int32)) + 1)
    @test_throws ArgumentError video_format(interlace_mode=-1)
    @test_throws ArgumentError video_format(id=-1)
end

@testset "raw format information" begin
    audio = @inferred AudioInfoRaw(
        audio_format(format=Audio.F32, rate=44_100, channels=2),
    )
    @test all(isconcretetype, fieldtypes(AudioInfoRaw))
    @test audio.format == UInt32(Audio.F32)
    @test audio.flags == 0
    @test audio.rate == 44_100
    @test audio.channels == 2
    @test audio.position == UInt32[UInt32(Audio.FL), UInt32(Audio.FR)]
    @test AudioInfoRaw(audio_format_param(channels=1)).position ==
          UInt32[UInt32(Audio.MONO)]

    unpositioned = Pod(
        SPA.Object(
            PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format,
            PipeWireAO.LibPipeWire.SPA_PARAM_Format,
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_mediaType,
                SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_TYPE_audio),
            ),
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_mediaSubtype,
                SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_SUBTYPE_raw),
            ),
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_format,
                SPA.Id(UInt32(Audio.F32)),
            ),
            SPA.Property(PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_rate, Int32(48_000)),
            SPA.Property(PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_channels, Int32(2)),
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_position,
                SPA.Array(SPA.Id[SPA.Id(UInt32(Audio.MONO))]),
            ),
        ),
    )
    unpositioned_info = AudioInfoRaw(unpositioned)
    @test unpositioned_info.flags == Audio.FLAG_UNPOSITIONED
    @test unpositioned_info.position == zeros(UInt32, 2)

    video = @inferred VideoInfoRaw(
        video_format(
            format=Video.NV12,
            size=SPA.Rectangle(1_920, 1_080),
            framerate=SPA.Fraction(30_000, 1_001),
            modifier=0x1234,
            max_framerate=SPA.Fraction(60, 1),
            views=2,
            interlace_mode=1,
            pixel_aspect_ratio=SPA.Fraction(1, 1),
            multiview_mode=2,
            multiview_flags=3,
            chroma_site=4,
            color_range=1,
            color_matrix=2,
            transfer_function=3,
            color_primaries=4,
        ),
    )
    @test all(isconcretetype, fieldtypes(VideoInfoRaw))
    @test isbitstype(VideoInfoRaw)
    @test video.format == UInt32(Video.NV12)
    @test video.flags == Video.FLAG_MODIFIER
    @test video.modifier == 0x1234
    @test video.size == SPA.Rectangle(1_920, 1_080)
    @test video.framerate == SPA.Fraction(30_000, 1_001)
    @test video.max_framerate == SPA.Fraction(60, 1)
    @test video.views == 2
    @test video.interlace_mode == 1
    @test video.pixel_aspect_ratio == SPA.Fraction(1, 1)
    @test video.multiview_mode == 2
    @test video.multiview_flags == 3
    @test video.chroma_site == 4
    @test video.color_range == 1
    @test video.color_matrix == 2
    @test video.transfer_function == 3
    @test video.color_primaries == 4
    @test VideoInfoRaw(video_format_param()).format == UInt32(Video.RGBA)

    @test_throws ArgumentError AudioInfoRaw(video_format())
    @test_throws ArgumentError VideoInfoRaw(audio_format())
    @test_throws ArgumentError AudioInfoRaw(Pod(Int32(1)))

    unfixed_audio = Pod(
        SPA.Object(
            PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format,
            PipeWireAO.LibPipeWire.SPA_PARAM_EnumFormat,
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_mediaType,
                SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_TYPE_audio),
            ),
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_mediaSubtype,
                SPA.Id(PipeWireAO.LibPipeWire.SPA_MEDIA_SUBTYPE_raw),
            ),
            SPA.Property(
                PipeWireAO.LibPipeWire.SPA_FORMAT_AUDIO_rate,
                SPA.Choice(SPA.CHOICE_ENUM, Int32[48_000, 44_100]),
            ),
        ),
    )
    @test_throws ArgumentError AudioInfoRaw(unfixed_audio)
end

@testset "bitmap and pointer SPA POD values" begin
    source = UInt8[0xaa, 0x55]
    bitmap = SPA.Bitmap(source)
    source[1] = 0x00
    bitmap_pod = Pod(bitmap)
    @test pod_type(bitmap_pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Bitmap
    @test pod_value(SPA.Bitmap, bitmap_pod) == SPA.Bitmap(UInt8[0xaa, 0x55])
    @test pod_value(bitmap_pod) == bitmap
    @test isconcretetype(SPA.Bitmap)
    @test all(isconcretetype, fieldtypes(SPA.Bitmap))
    @test_throws ArgumentError SPA.Bitmap(UInt8[])

    storage = Ref{Int32}(42)
    pointer = SPA.Pointer(7, Base.unsafe_convert(Ptr{Int32}, storage))
    pointer_pod = GC.@preserve storage Pod(pointer)
    decoded = @inferred pod_value(SPA.Pointer{Int32}, pointer_pod)
    @test decoded == pointer
    @test pod_type(pointer_pod) == PipeWireAO.LibPipeWire.SPA_TYPE_Pointer
    @test pod_value(pointer_pod) == SPA.Pointer(7, Ptr{Cvoid}(pointer.value))
    @test isconcretetype(typeof(pointer))
    @test all(isconcretetype, fieldtypes(typeof(pointer)))
    @test isbitstype(typeof(pointer))
    @test pod_value_allocations(SPA.Pointer{Int32}, pointer_pod) == 0
    @test_throws ArgumentError SPA.Pointer(-1, pointer.value)

    nonzero_padding_body = UInt8[]
    PipeWireAO._append_bits!(nonzero_padding_body, UInt32(7))
    PipeWireAO._append_bits!(nonzero_padding_body, UInt32(1))
    PipeWireAO._append_bits!(nonzero_padding_body, UInt(pointer.value))
    nonzero_padding = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Pointer),
        nonzero_padding_body,
    )
    @test_throws ArgumentError pod_value(SPA.Pointer{Int32}, nonzero_padding)

    empty_bitmap = PipeWireAO._pod_from_body(
        UInt32(PipeWireAO.LibPipeWire.SPA_TYPE_Bitmap),
        UInt8[],
    )
    @test_throws ArgumentError pod_value(SPA.Bitmap, empty_bitmap)
end
@testset "typed SPA parameters, commands, and events" begin
    buffers = buffers_param(
        buffers=4,
        blocks=1,
        size=4096,
        stride=256,
        align=16,
        data_types=Int32(1 << PipeWireAO.LibPipeWire.SPA_DATA_MemPtr),
        metadata_types=Int32(1 << PipeWireAO.LibPipeWire.SPA_META_Header),
        page_size_hint=SPA.PAGE_SIZE_HUGE_2MB,
    )
    @test buffers isa SPA.Parameter
    @test all(isconcretetype, fieldtypes(typeof(buffers)))
    @test buffers.object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_ParamBuffers
    @test buffers.object.id == PipeWireAO.LibPipeWire.SPA_PARAM_Buffers
    @test pod_value(SPA.Parameter, Pod(buffers)) == buffers
    page_size_property = only(
        property for property in buffers.object.properties if
        property.key == SPA.BUFFERS_PAGE_SIZE_HINT
    )
    @test pod_value(SPA.Id, page_size_property.value) ==
          SPA.Id(UInt32(SPA.PAGE_SIZE_HUGE_2MB))

    metadata = metadata_param(PipeWireAO.LibPipeWire.SPA_META_Header; size=64)
    header = header_metadata_param()
    io = io_param(PipeWireAO.LibPipeWire.SPA_IO_Buffers; size=32)
    @test pod_value(SPA.Parameter, Pod(metadata)) == metadata
    @test pod_value(SPA.Parameter, Pod(header)) == header
    @test pod_value(Int32, only(
        property.value for property in header.object.properties if
        property.key == PipeWireAO.LibPipeWire.SPA_PARAM_META_size
    )) == Int32(sizeof(PipeWireAO.LibPipeWire.spa_meta_header))
    @test pod_value(SPA.Parameter, Pod(io)) == io
    @test_throws ArgumentError buffers_param(size=big(typemax(Int32)) + 1)

    latency = latency_param(
        PipeWireAO.LibPipeWire.SPA_DIRECTION_OUTPUT;
        min_quantum=0.5,
        max_quantum=2,
        min_rate=64,
        max_rate=256,
        min_ns=1_000,
        max_ns=2_000,
    )
    process_latency = process_latency_param(quantum=1, rate=128, ns=500)
    tag = tag_param(
        PipeWireAO.LibPipeWire.SPA_DIRECTION_INPUT,
        ("language" => "en", "role" => "music"),
    )
    @test latency.object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_ParamLatency
    @test process_latency.object.type ==
          PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_ParamProcessLatency
    @test tag.object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_ParamTag
    @test pod_value(SPA.Parameter, Pod(latency)) == latency
    @test pod_value(SPA.Parameter, Pod(process_latency)) == process_latency
    @test pod_value(SPA.Parameter, Pod(tag)) == tag
    @test_throws ArgumentError latency_param(
        PipeWireAO.LibPipeWire.SPA_DIRECTION_INPUT;
        min_quantum=Inf,
    )

    command = node_command(PipeWireAO.LibPipeWire.SPA_NODE_COMMAND_Start)
    event = node_event(PipeWireAO.LibPipeWire.SPA_NODE_EVENT_RequestProcess)
    @test command isa SPA.Command
    @test event isa SPA.Event
    @test all(isconcretetype, fieldtypes(typeof(command)))
    @test all(isconcretetype, fieldtypes(typeof(event)))
    @test pod_value(SPA.Command, Pod(command)) == command
    @test pod_value(SPA.Event, Pod(event)) == event
    @test device_command(1).object.type == PipeWireAO.LibPipeWire.SPA_TYPE_COMMAND_Device
    @test device_event(1).object.type == PipeWireAO.LibPipeWire.SPA_TYPE_EVENT_Device
    @test_throws ArgumentError SPA.Command(
        SPA.Object(PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format, 0),
    )
    @test_throws ArgumentError SPA.Event(
        SPA.Object(PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format, 0),
    )

    typed_audio = audio_format_param(rate=48_000, channels=2)
    typed_video = video_format_param(size=SPA.Rectangle(1920, 1080))
    @test typed_audio isa SPA.Parameter
    @test typed_video isa SPA.Parameter
    @test typed_audio.object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format
    @test typed_video.object.type == PipeWireAO.LibPipeWire.SPA_TYPE_OBJECT_Format
end
