using Test, PipeWireAO

function count_hook_removal(hook::Ptr{PipeWireAO.LibPipeWire.spa_hook})
    count = Ptr{Cint}(unsafe_load(hook).priv)
    unsafe_store!(count, unsafe_load(count) + Cint(1))
    return nothing
end

@testset "owned SPA hook list removal" begin
    L = PipeWireAO.LibPipeWire
    removed = @cfunction(count_hook_removal, Cvoid, (Ptr{PipeWireAO.LibPipeWire.spa_hook},))
    for count in (1, 2, 3)
        head = Ref(L.spa_list(C_NULL, C_NULL))
        hooks = [Ref(PipeWireAO._zero_hook()) for _ in 1:count]
        removals = Ref{Cint}(0)
        GC.@preserve head hooks removals begin
            counter = Base.unsafe_convert(Ptr{Cint}, removals)
            head_pointer = Base.unsafe_convert(Ptr{L.spa_list}, head)
            pointers = [Ptr{L.spa_list}(Base.unsafe_convert(Ptr{L.spa_hook}, hook)) for hook in hooks]
            head[] = L.spa_list(first(pointers), last(pointers))
            for index in eachindex(hooks)
                native = hooks[index][]
                previous = index == 1 ? head_pointer : pointers[index - 1]
                following = index == count ? head_pointer : pointers[index + 1]
                hooks[index][] = L.spa_hook(L.spa_list(following, previous),
                    native.cb, removed, counter)
            end
            # Remove from the front through the final singleton; verify both
            # head directions and the surviving first/last links each time.
            for index in eachindex(hooks)
                PipeWireAO._remove_spa_hook!(hooks[index])
                @test removals[] == index
                if index == count
                    @test head[].next == head_pointer
                    @test head[].prev == head_pointer
                else
                    @test head[].next == pointers[index + 1]
                    @test head[].prev == last(pointers)
                    @test unsafe_load(pointers[index + 1]).prev == head_pointer
                    @test unsafe_load(last(pointers)).next == head_pointer
                end
                @test hooks[index][].link.next == C_NULL
                @test hooks[index][].link.prev == C_NULL
                saved = head[]
                PipeWireAO._remove_spa_hook!(hooks[index])
                @test removals[] == index
                @test head[].next == saved.next
                @test head[].prev == saved.prev
            end
        end
    end
end

@testset "closing a listener with an unlinked hook" begin
    L = PipeWireAO.LibPipeWire
    listener = PipeWireAO._new_listener(IOBuffer(), L.pw_core_events, (;))
    removals = Ref{Cint}(0)
    removed = @cfunction(count_hook_removal, Cvoid, (Ptr{PipeWireAO.LibPipeWire.spa_hook},))
    GC.@preserve removals begin
        native = listener.hook[]
        listener.hook[] = L.spa_hook(native.link, native.cb, removed,
            Base.unsafe_convert(Ptr{Cint}, removals))
        PipeWireAO._activate_listener!(listener)
        close(listener)
        close(listener)
        @test !isopen(listener)
        @test removals[] == 0
    end
end
