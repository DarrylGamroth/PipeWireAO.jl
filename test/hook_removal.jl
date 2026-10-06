using Test, PipeWireAO

@testset "owned SPA hook list removal" begin
    L = PipeWireAO.LibPipeWire
    for count in (1, 2, 3)
        head = Ref(L.spa_list(C_NULL, C_NULL))
        hooks = [Ref(PipeWireAO._zero_hook()) for _ in 1:count]
        GC.@preserve head hooks begin
            head_pointer = Base.unsafe_convert(Ptr{L.spa_list}, head)
            pointers = [Ptr{L.spa_list}(Base.unsafe_convert(Ptr{L.spa_hook}, hook)) for hook in hooks]
            head[] = L.spa_list(first(pointers), last(pointers))
            for index in eachindex(hooks)
                native = hooks[index][]
                previous = index == 1 ? head_pointer : pointers[index - 1]
                following = index == count ? head_pointer : pointers[index + 1]
                hooks[index][] = L.spa_hook(L.spa_list(following, previous),
                    native.cb, native.removed, native.priv)
            end
            # Remove from the front through the final singleton; verify both
            # head directions and the surviving first/last links each time.
            for index in eachindex(hooks)
                PipeWireAO._remove_spa_hook!(hooks[index])
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
                @test head[].next == saved.next
                @test head[].prev == saved.prev
            end
        end
    end
end
