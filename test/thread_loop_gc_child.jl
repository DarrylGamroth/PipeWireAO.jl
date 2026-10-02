# Separate process: a regression in GC participation can deadlock this check.
using PipeWireAO
using Base.Threads: Atomic

struct CollectInCallback
    entered::Atomic{Bool}
    proceed::Atomic{Bool}
    completed::Atomic{Bool}
end

function (callback::CollectInCallback)(::EventSource, ::UInt64)
    callback.entered[] = true
    while !callback.proceed[]
        @ccall gc_safe=true usleep(1000::Cuint)::Cint
    end
    # Let the owner enter its native lock/join before requesting collection.
    @ccall gc_safe=true usleep(100000::Cuint)::Cint
    GC.gc(true)
    callback.completed[] = true
    return nothing
end

function check(operation)
    callback = CollectInCallback(Atomic{Bool}(false), Atomic{Bool}(true), Atomic{Bool}(false))
    loop = ThreadLoop("PipeWireAO GC participation regression")
    event = EventSource(loop, callback)
    callback(event, UInt64(0))  # Compile before the concurrent part of the check.
    callback.entered[] = callback.completed[] = false
    callback.proceed[] = false
    start!(loop)
    signal!(event)
    Base.timedwait(() -> callback.entered[], 5) === :ok || error("callback did not enter")
    callback.proceed[] = true
    if operation == "lock"
        with_thread_loop_lock(loop) do _
            callback.completed[] || error("lock acquired before callback finished")
        end
        stop!(loop)
    elseif operation == "stop"
        stop!(loop)
    else
        error("unknown check operation")
    end
    callback.completed[] || error("callback did not finish collection")
    close(event)
    close(loop)
    println("GC_CALLBACK_COMPLETE operation=", operation)
end

check(only(ARGS))
