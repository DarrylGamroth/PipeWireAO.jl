using PipeWireAO, Libdl, Test

# New callback layouts must never be interpreted by the retired native ABI.
@test library_version() == v"2.0.0"
let actual = realpath(Libdl.dlpath(PipeWireAO.LibPipeWire.PipeWireAO_jll.libpipewire_ao)),
    expected = get(ENV, "PIPEWIREAO_TEST_LIBRARY", PipeWireAO.LibPipeWire.PipeWireAO_jll.libpipewire_ao)
    @test actual == realpath(expected)
end
