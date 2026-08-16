using Clang.Generators
using PipeWireAO_jll

const EXPORTED_INLINE_APIS = [
    "PW_API_CLIENT_IMPL",
    "PW_API_CORE_IMPL",
    "PW_API_DEVICE_IMPL",
    "PW_API_FACTORY_IMPL",
    "PW_API_LINK_IMPL",
    "PW_API_LOOP_IMPL",
    "PW_API_MODULE_IMPL",
    "PW_API_NODE_IMPL",
    "PW_API_PORT_IMPL",
    "PW_API_REGISTRY_IMPL",
    "PW_API_THREAD_IMPL",
]

cd(@__DIR__) do
    include_root = joinpath(PipeWireAO_jll.artifact_dir, "include")
    pipewire_include = joinpath(include_root, "pipewire-ao-0.3")
    spa_include = joinpath(include_root, "spa-ao-0.2")
    headers = [
        joinpath(pipewire_include, "pipewire", "pipewire.h"),
        joinpath(pipewire_include, "pipewire", "impl-module.h"),
        joinpath(pipewire_include, "pipewire", "extensions", "metadata.h"),
        joinpath(pipewire_include, "pipewire", "extensions", "profiler.h"),
        joinpath(spa_include, "spa", "param", "buffers.h"),
        joinpath(spa_include, "spa", "param", "latency.h"),
        joinpath(spa_include, "spa", "param", "port-config.h"),
        joinpath(spa_include, "spa", "param", "profile.h"),
        joinpath(spa_include, "spa", "param", "props.h"),
        joinpath(spa_include, "spa", "param", "route.h"),
        joinpath(spa_include, "spa", "param", "tag.h"),
        joinpath(spa_include, "spa", "param", "format.h"),
        joinpath(spa_include, "spa", "param", "audio", "format.h"),
        joinpath(spa_include, "spa", "param", "audio", "raw.h"),
        joinpath(spa_include, "spa", "param", "video", "format.h"),
        joinpath(spa_include, "spa", "param", "video", "raw.h"),
    ]

    all(isfile, headers) || error("one or more PipeWire headers were not found")

    options = load_options("generator.toml")
    args = get_default_args()
    append!(args, ["-I$pipewire_include", "-I$spa_include"])

    # PipeWire declares interface calls as static inline functions for normal C
    # consumers, while libpipewire also exports these implementations. Present
    # the exported subsets as ordinary functions to Clang.jl so their wrappers
    # call the JLL instead of trying to reproduce C vtable macros in Julia.
    append!(args, ["-D$name=" for name in EXPORTED_INLINE_APIS])

    output_path = normpath(@__DIR__, options["general"]["output_file_path"])
    mkpath(dirname(output_path))

    context = create_context(headers, args, options)
    build!(context)
end
