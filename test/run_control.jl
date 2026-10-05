using PipeWireAO
using Test

const RCNative = PipeWireAO.LibPipeWire

function run_control_parse_bytes(destination, pod)
    return @allocated PipeWireAO.parse_run_control_request!(destination, pod)
end

run_control_status_parse_bytes(destination, pod) =
    @allocated PipeWireAO.parse_run_control_status!(destination, pod)
reset_control_request_parse_bytes(destination, pod) =
    @allocated PipeWireAO.parse_reset_control_request!(destination, pod)
reset_control_status_parse_bytes(destination, pod) =
    @allocated PipeWireAO.parse_reset_control_status!(destination, pod)

function control_build_bytes(builder!::F, buffer, arguments::Vararg{Any,N}) where {F,N}
    builder!(buffer, arguments...)
    @allocated begin
        builder!(buffer, arguments...)
        nothing
    end
end

@testset "native owner control POD wrappers" begin
    @test isbitstype(PipeWireAO.RunControlRequest)
    @test isbitstype(PipeWireAO.RunControlStatus)
    @test isbitstype(PipeWireAO.ResetControlRequest)
    @test isbitstype(PipeWireAO.ResetControlStatus)

    run_request = PipeWireAO.run_control_request(41, :running)
    parsed_run_request = Ref(PipeWireAO.RunControlRequest(0, 0, 0))
    @test PipeWireAO.parse_run_control_request!(parsed_run_request, run_request) == 0
    @test parsed_run_request[].version == 1
    @test parsed_run_request[].token == 41
    @test parsed_run_request[].requested_state == RCNative.PW_AO_RUN_CONTROL_STATE_RUNNING

    run_status = PipeWireAO.run_control_status(41, -5, :stopped)
    parsed_run_status = Ref(PipeWireAO.RunControlStatus(0, 0, 0, 0))
    @test PipeWireAO.parse_run_control_status!(parsed_run_status, run_status) == 0
    @test parsed_run_status[].version == 1
    @test parsed_run_status[].completed_token == 41
    @test parsed_run_status[].result == -5
    @test parsed_run_status[].actual_state == RCNative.PW_AO_RUN_CONTROL_STATE_STOPPED

    unknown_status = PipeWireAO.run_control_status(0, 0, :unknown)
    @test PipeWireAO.parse_run_control_status!(parsed_run_status, unknown_status) == 0
    @test parsed_run_status[].actual_state == RCNative.PW_AO_RUN_CONTROL_STATE_UNKNOWN

    reset_request = PipeWireAO.reset_control_request(42)
    parsed_reset_request = Ref(PipeWireAO.ResetControlRequest(0, 0))
    @test PipeWireAO.parse_reset_control_request!(parsed_reset_request, reset_request) == 0
    @test parsed_reset_request[].version == 1
    @test parsed_reset_request[].token == 42

    reset_status = PipeWireAO.reset_control_status(42, -7)
    parsed_reset_status = Ref(PipeWireAO.ResetControlStatus(0, 0, 0))
    @test PipeWireAO.parse_reset_control_status!(parsed_reset_status, reset_status) == 0
    @test parsed_reset_status[].version == 1
    @test parsed_reset_status[].completed_token == 42
    @test parsed_reset_status[].result == -7

    @test_throws ArgumentError PipeWireAO.run_control_request(0, :running)
    @test_throws ArgumentError PipeWireAO.run_control_request(UInt64(typemax(Int64)) + 1, :running)
    @test_throws ArgumentError PipeWireAO.run_control_request(true, :running)
    @test_throws ArgumentError PipeWireAO.run_control_status(1, false, :stopped)
    @test_throws ArgumentError PipeWireAO.run_control_request(1, :unknown)
    @test_throws ArgumentError PipeWireAO.run_control_status(-1, 0, :stopped)
    @test_throws ArgumentError PipeWireAO.run_control_status(0, typemax(Int32) + 1, :stopped)
    @test_throws ArgumentError PipeWireAO.run_control_status(0, 0, :bad)
    @test_throws ArgumentError PipeWireAO.reset_control_request(0)
    @test_throws ArgumentError PipeWireAO.reset_control_status(-1, 0)
    @test_throws ArgumentError PipeWireAO.reset_control_status(0, typemin(Int32) - 1)

    request_token_key = "pipewireao.run-control.request-token"
    version_key = "pipewireao.run-control.version"
    state_key = "pipewireao.run-control.requested-state"
    valid_version = version_key => Int32(1)
    valid_token = request_token_key => Int64(50)
    valid_state = state_key => "running"
    malformed_requests = (
        PipeWireAO.Pod(4), # Wrong outer POD type.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_token, valid_state))), # Missing version.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, valid_state))), # Missing token.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, valid_token))), # Missing state.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, valid_version, valid_token, valid_state))), # Duplicate key.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, request_token_key => true, valid_state))), # Bool is not an Int64 token.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, request_token_key => Int32(50), valid_state))), # Wrong token POD type.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, valid_token, state_key => Int32(1)))), # Wrong state POD type.
        PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(valid_version, valid_token, state_key => "unknown"))), # Invalid request state.
    )
    for malformed in malformed_requests
        @test PipeWireAO.parse_run_control_request!(parsed_run_request, malformed) < 0
    end

    malformed_reset = PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(
        "pipewireao.reset-control.version" => Int32(1),
        "pipewireao.reset-control.request-token" => true,
    )))
    @test PipeWireAO.parse_reset_control_request!(parsed_reset_request, malformed_reset) < 0

    malformed_status = PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(
        version_key => Int32(1),
        "pipewireao.run-control.completed-token" => Int64(3),
        "pipewireao.run-control.result" => Int32(0),
        state_key => "unknown",
    )))
    @test PipeWireAO.parse_run_control_status!(parsed_run_status, malformed_status) < 0
    malformed_reset_status = PipeWireAO.Pod(PipeWireAO.props_param(PipeWireAO.SPA.Props(
        "pipewireao.reset-control.version" => Int32(1),
        "pipewireao.reset-control.completed-token" => Int64(3),
    )))
    @test PipeWireAO.parse_reset_control_status!(parsed_reset_status, malformed_reset_status) < 0

    # Warm the concrete parser path before measuring only the native parse call.
    @test PipeWireAO.parse_run_control_request!(parsed_run_request, run_request) == 0
    @test run_control_parse_bytes(parsed_run_request, run_request) == 0
    @test PipeWireAO.parse_run_control_status!(parsed_run_status, run_status) == 0
    @test run_control_status_parse_bytes(parsed_run_status, run_status) == 0
    @test PipeWireAO.parse_reset_control_request!(parsed_reset_request, reset_request) == 0
    @test reset_control_request_parse_bytes(parsed_reset_request, reset_request) == 0
    @test PipeWireAO.parse_reset_control_status!(parsed_reset_status, reset_status) == 0
    @test reset_control_status_parse_bytes(parsed_reset_status, reset_status) == 0
end

@testset "prepared native control serialization" begin
    buffer = PodBuffer(4096)
    for (builder!, builder, arguments) in (
        (run_control_request!, run_control_request, (41, :running)),
        (run_control_request!, run_control_request, (42, :stopped)),
        (run_control_status!, run_control_status, (42, -5, :stopped)),
        (run_control_status!, run_control_status, (0, 0, :unknown)),
        (reset_control_request!, reset_control_request, (43,)),
        (reset_control_status!, reset_control_status, (43, -7)),
    )
        @test builder!(buffer, arguments...) == builder(arguments...)
        @test control_build_bytes(builder!, buffer, arguments...) == 0
        # Native parsing must still agree after an ordinary collection.
        GC.gc()
        @test builder!(buffer, arguments...) == builder(arguments...)
    end
    @test_throws ArgumentError run_control_request!(buffer, true, :running)
    @test_throws ArgumentError run_control_status!(buffer, 1, false, :stopped)
    @test_throws ArgumentError run_control_request!(buffer, 1, :unknown)
    @test_throws ArgumentError reset_control_request!(PodBuffer(8), 1)
end
