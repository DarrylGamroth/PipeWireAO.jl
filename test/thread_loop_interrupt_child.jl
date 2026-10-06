# Child-only regression: the parent signals this exact process while its main
# thread waits for a mutex held by the native event callback. No science runs.
using PipeWireAO
using Base.Threads: Atomic
Base.exit_on_sigint(false)

struct InterruptLockCallback
    entered::Atomic{Bool}
    completed::Atomic{Bool}
    release_path::String
    waiting_path::String
end

function (callback::InterruptLockCallback)(event::EventSource, ::UInt64)
    callback.entered[] = true
    recorded = false
    while !isfile(callback.release_path)
        count = lock(event.loop.state_lock) do
            event.loop.native_access_count
        end
        if count > 0 && !recorded
            # The main caller has reserved its native access and cannot acquire
            # the mutex until this owner-thread callback returns.
            write(callback.waiting_path, "reserved=$count holder_thread=$(Threads.threadid())\n")
            recorded = true
        end
        @ccall gc_safe=true usleep(1000::Cuint)::Cint
    end
    callback.completed[] = true
    return nothing
end

observe_interrupt(::InterruptException) = true
observe_interrupt(error) = throw(error)

function check(directory)
    Threads.threadid() == 1 || error("main ownership probe must run on thread 1")
    Threads.nthreads() == 2 || error("cross-thread ownership probe requires two Julia threads")
    callback = InterruptLockCallback(Atomic{Bool}(false), Atomic{Bool}(false),
        joinpath(directory, "release"), joinpath(directory, "waiting"))
    loop = ThreadLoop("interrupt ownership regression")
    event = EventSource(loop, callback)
    write(callback.release_path, "")
    callback(event, UInt64(0))
    rm(callback.release_path)
    callback.entered[] = callback.completed[] = false
    start!(loop)
    signal!(event)
    timedwait(() -> callback.entered[], 5; pollint=0.001) == :ok ||
        error("native callback did not acquire its mutex")
    interrupted = false
    try
        with_thread_loop_lock(loop) do _
            callback.completed[] || error("mutex acquired before the holder returned")
        end
    catch error
        interrupted = observe_interrupt(error)
    end
    count = lock(loop.state_lock) do
        loop.native_access_count
    end
    println("INTERRUPT_OWNERSHIP interrupted=$interrupted count=$count main_thread=$(Threads.threadid())")
    close(event)
    if count != 0
        # Do not join a native loop with a potentially leaked mutex. Report the
        # failed guard and let the parent observe this owned process's exit.
        println("INTERRUPT_OWNERSHIP closed=false cross_thread_reacquired=false")
        return 1
    end
    reacquired = Atomic{Bool}(false)
    Threads.@threads :static for index in 1:2
        if index == 2
            Threads.threadid() == 2 || error("probe moved from its designated OS thread")
            with_thread_loop_lock(loop) do _
                reacquired[] = true
            end
        end
    end
    reacquired[] || error("a distinct OS thread did not reacquire the native mutex")
    stop!(loop)
    close(loop)
    !isopen(loop) || error("owned loop did not close")
    println("INTERRUPT_OWNERSHIP closed=true cross_thread_reacquired=true")
    return interrupted ? 0 : 1
end

exit(check(only(ARGS)))
