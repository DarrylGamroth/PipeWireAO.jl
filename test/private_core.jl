using PipeWireAO
using Test

function with_array_exchange_private_core(f)
    prefix = get(ENV, "PIPEWIREAO_EXCHANGE_TEST_PREFIX", String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir))
    libdir = isdir(joinpath(prefix, "lib", "x86_64-linux-gnu")) ? joinpath(prefix, "lib", "x86_64-linux-gnu") : joinpath(prefix, "lib")
    daemon_path = joinpath(prefix, "bin", "pipewire-ao")
    mktempdir(prefix="pipewireao-array-exchange-") do directory
        runtime = joinpath(directory, "runtime")
        config = joinpath(directory, "configuration")
        mkpath(runtime)
        mkpath(config)
        remote = "ndarray-exchange-$(getpid())-$(time_ns())"
        write(joinpath(config, "private-core.conf"), """
        context.properties = { core.daemon = true core.name = $remote support.dbus = false library.use-fallback = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-scheduler-v1 }
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-link-factory }
            { name = libpipewire-module-metadata }
            { name = libpipewire-module-access }
        ]
        """)
        write(joinpath(config, "client.conf"), """
        context.properties = { support.dbus = false }
        context.spa-libs = { support.* = support/libspa-support }
        context.modules = [
            { name = libpipewire-module-protocol-native }
            { name = libpipewire-module-client-node }
            { name = libpipewire-module-metadata }
        ]
        """)
        environment = Dict("XDG_RUNTIME_DIR" => runtime, "PIPEWIREAO_RUNTIME_DIR" => runtime,
            "PIPEWIREAO_CONFIG_DIR" => config, "PIPEWIREAO_MODULE_DIR" => joinpath(libdir, "pipewire-ao-0.3"),
            "PIPEWIREAO_SPA_PLUGIN_DIR" => joinpath(libdir, "spa-ao-0.2"), "PIPEWIREAO_DEBUG" => "0",
            "LD_LIBRARY_PATH" => libdir * ":" * get(ENV, "LD_LIBRARY_PATH", ""))
        log = open(joinpath(directory, "core.log"), "w+")
        daemon = nothing
        try
            daemon = run(pipeline(addenv(`$daemon_path -c private-core.conf`, environment); stdout=log, stderr=log); wait=false)
            timedwait(() -> ispath(joinpath(runtime, remote)), 10; pollint=0.01) == :ok || error("private daemon socket deadline expired")
            withenv(environment...) do
                f(remote)
            end
            @test !Base.process_exited(daemon)
        catch
            flush(log)
            seekstart(log)
            print(stderr, read(log, String))
            rethrow()
        finally
            if daemon !== nothing
                Base.process_exited(daemon) || kill(daemon)
                wait(daemon)
            end
            close(log)
        end
    end
end

