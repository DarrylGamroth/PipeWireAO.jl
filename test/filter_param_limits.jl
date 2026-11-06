using PipeWireAO, Test

struct FilterParamLimitRecorder
    delivered::Vector{Tuple{UInt32,Union{Nothing,Pod}}}
    rejected::Vector{Tuple{UInt32,UInt64}}
end
function (recorder::FilterParamLimitRecorder)(::Filter, ::Nothing, id::UInt32, pod::Union{Nothing,Pod})
    push!(recorder.delivered,(id,pod))
    return nothing
end
struct FilterParamLimitRejection
    recorder::FilterParamLimitRecorder
end
function (callback::FilterParamLimitRejection)(::Filter, ::Nothing, id::UInt32, size::UInt64)
    push!(callback.recorder.rejected,(id,size))
    return nothing
end
function invoke_filter_param_limit(filter::T, pointer::Ptr{PipeWireAO.LibPipeWire.spa_pod}) where {T<:Filter}
    events = filter.events[]
    GC.@preserve filter ccall(events.param_changed,Cvoid,
        (Ref{T},Ptr{Cvoid},UInt32,Ptr{PipeWireAO.LibPipeWire.spa_pod}),
        filter,C_NULL,SPA.PARAM_PROPS,pointer)
    return nothing
end
function invoke_filter_param_limit(filter::Filter,pod::Pod)
    GC.@preserve pod invoke_filter_param_limit(filter,PipeWireAO._pod_pointer(pod))
end

@testset "filter bounded parameter copies" begin
    context = Context()
    core = CoreConnection(context;self=true)
    recorder = FilterParamLimitRecorder(Tuple{UInt32,Union{Nothing,Pod}}[],Tuple{UInt32,UInt64}[])
    filter = Filter(core,"bounded-filter-parameters";max_param_bytes=16,
        on_param_changed=recorder,on_param_rejected=FilterParamLimitRejection(recorder))
    try
        exact = Pod(Int64(41))
        @test sizeof(exact) == 16
        @test invoke_filter_param_limit(filter,exact) === nothing
        @test recorder.delivered == [(SPA.PARAM_PROPS,exact)]
        @test isempty(recorder.rejected)
        @test invoke_filter_param_limit(filter,Pod("oversized parameter")) === nothing
        @test length(recorder.rejected) == 1
        @test recorder.rejected[1] == (SPA.PARAM_PROPS,UInt64(sizeof(Pod("oversized parameter"))))
        @test length(recorder.delivered) == 1
        @test filter.callback_error[] === nothing
        # No UInt32 overflow may turn an enormous declared body into an admitted copy.
        header = Ref(PipeWireAO.LibPipeWire.spa_pod(typemax(UInt32),SPA.POD_STRUCT))
        GC.@preserve header invoke_filter_param_limit(filter,Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_pod},header))
        @test last(recorder.rejected) == (SPA.PARAM_PROPS,UInt64(typemax(UInt32))+8)
        @test length(recorder.delivered) == 1
        @test invoke_filter_param_limit(filter,Ptr{PipeWireAO.LibPipeWire.spa_pod}(C_NULL)) === nothing
        @test last(recorder.delivered) == (SPA.PARAM_PROPS,nothing)
        @test invoke_filter_param_limit(filter,exact) === nothing
        @test last(recorder.delivered) == (SPA.PARAM_PROPS,exact)
        @test filter.callback_error[] === nothing
        for invalid in (0,7,-1,1<<21,big(typemax(UInt64))+1)
            @test_throws ArgumentError Filter(core,"invalid-filter-parameter-limit";max_param_bytes=invalid)
        end
    finally
        close(filter); close(core); close(context)
    end
end

@testset "filter copy admission reads only the header" begin
    context = Context()
    core = CoreConnection(context;self=true)
    recorder = FilterParamLimitRecorder(Tuple{UInt32,Union{Nothing,Pod}}[],Tuple{UInt32,UInt64}[])
    filter = Filter(core,"guarded-filter-parameter-header";max_param_bytes=16,
        on_param_changed=recorder,on_param_rejected=FilterParamLimitRejection(recorder))
    try
        if Sys.islinux()
            # The complete header is readable, but every body byte lies in a
            # protected page. Any attempt to copy the rejected body faults.
            pagesize = ccall(:getpagesize,Cint,())
            mapping = ccall(:mmap,Ptr{Cvoid},(Ptr{Cvoid},Csize_t,Cint,Cint,Cint,Int64),
                C_NULL,2*pagesize,3,0x22,-1,0)
            mapping == Ptr{Cvoid}(typemax(UInt)) && error("guard-page allocation failed")
            try
                @test ccall(:mprotect,Cint,(Ptr{Cvoid},Csize_t,Cint),mapping+pagesize,pagesize,0) == 0
                pointer = Ptr{PipeWireAO.LibPipeWire.spa_pod}(mapping+pagesize-8)
                unsafe_store!(pointer,PipeWireAO.LibPipeWire.spa_pod(UInt32(9),SPA.POD_STRUCT))
                @test invoke_filter_param_limit(filter,pointer) === nothing
                @test recorder.rejected == [(SPA.PARAM_PROPS,UInt64(17))]
                @test isempty(recorder.delivered)
                @test filter.callback_error[] === nothing
            finally
                ccall(:munmap,Cint,(Ptr{Cvoid},Csize_t),mapping,2*pagesize)
            end
        else
            @test_skip "protected body proof requires Linux mmap"
        end
    finally
        close(filter); close(core); close(context)
    end
end

