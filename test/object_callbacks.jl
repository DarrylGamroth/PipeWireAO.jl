using PipeWireAO
using Test

const LPW = PipeWireAO.LibPipeWire

function callback_test_proxy(core::CoreConnection)
    callbacks = (
        on_bound=nothing,
        on_removed=nothing,
        on_done=nothing,
        on_error=nothing,
        on_bound_properties=nothing,
    )
    listener = Ref(PipeWireAO._zero_hook())
    events = Ref{LPW.pw_proxy_events}()
    proxy = Proxy(
        Ptr{LPW.pw_proxy}(C_NULL),
        core,
        "PipeWire:Interface:Test",
        UInt32(0),
        ReentrantLock(),
        ReentrantLock(),
        listener,
        events,
        callbacks,
        Ref{Any}(nothing),
        typemax(UInt32),
        false,
        true,
    )
    events[] = PipeWireAO._proxy_events(proxy)
    return proxy
end

function callback_test_object(::Type{Node}, core, callbacks)
    events = Ref{LPW.pw_node_events}()
    object = Node(
        callback_test_proxy(core),
        ReentrantLock(),
        Ref(PipeWireAO._zero_hook()),
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
    )
    events[] = PipeWireAO._node_events(object)
    return object
end

function callback_test_object(::Type{Port}, core, callbacks)
    events = Ref{LPW.pw_port_events}()
    object = Port(
        callback_test_proxy(core),
        ReentrantLock(),
        Ref(PipeWireAO._zero_hook()),
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
    )
    events[] = PipeWireAO._port_events(object)
    return object
end

function callback_test_object(::Type{Device}, core, callbacks)
    events = Ref{LPW.pw_device_events}()
    object = Device(
        callback_test_proxy(core),
        ReentrantLock(),
        Ref(PipeWireAO._zero_hook()),
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
    )
    events[] = PipeWireAO._device_events(object)
    return object
end

function callback_test_object(::Type{Link}, core, callbacks)
    events = Ref{LPW.pw_link_events}()
    object = Link(
        callback_test_proxy(core),
        ReentrantLock(),
        Ref(PipeWireAO._zero_hook()),
        events,
        callbacks,
        Ref{Any}(nothing),
        true,
    )
    events[] = PipeWireAO._link_events(object)
    return object
end

function callback_test_listener(object::Node, callbacks)
    listener = PipeWireAO._new_listener(object, LPW.pw_node_events, callbacks)
    listener.events[] = PipeWireAO._listener_node_events(listener)
    listener.active = true
    return listener
end

function callback_test_listener(object::Port, callbacks)
    listener = PipeWireAO._new_listener(object, LPW.pw_port_events, callbacks)
    listener.events[] = PipeWireAO._listener_port_events(listener)
    listener.active = true
    return listener
end

function callback_test_listener(object::Device, callbacks)
    listener = PipeWireAO._new_listener(object, LPW.pw_device_events, callbacks)
    listener.events[] = PipeWireAO._listener_device_events(listener)
    listener.active = true
    return listener
end

function callback_test_listener(object::Link, callbacks)
    listener = PipeWireAO._new_listener(object, LPW.pw_link_events, callbacks)
    listener.events[] = PipeWireAO._listener_link_events(listener)
    listener.active = true
    return listener
end

function invoke_object_info(object::T, pointer::Ptr{N}) where {T,N}
    ccall(object.events[].info, Cvoid, (Ref{T}, Ptr{N}), object, pointer)
    return nothing
end

function invoke_object_param(object::T, param::Pod) where {T}
    GC.@preserve object param ccall(
        object.events[].param,
        Cvoid,
        (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LPW.spa_pod}),
        object,
        Cint(71),
        UInt32(72),
        UInt32(73),
        UInt32(74),
        PipeWireAO._pod_pointer(param),
    )
    return nothing
end

function invoke_listener_info(listener::T, pointer::Ptr{N}) where {T<:ManagedListener,N}
    ccall(listener.events[].info, Cvoid, (Ref{T}, Ptr{N}), listener, pointer)
    return nothing
end

