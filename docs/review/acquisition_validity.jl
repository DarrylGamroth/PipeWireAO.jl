using PipeWireAO, Test
const native = PipeWireAO.LibPipeWire
if !isempty(ARGS)
    native.PipeWireAO_jll.libpipewire_ao = only(ARGS)
end
root = normpath(joinpath(@__DIR__, "..", ".."))
source = read(joinpath(root, "test", "ndarray_filter.jl"), String)
fixture = split(split(source, "function native_ndarray_filter_buffer("; limit=2)[2], "function invoke_ndarray_filter_prepare"; limit=2)[1]
Base.include_string(Main, "function native_ndarray_filter_buffer(" * fixture)
include(joinpath(root, "test", "acquisition_metadata.jl"))
include(joinpath(root, "test", "acquisition_trigger.jl"))