@testset "minimum filter parameter limit and default behavior" begin
    context = Context()
    core = CoreConnection(context;self=true)
    recorder = FilterParamLimitRecorder(Tuple{UInt32,Union{Nothing,Pod}}[],Tuple{UInt32,UInt64}[])
    filter = Filter(core,"minimum-filter-parameter-header";max_param_bytes=8,
        on_param_changed=recorder,on_param_rejected=FilterParamLimitRejection(recorder))
    unbounded = Filter(core,"default-filter-parameter-copy";on_param_changed=recorder,
        on_param_rejected=FilterParamLimitRejection(recorder))
    dropping = Filter(core,"drop-filter-parameter-copy";max_param_bytes=8,on_param_changed=recorder)
    try
        @test invoke_filter_param_limit(filter,Pod(nothing)) === nothing
        @test last(recorder.delivered) == (SPA.PARAM_PROPS,Pod(nothing))
        # Copy admission does not trust or decode a payload. An Int with no
        # body remains an eight-byte owned POD for the consumer to reject.
        header = Ref(PipeWireAO.LibPipeWire.spa_pod(UInt32(0),SPA.POD_INT))
        GC.@preserve header invoke_filter_param_limit(filter,Base.unsafe_convert(Ptr{PipeWireAO.LibPipeWire.spa_pod},header))
        malformed = last(recorder.delivered)[2]
        @test sizeof(malformed) == 8 && pod_type(malformed) == SPA.POD_INT
        @test filter.callback_error[] === nothing
        @test invoke_filter_param_limit(unbounded,Pod(Int64(23))) === nothing
        @test last(recorder.delivered) == (SPA.PARAM_PROPS,Pod(Int64(23)))
        @test unbounded.max_param_bytes == 0
        @test isempty(recorder.rejected)
        count = length(recorder.delivered)
        @test invoke_filter_param_limit(dropping,Pod(Int64(24))) === nothing
        @test length(recorder.delivered) == count
        @test dropping.callback_error[] === nothing
    finally
        close(dropping); close(unbounded); close(filter); close(core); close(context)
    end
end

@testset "rejected parameter callback exceptions retain containment" begin
    context = Context()
    core = CoreConnection(context;self=true)
    failure = ErrorException("rejected parameter callback failure")
    filter = Filter(core,"throwing-filter-parameter-rejection";max_param_bytes=8,
        on_param_rejected=(_filter,_port,_id,_size)->throw(failure))
    try
        @test invoke_filter_param_limit(filter,Pod(Int64(23))) === nothing
        @test filter.callback_error[] === failure
        @test_throws ErrorException filter_state(filter)
    finally
        close(filter); close(core); close(context)
    end
end

isdefined(@__MODULE__,:with_array_exchange_private_core) || include("private_core.jl")
function pump_filter_parameter_limit(predicate,loop)
    deadline = time_ns()+UInt64(5_000_000_000)
    while !predicate() && time_ns() < deadline
        iterate!(loop;max_dispatches=8)
        predicate() || sleep(0.001)
    end
    return predicate()
end
@testset "remote oversized filter parameter preserves the endpoint" begin
    with_array_exchange_private_core() do remote
        loop = MainLoop()
        context = Context(loop)
        done = Tuple{UInt32,Cint}[]
        errors = String[]
        core = CoreConnection(context;properties=Dict("remote.name"=>remote))
        client_core = CoreConnection(context;properties=Dict("remote.name"=>remote),
            on_done=(_core,id,sequence)->(push!(done,(id,sequence));nothing),
            on_error=(_core,_id,_sequence,error)->(push!(errors,sprint(showerror,error));nothing))
        registry = Registry(client_core)
        recorder = FilterParamLimitRecorder(Tuple{UInt32,Union{Nothing,Pod}}[],Tuple{UInt32,UInt64}[])
        filter = Filter(core,"test.filter.parameter.limits";
            properties=Dict("node.name"=>"test.filter.parameter.limits"),max_param_bytes=16*1024,
            on_param_changed=recorder,on_param_rejected=FilterParamLimitRejection(recorder))
        node = nothing
        try
            initial = Pod(props_param(SPA.Props("value"=>Int64(0))))
            connect!(filter;flags=FILTER_INACTIVE,params=(initial,))
            @test pump_filter_parameter_limit(loop) do
                !isempty(find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>"test.filter.parameter.limits",)))
            end
            global_node = only(find_globals(registry;interface="PipeWire:Interface:Node",properties=("node.name"=>"test.filter.parameter.limits",)))
            node = bind(registry,global_node,Node)
            # A core fence establishes proxy activation before sending requests.
            sequence = sync!(client_core)
            @test pump_filter_parameter_limit(loop) do
                (UInt32(0),sequence) in done
            end
            empty!(recorder.delivered); empty!(recorder.rejected)
            oversized = Pod(props_param(SPA.Props("value"=>"x"^(16*1024))))
            @test set_param!(node,SPA.PARAM_PROPS,oversized) === node
            @test pump_filter_parameter_limit(loop) do
                !isempty(recorder.rejected)
            end
            @test only(recorder.rejected) == (SPA.PARAM_PROPS,UInt64(sizeof(oversized)))
            @test isempty(recorder.delivered)
            @test filter.callback_error[] === nothing
            normal = Pod(props_param(SPA.Props("value"=>Int64(41))))
            @test set_param!(node,SPA.PARAM_PROPS,normal) === node
            normal_sync = sync!(client_core)
            @test pump_filter_parameter_limit(loop) do
                (UInt32(0),normal_sync) in done && any(record -> record[2] == normal,recorder.delivered)
            end
            @test any(record -> record[2] == normal,recorder.delivered)
            @test isempty(errors)
            @test filter.callback_error[] === nothing
            @test isopen(filter) && isopen(core)
        finally
            node === nothing || close(node)
            close(filter); close(registry); close(client_core); close(core); close(context); close(loop)
        end
    end
end
