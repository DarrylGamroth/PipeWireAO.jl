# Validate the replacement Properties contract against the explicitly selected SDK.
using PipeWireAO, Test
root = normpath(joinpath(@__DIR__, "..", ".."))
for file in ("native_sdk.jl", "ndarray_filter.jl", "buffer_properties.jl",
        "acquisition_metadata.jl", "acquisition_trigger.jl")
    include(joinpath(root, "test", file))
end
