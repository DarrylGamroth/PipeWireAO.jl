using Test, PipeWireAO
isdefined(@__MODULE__, :with_array_exchange_private_core) || include("private_core.jl")

@testset "stop global tracking preserves independently bound proxies" begin
    with_array_exchange_private_core() do remote
        loop = ThreadLoop("test.registry.tracking")
        context, core, registry = with_thread_loop_lock(loop) do _
            context = Context(loop)
            core = CoreConnection(context; properties=Dict("remote.name" => remote))
            context, core, Registry(core)
        end
        start!(loop)
        filter = node = listener = late = nothing
        infos = NodeInfo[]
        removed = Ref(false)
        additions = Ref(0)
        try
            filter = with_thread_loop_lock(loop) do _
                value = Filter(core, "test.registry.retained";
                    properties=Dict("node.name" => "test.registry.retained"))
                connect!(value; flags=FILTER_INACTIVE | FILTER_ASYNC)
                value
            end
            @test timedwait(5; pollint=0.01) do
                roundtrip(core)
                !isempty(find_globals(registry; properties=("node.name" => "test.registry.retained",)))
            end == :ok
            global_object = only(find_globals(registry; properties=("node.name" => "test.registry.retained",)))
            with_thread_loop_lock(loop) do _
                node = bind(registry, global_object, Node;
                    on_info=(node, info) -> (push!(infos, info); nothing),
                    on_removed=node -> (removed[] = true; nothing))
                listener = add_listener!(registry;
                    on_global_added=(registry, global_object) -> (additions[] += 1; nothing))
            end
            roundtrip(core)
            @test !isempty(infos)
            snapshot = globals(registry)
            @test stop_global_tracking!(registry) === registry
            @test stop_global_tracking!(registry) === registry
            @test isopen(registry) && isopen(node)
            @test_throws InvalidStateException close(registry)
            count_before = additions[]
            with_thread_loop_lock(loop) do _
                late = Filter(core, "test.registry.late";
                    properties=Dict("node.name" => "test.registry.late"))
                connect!(late; flags=FILTER_INACTIVE | FILTER_ASYNC)
                update_properties!(filter, Dict("test.proof" => "changed"))
            end
            @test timedwait(5; pollint=0.01) do
                roundtrip(core)
                additions[] > count_before && any(info ->
                    get(info.properties, "test.proof", nothing) == "changed", infos)
            end == :ok
            @test isempty(find_globals(registry; properties=("node.name" => "test.registry.late",)))
            @test map(object -> object.id, globals(registry)) == map(object -> object.id, snapshot)
            with_thread_loop_lock(loop) do _
                close(listener)
            end
            listener = nothing
            with_thread_loop_lock(loop) do _
                close(filter)
            end
            filter = nothing
            @test timedwait(5; pollint=0.01) do
                roundtrip(core)
                removed[]
            end == :ok
            @test isopen(registry)
        finally
            with_thread_loop_lock(loop) do _
                for resource in (listener, node, late, filter, registry, core, context)
                    resource === nothing || close(resource)
                end
            end
            close(loop)
        end
        @test_throws InvalidStateException stop_global_tracking!(registry)
    end
end
