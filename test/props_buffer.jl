using PipeWireAO
using Test

function prepared_props_build_bytes(buffer::PipeWireAO.PropsBuffer{N,T}, values::T) where {N,T}
    PipeWireAO.props!(buffer, values)
    return @allocated begin
        PipeWireAO.props!(buffer, values)
        nothing
    end
end

function prepared_props_parse_bytes(destination::Ref{T}, buffer::PipeWireAO.PropsBuffer{N,T}, pod::Pod) where {N,T}
    PipeWireAO.parse_props!(destination, buffer, pod)
    return @allocated PipeWireAO.parse_props!(destination, buffer, pod)
end

function prepared_props_word!(pod::Pod, offset::Int, word::UInt32)
    reinterpret(UInt32, @view(pod.data[offset:(offset + 3)]))[1] = word
    return pod
end

prepared_props_pod(pairs) = Pod(props_param(SPA.Props(pairs)))

@testset "prepared scalar Props storage" begin
    names = ("enabled", "count", "token", "gain", "phase", "kind")
    initial = (true, Int32(-32), Int64(1) << 48, 0.5f0, -2.25, SPA.Id(7))
    updated = (false, typemax(Int32), typemin(Int64), -0.0f0, Inf, SPA.Id(typemax(UInt32)))
    buffer = PipeWireAO.PropsBuffer(names, initial)
    destination = Ref(initial)
    expected = prepared_props_pod(ntuple(index -> names[index] => initial[index], length(names)))
    @test buffer.pod == expected
    @test PipeWireAO.parse_props!(destination, buffer, expected) == 0
    @test isequal(destination[], initial)
    retained = Pod(buffer.pod.data)
    borrowed = PipeWireAO.props!(buffer, updated)
    @test borrowed === buffer.pod
    @test borrowed == prepared_props_pod(ntuple(index -> names[index] => updated[index], length(names)))
    @test retained == expected
    @test PipeWireAO.parse_props!(destination, buffer, borrowed) == 0
    @test isequal(destination[], updated)
    reordered = prepared_props_pod(ntuple(index -> names[7 - index] => initial[7 - index], 6))
    @test PipeWireAO.parse_props!(destination, buffer, reordered) == 0
    @test isequal(destination[], initial)
    # The public allocating parser remains an independent wire-format oracle.
    decoded = SPA.Props(borrowed)
    for index in eachindex(names)
        @test decoded.values[index].first == names[index]
        @test isequal(pod_value(typeof(updated[index]), decoded.values[index].second), updated[index])
    end

    @test_throws ArgumentError PipeWireAO.PropsBuffer(("one",), ())
    @test_throws ArgumentError PipeWireAO.PropsBuffer(("one", "one"), (Int32(1), Int32(2)))
    @test_throws ArgumentError PipeWireAO.PropsBuffer(("",), (Int32(1),))
    @test_throws ArgumentError PipeWireAO.PropsBuffer(("nul\0key",), (Int32(1),))
    for value in ("text", Int16(1), UInt32(1), SPA.Fd(1), SPA.Rectangle(1, 1))
        @test_throws ArgumentError PipeWireAO.PropsBuffer(("one",), (value,))
    end
    @test_throws MethodError PipeWireAO.props!(buffer, (true, Int64(3), Int64(4), 1.0f0, 2.0, SPA.Id(2)))
    @test_throws MethodError PipeWireAO.parse_props!(Ref((Int32(1),)), buffer, borrowed)

    empty_buffer = PipeWireAO.PropsBuffer((), ())
    empty_destination = Ref(())
    @test PipeWireAO.parse_props!(empty_destination, empty_buffer, PipeWireAO.props!(empty_buffer, ())) == 0
    unicode_buffer = PipeWireAO.PropsBuffer(("phase:φ", "eightbyt", "short"), (0.5f0, Int64(8), true))
    unicode_destination = Ref(unicode_buffer.prototype)
    @test PipeWireAO.parse_props!(unicode_destination, unicode_buffer, unicode_buffer.pod) == 0
    @test unicode_destination[] == unicode_buffer.prototype
end

