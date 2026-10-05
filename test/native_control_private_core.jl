using PipeWireAO, Test
include("private_core.jl")

function publish_batch(stream,parameters)
    with_thread_loop_lock(main_loop(stream)) do _
        update_params!(stream,parameters)
    end
    return nothing
end
function batch_publication_bytes(stream,parameters,observer_loop)
    # @allocated reads process-wide counters. This fixture's independent Node
    # observer copies native info/parameters on its loop thread; those cold
    # client allocations can overlap even an idle measurement. In deployment
    # the observer runs in a separate supervisor process. Hold only its loop
    # during this library microbenchmark; the entire publisher call, including
    # its loop lock and native update, remains inside the allocation budget.
    # Enumeration below runs after releasing the observer and checks every
    # retained parameter. This isolation is not a whole-application budget.
    return with_thread_loop_lock(observer_loop) do _
        publish_batch(stream,parameters)
        @allocated publish_batch(stream,parameters)
    end
end

@testset "prepared native parameter sets on a private core" begin
    with_array_exchange_private_core() do remote
        loop = ThreadLoop("test.control.publisher")
        context,core = with_thread_loop_lock(loop) do _
            context = Context(loop)
            context,CoreConnection(context;properties=Dict("remote.name"=>remote))
        end
        start!(loop)
        client_loop = ThreadLoop("test.control.observer")
        client_context,client_core,registry = with_thread_loop_lock(client_loop) do _
            observer_context = Context(client_loop)
            observer_core = CoreConnection(observer_context;properties=Dict("remote.name"=>remote))
            observer_context,observer_core,Registry(observer_core)
        end
        start!(client_loop)
        stream = node = nothing
        observed = Pod[]
        try
            stream = with_thread_loop_lock(loop) do _
                value = Stream(core,"test.controls";properties=Dict("node.name"=>"test.controls"))
                format = NdArrayFormat(NdArray.U16_LE,(2,2);layout=NdArray.ROW_MAJOR)
                connect!(value,:output;flags=STREAM_INACTIVE|STREAM_MAP_BUFFERS,
                    params=(ndarray_format(format;schema="test.control/1"),))
                value
            end
            @test timedwait(5;pollint=0.01) do
                roundtrip(registry)
                !isempty(find_globals(registry;interface="PipeWire:Interface:Node",
                    properties=("node.name"=>"test.controls",)))
            end == :ok
            source = only(find_globals(registry;interface="PipeWire:Interface:Node",
                properties=("node.name"=>"test.controls",)))
            node = with_thread_loop_lock(client_loop) do _
                bind(registry,source,Node;on_param=(node,sequence,id,index,next,pod)->begin
                    pod === nothing || push!(observed,pod)
                    nothing
                end)
            end
            roundtrip(client_core)
            function enumerate(id)
                # A roundtrip on the subscriber does not order messages from
                # the publisher's independent connection. Flush that source
                # first before inspecting the complete retained native set.
                roundtrip(core)
                with_thread_loop_lock(client_loop) do _
                    empty!(observed)
                    enum_params!(node,id)
                end
                roundtrip(client_core)
                return with_thread_loop_lock(client_loop) do _
                    copy(observed)
                end
            end
            initial_format = enumerate(SPA.PARAM_ENUM_FORMAT)
            @test length(initial_format)==1
            empty_parameters = PreparedParams(())
            @test batch_publication_bytes(stream,empty_parameters,client_loop)==0
            @test enumerate(SPA.PARAM_ENUM_FORMAT)==initial_format

            run = PodBuffer(512)
            reset = PodBuffer(512)
            snapshot = PropsBuffer(("test.source.token","test.source.sequence"),(Int64(7),Int64(3)))
            rejection = PropsBuffer(("test.rejection.token",),(Int64(0),))
            run_control_status!(run,7,0,:stopped)
            reset_control_status!(reset,0,0)
            single = PreparedParams((run.pod,))
            @test batch_publication_bytes(stream,single,client_loop)==0
            @test enumerate(SPA.PARAM_PROPS)==[run.pod]
            parameters = PreparedParams((run.pod,reset.pod,snapshot.pod,rejection.pod))
            GC.gc() # Julia owners retain every native input through collection.
            @test batch_publication_bytes(stream,parameters,client_loop)==0
            @test enumerate(SPA.PARAM_PROPS)==collect(parameters.params)
            @test enumerate(SPA.PARAM_ENUM_FORMAT)==initial_format

            # A different native parameter ID is retained; all same-ID Props
            # are supplied together again. Current pointers are rebuilt per use.
            info = Pod(prop_info_param(SPA.PropInfo("test.gain",Pod(0.5f0);description="test gain")))
            mixed = PreparedParams((info,parameters.params...))
            @test batch_publication_bytes(stream,mixed,client_loop)==0
            @test enumerate(SPA.PARAM_PROP_INFO)==[info]
            @test enumerate(SPA.PARAM_PROPS)==collect(parameters.params)
            run_control_status!(run,8,0,:running)
            props!(snapshot,(Int64(8),Int64(4)))
            GC.gc()
            @test batch_publication_bytes(stream,parameters,client_loop)==0
            @test enumerate(SPA.PARAM_PROPS)==collect(parameters.params)
            @test enumerate(SPA.PARAM_PROP_INFO)==[info]
            @test enumerate(SPA.PARAM_ENUM_FORMAT)==initial_format
        finally
            with_thread_loop_lock(client_loop) do _
                node===nothing || close(node)
                close(registry);close(client_core);close(client_context)
            end
            close(client_loop)
            with_thread_loop_lock(loop) do _
                stream===nothing || close(stream)
                close(core);close(context)
            end
            close(loop)
        end
    end
end
