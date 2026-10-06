@testset "native thread-loop interrupt ownership" begin
    mktempdir() do directory
        evidence = get(ENV, "PIPEWIREAO_INTERRUPT_EVIDENCE", directory)
        mkpath(evidence)
        logfile = joinpath(evidence, "child.log")
        child = nothing
        open(logfile, "w") do log
            try
                command = `$(Base.julia_cmd()) --startup-file=no --threads=2,0 --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "thread_loop_interrupt_child.jl")) $directory`
                child = run(pipeline(command; stdout=log, stderr=log); wait=false)
                ready = timedwait(() -> isfile(joinpath(directory,"waiting")) || process_exited(child),
                    30; pollint=0.002)
                ready == :ok && isfile(joinpath(directory,"waiting")) ||
                    error("owned child did not reach the blocked acquire")
                witness = read(joinpath(directory,"waiting"),String)
                @test occursin("reserved=1",witness)
                @test !occursin("holder_thread=1\n",witness)
                write(joinpath(evidence,"waiting.txt"),witness)
                write(joinpath(evidence,"owned-child-pid.txt"),string(getpid(child)))
                # Signal only this exact child, after the native holder proves
                # that its main caller reserved a pending acquire.
                kill(child, Base.SIGINT)
                sleep(0.05)
                write(joinpath(directory,"release"),"")
                timedwait(() -> process_exited(child),10; pollint=0.002) == :ok ||
                    error("owned child did not release native ownership")
                wait(child)
                @test success(child)
            finally
                if child !== nothing && process_running(child)
                    kill(child,Base.SIGKILL)
                    timedwait(() -> process_exited(child),5; pollint=0.002) == :ok ||
                        error("owned child cleanup unresolved")
                    wait(child)
                end
            end
        end
        text = read(logfile,String)
        @test occursin("interrupted=true count=0 main_thread=1",text)
        @test occursin("closed=true cross_thread_reacquired=true",text)
    end
end