function invoke_listener_param(listener::T, param::Pod) where {T<:ManagedListener}
    GC.@preserve listener param ccall(
        listener.events[].param,
        Cvoid,
        (Ref{T}, Cint, UInt32, UInt32, UInt32, Ptr{LPW.spa_pod}),
        listener,
        Cint(81),
        UInt32(82),
        UInt32(83),
        UInt32(84),
        PipeWireAO._pod_pointer(param),
    )
    return nothing
end

@testset "typed object callback copies" begin
    context = Context()
    core = CoreConnection(context; self=true)

    param_infos = [
        LPW.spa_param_info(
            UInt32(21),
            UInt32(22),
            UInt32(23),
            Int32(24),
            ntuple(_ -> UInt32(0), 4),
        ),
    ]
    port_native = Ref(
        LPW.pw_port_info(
            UInt32(31),
            LPW.SPA_DIRECTION_INPUT,
            UInt64(32),
            C_NULL,
            pointer(param_infos),
            UInt32(1),
        ),
    )
    device_native = Ref(
        LPW.pw_device_info(
            UInt32(41),
            UInt64(42),
            C_NULL,
            pointer(param_infos),
            UInt32(1),
        ),
    )
    link_error = "test link error"
    link_format = Pod(Int32(43))
    link_native = Ref(
        LPW.pw_link_info(
            UInt32(51),
            UInt32(52),
            UInt32(53),
            UInt32(54),
            UInt32(55),
            UInt64(56),
            LPW.PW_LINK_STATE_ERROR,
            pointer(link_error),
            PipeWireAO._pod_pointer(link_format),
            C_NULL,
        ),
    )

    port_infos = PortInfo[]
    port_params = Tuple{Cint,UInt32,UInt32,UInt32,Union{Nothing,Pod}}[]
    port = callback_test_object(
        Port,
        core,
        (
            on_info=(port, info) -> push!(port_infos, info),
            on_param=(port, sequence, id, index, next, param) ->
                push!(port_params, (sequence, id, index, next, param)),
        ),
    )
    device_infos = DeviceInfo[]
    device_params = Tuple{Cint,UInt32,UInt32,UInt32,Union{Nothing,Pod}}[]
    device = callback_test_object(
        Device,
        core,
        (
            on_info=(device, info) -> push!(device_infos, info),
            on_param=(device, sequence, id, index, next, param) ->
                push!(device_params, (sequence, id, index, next, param)),
        ),
    )
    link_infos = LinkInfo[]
    link = callback_test_object(
        Link,
        core,
        (on_info=(link, info) -> push!(link_infos, info),),
    )
    node_params = Tuple{Cint,UInt32,UInt32,UInt32,Union{Nothing,Pod}}[]
    node = callback_test_object(
        Node,
        core,
        (
            on_info=nothing,
            on_param=(node, sequence, id, index, next, param) ->
                push!(node_params, (sequence, id, index, next, param)),
        ),
    )

    param = Pod(Int64(75))
    GC.@preserve param_infos port_native device_native link_error link_format link_native begin
        invoke_object_info(port, Base.unsafe_convert(Ptr{LPW.pw_port_info}, port_native))
        invoke_object_info(device, Base.unsafe_convert(Ptr{LPW.pw_device_info}, device_native))
        invoke_object_info(link, Base.unsafe_convert(Ptr{LPW.pw_link_info}, link_native))
        invoke_object_param(node, param)
        invoke_object_param(port, param)
        invoke_object_param(device, param)
    end

    @test only(port_infos).id == 31
    @test only(port_infos).direction == PipeWireAO.DIRECTION_INPUT
    @test only(only(port_infos).params) == ParamInfo(UInt32(21), UInt32(22), UInt32(23), Int32(24))
    @test only(device_infos).id == 41
    @test only(only(device_infos).params).id == 21
    @test only(link_infos).id == 51
    @test only(link_infos).state == PipeWireAO.LINK_STATE_ERROR
    @test only(link_infos).error == "test link error"
    @test pod_value(Int32, something(only(link_infos).format)) == 43
    for events in (node_params, port_params, device_params)
        @test only(events)[1:4] == (Cint(71), UInt32(72), UInt32(73), UInt32(74))
        @test pod_value(Int64, something(only(events)[5])) == 75
    end

    listener_port_infos = PortInfo[]
    listener_port_params = Tuple{Cint,UInt32,UInt32,UInt32,Union{Nothing,Pod}}[]
    port_listener = callback_test_listener(
        port,
        (
            on_info=(port, info) -> push!(listener_port_infos, info),
            on_param=(port, sequence, id, index, next, value) ->
                push!(listener_port_params, (sequence, id, index, next, value)),
        ),
    )
    listener_device_infos = DeviceInfo[]
    device_listener = callback_test_listener(
        device,
        (on_info=(device, info) -> push!(listener_device_infos, info), on_param=nothing),
    )
    listener_link_infos = LinkInfo[]
    link_listener = callback_test_listener(
        link,
        (on_info=(link, info) -> push!(listener_link_infos, info),),
    )
    listener_node_params = Tuple{Cint,UInt32,UInt32,UInt32,Union{Nothing,Pod}}[]
    node_listener = callback_test_listener(
        node,
        (
            on_info=nothing,
            on_param=(node, sequence, id, index, next, value) ->
                push!(listener_node_params, (sequence, id, index, next, value)),
        ),
    )

    GC.@preserve param_infos port_native device_native link_error link_format link_native begin
        invoke_listener_info(
            port_listener,
            Base.unsafe_convert(Ptr{LPW.pw_port_info}, port_native),
        )
        invoke_listener_info(
            device_listener,
            Base.unsafe_convert(Ptr{LPW.pw_device_info}, device_native),
        )
        invoke_listener_info(
            link_listener,
            Base.unsafe_convert(Ptr{LPW.pw_link_info}, link_native),
        )
        invoke_listener_param(node_listener, param)
        invoke_listener_param(port_listener, param)
    end

    @test only(listener_port_infos).id == 31
    @test only(listener_device_infos).id == 41
    @test only(listener_link_infos).id == 51
    @test only(listener_port_params)[1:4] ==
          (Cint(81), UInt32(82), UInt32(83), UInt32(84))
    @test pod_value(Int64, something(only(listener_port_params)[5])) == 75
    @test pod_value(Int64, something(only(listener_node_params)[5])) == 75

    @test_throws InvalidStateException subscribe_params!(port, [PipeWireAO.SPA.PARAM_PROPS])
    @test_throws InvalidStateException subscribe_params!(device, [PipeWireAO.SPA.PARAM_PROPS])
    @test_throws InvalidStateException enum_params!(
        port,
        PipeWireAO.SPA.PARAM_PROPS;
        count=1,
    )
    @test_throws InvalidStateException enum_params!(
        device,
        PipeWireAO.SPA.PARAM_PROPS;
        count=1,
    )
    @test_throws InvalidStateException set_param!(
        device,
        PipeWireAO.SPA.PARAM_FORMAT,
        Pod(audio_format_param()),
    )

    port.callbacks_active = false
    info_count = length(port_infos)
    GC.@preserve param_infos port_native invoke_object_info(
        port,
        Base.unsafe_convert(Ptr{LPW.pw_port_info}, port_native),
    )
    @test length(port_infos) == info_count

    malformed_port = callback_test_object(
        Port,
        core,
        (on_info=nothing, on_param=nothing),
    )
    invoke_object_info(malformed_port, Ptr{LPW.pw_port_info}(C_NULL))
    @test malformed_port.callback_error[] isa ArgumentError
    @test_throws ArgumentError subscribe_params!(
        malformed_port,
        [PipeWireAO.SPA.PARAM_PROPS],
    )

    malformed_node = callback_test_object(
        Node,
        core,
        (on_info=nothing, on_param=nothing),
    )
    malformed_device = callback_test_object(
        Device,
        core,
        (on_info=nothing, on_param=nothing),
    )
    malformed_link = callback_test_object(Link, core, (on_info=nothing,))
    invoke_object_info(malformed_node, Ptr{LPW.pw_node_info}(C_NULL))
    invoke_object_info(malformed_device, Ptr{LPW.pw_device_info}(C_NULL))
    invoke_object_info(malformed_link, Ptr{LPW.pw_link_info}(C_NULL))
    @test malformed_node.callback_error[] isa ArgumentError
    @test malformed_device.callback_error[] isa ArgumentError
    @test malformed_link.callback_error[] isa ArgumentError

    close(malformed_port)
    close(malformed_node)
    close(malformed_device)
    close(malformed_link)

    close(core)
    close(context)
end