@testset "prepared Props rejection" begin
    names = ("version", "token")
    values = (Int32(1), Int64(42))
    buffer = PipeWireAO.PropsBuffer(names, values)
    destination = Ref(values)
    invalid = Cint(-Base.Libc.EINVAL)
    missing = Cint(-Base.Libc.ENOENT)
    valid_pairs = (names[1] => values[1], names[2] => values[2])
    for pairs in (
        (valid_pairs..., valid_pairs[1]),
        (valid_pairs[1], valid_pairs[1]),
        (valid_pairs..., "extra" => Int32(1)),
        ("unknown" => values[1], valid_pairs[2]),
        ("Version" => values[1], valid_pairs[2]),
        ("version " => values[1], valid_pairs[2]),
        (names[1] => true, valid_pairs[2]),
        (names[1] => SPA.Id(1), valid_pairs[2]),
        (names[1] => Float32(1), valid_pairs[2]),
        (valid_pairs[1], names[2] => Int32(42)),
        (valid_pairs[1], names[2] => Float64(42)),
        (valid_pairs[1], names[2] => "42"),
    )
        pod = prepared_props_pod(pairs)
        @test PipeWireAO.parse_props!(destination, buffer, pod) == invalid
        @test prepared_props_parse_bytes(destination, buffer, pod) == 0
    end
    for pairs in ((), (valid_pairs[1],), (valid_pairs[2],))
        pod = prepared_props_pod(pairs)
        @test PipeWireAO.parse_props!(destination, buffer, pod) == missing
        @test prepared_props_parse_bytes(destination, buffer, pod) == 0
    end
    # Schema version semantics belong to the caller.
    arbitrary_version = prepared_props_pod((names[1] => Int32(900), valid_pairs[2]))
    @test PipeWireAO.parse_props!(destination, buffer, arbitrary_version) == 0
    @test destination[][1] == 900
    no_params = Pod(SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, SPA.Property[]))
    @test PipeWireAO.parse_props!(destination, buffer, no_params) == missing
    for pod in (
        Pod(Int32(1)),
        Pod(SPA.Struct(Pod(Int32(1)))),
        Pod(SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, SPA.Property(SPA.PROP_PARAMS, Int32(1)))),
        Pod(SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, SPA.Property(SPA.PROP_PARAMS + 1, SPA.Struct()))),
    )
        @test PipeWireAO.parse_props!(destination, buffer, pod) == invalid
    end
    params = pod_value(SPA.Parameter, buffer.pod).object.properties[1]
    for properties in ((params, params), (params, SPA.Property(SPA.PROP_PARAMS + 1, Int32(1))))
        pod = Pod(SPA.Parameter(SPA.OBJECT_PROPS, SPA.PARAM_PROPS, properties))
        @test PipeWireAO.parse_props!(destination, buffer, pod) == invalid
    end
    for offset in (5, 9, 13, 17, 29)
        malformed = prepared_props_word!(Pod(buffer.pod.data), offset, typemax(UInt32))
        @test PipeWireAO.parse_props!(destination, buffer, malformed) == invalid
    end
end

@testset "bounded prepared Props parser" begin
    buffer = PipeWireAO.PropsBuffer(("one", "two"), (Int32(1), Int64(2)))
    destination = Ref(buffer.prototype)
    invalid = Cint(-Base.Libc.EINVAL)
    # Pod deliberately allows byte mutation after construction. Exercise every
    # truncation with both the original top header and a repaired top length.
    for length in 0:(sizeof(buffer.pod) - 1)
        malformed = Pod(buffer.pod.data)
        resize!(malformed.data, length)
        @test PipeWireAO.parse_props!(destination, buffer, malformed) < 0
        if length >= 8
            prepared_props_word!(malformed, 1, UInt32(length - 8))
            @test PipeWireAO.parse_props!(destination, buffer, malformed) < 0
        end
    end
    for offset in (1, 25, 33, buffer.offsets[1] - 8, buffer.offsets[1] + 8, buffer.offsets[2] - 8)
        for size in (UInt32(0), UInt32(1), UInt32(7), UInt32(9), typemax(UInt32))
            malformed = prepared_props_word!(Pod(buffer.pod.data), offset, size)
            @test PipeWireAO.parse_props!(destination, buffer, malformed) == invalid
            @test prepared_props_parse_bytes(destination, buffer, malformed) == 0
        end
    end
    # A Struct ending after a name has no corresponding value.
    dangling = prepared_props_word!(Pod(buffer.pod.data), 25, UInt32(16))
    resize!(dangling.data, 48)
    prepared_props_word!(dangling, 1, UInt32(40))
    @test PipeWireAO.parse_props!(destination, buffer, dangling) == invalid
    not_terminated = Pod(buffer.pod.data)
    not_terminated.data[44] = UInt8('x')
    @test PipeWireAO.parse_props!(destination, buffer, not_terminated) == invalid
    interior_nul = Pod(buffer.pod.data)
    interior_nul.data[42] = 0
    @test PipeWireAO.parse_props!(destination, buffer, interior_nul) == invalid
    trailing = Pod(buffer.pod.data)
    push!(trailing.data, 0)
    @test PipeWireAO.parse_props!(destination, buffer, trailing) == invalid
    # Invalid attempts do not poison scratch offsets for subsequent calls.
    @test PipeWireAO.parse_props!(destination, buffer, buffer.pod) == 0
    @test destination[] == buffer.prototype
end

@testset "prepared Props warmed allocation budget" begin
    # Use a function barrier, reusable Ref, and GC enabled. Preparation and the
    # public allocating oracle are outside the repeated-call contract.
    GC.enable(true)
    values = (true, Int32(2), Int64(3), 4.0f0, 5.0, SPA.Id(6))
    buffer = PipeWireAO.PropsBuffer(("bool", "int", "long", "float", "double", "id"), values)
    destination = Ref(values)
    reordered = prepared_props_pod(("id" => SPA.Id(7), "double" => 8.0,
        "float" => 9.0f0, "long" => Int64(10), "int" => Int32(11), "bool" => false))
    for _ in 1:10
        @test prepared_props_build_bytes(buffer, values) == 0
        @test prepared_props_parse_bytes(destination, buffer, buffer.pod) == 0
        @test prepared_props_parse_bytes(destination, buffer, reordered) == 0
    end
    @test destination[] == (false, Int32(11), Int64(10), 9.0f0, 8.0, SPA.Id(7))
    @test prepared_props_build_bytes(PipeWireAO.PropsBuffer((), ()), ()) == 0
    @test prepared_props_parse_bytes(Ref(()), PipeWireAO.PropsBuffer((), ()), PipeWireAO.PropsBuffer((), ()).pod) == 0
end
