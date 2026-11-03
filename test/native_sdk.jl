using PipeWireAO, Libdl, Test

# New callback layouts must never be interpreted by the retired native ABI.
@test library_version() == v"4.0.0"
let actual = realpath(Libdl.dlpath(PipeWireAO.LibPipeWire.PipeWireAO_jll.libpipewire_ao)),
    expected = get(ENV, "PIPEWIREAO_TEST_LIBRARY", PipeWireAO.LibPipeWire.PipeWireAO_jll.libpipewire_ao)
    @test actual == realpath(expected)
end

# Source validation can supply a retired installation without changing the active SDK.
let retired_prefix=get(ENV,"PIPEWIREAO_TEST_RETIRED_PREFIX","")
    if !isempty(retired_prefix)
        @testset "retired native ABI rejected during package initialization" begin
            mktempdir() do directory
                project=Base.active_project()
                project===nothing && error("native ABI subprocess check requires an active validation project")
                cp(project,joinpath(directory,"Project.toml"))
                manifest=joinpath(dirname(project),"Manifest.toml")
                isfile(manifest) || error("native ABI subprocess check requires a resolved validation environment")
                cp(manifest,joinpath(directory,"Manifest.toml"))
                libdir=isdir(joinpath(retired_prefix,"lib","x86_64-linux-gnu")) ?
                    joinpath(retired_prefix,"lib","x86_64-linux-gnu") : joinpath(retired_prefix,"lib")
                open(joinpath(directory,"LocalPreferences.toml"),"w") do io
                    println(io,"[PipeWireAO_jll]")
                    for (name,path) in (("libpipewire_ao_path",joinpath(libdir,"libpipewire-ao-0.3.so")),
                            ("libspa_ao_path",joinpath(libdir,"spa-ao-0.2","libspa-ao.so")),
                            ("libspa_support_path",joinpath(libdir,"spa-ao-0.2","support","libspa-support.so")))
                        isfile(path) || error("retired native library is missing: $path")
                        println(io,name," = ",repr(path))
                    end
                end
                output=IOBuffer()
                command=`$(Base.julia_cmd()) --startup-file=no --project=$directory -e 'using PipeWireAO'`
                process=run(pipeline(ignorestatus(command);stdout=output,stderr=output);wait=false)
                completed=timedwait(() -> process_exited(process),60;pollint=0.1)==:ok
                if !completed
                    kill(process)
                    wait(process)
                    error("retired native ABI startup subprocess exceeded its deadline")
                end
                wait(process)
                @test !success(process)
                @test occursin("requires native 4.x; found 3.",String(take!(output)))
            end
        end
    end
end
