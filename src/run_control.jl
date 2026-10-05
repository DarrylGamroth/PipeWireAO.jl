"""Native Version 1 owner-mediated run-control request ABI struct."""
const RunControlRequest = LibPipeWire.pw_ao_run_control_request

"""Native Version 1 owner-mediated run-control status ABI struct."""
const RunControlStatus = LibPipeWire.pw_ao_run_control_status

"""Native Version 1 owner-mediated reset request ABI struct."""
const ResetControlRequest = LibPipeWire.pw_ao_reset_control_request

"""Native Version 1 owner-mediated reset status ABI struct."""
const ResetControlStatus = LibPipeWire.pw_ao_reset_control_status

const _RUN_CONTROL_VERSION_KEY = "pipewireao.run-control.version"
const _RUN_CONTROL_REQUEST_TOKEN_KEY = "pipewireao.run-control.request-token"
const _RUN_CONTROL_REQUESTED_STATE_KEY = "pipewireao.run-control.requested-state"
const _RUN_CONTROL_COMPLETED_TOKEN_KEY = "pipewireao.run-control.completed-token"
const _RUN_CONTROL_RESULT_KEY = "pipewireao.run-control.result"
const _RUN_CONTROL_ACTUAL_STATE_KEY = "pipewireao.run-control.actual-state"
const _RESET_CONTROL_VERSION_KEY = "pipewireao.reset-control.version"
const _RESET_CONTROL_REQUEST_TOKEN_KEY = "pipewireao.reset-control.request-token"
const _RESET_CONTROL_COMPLETED_TOKEN_KEY = "pipewireao.reset-control.completed-token"
const _RESET_CONTROL_RESULT_KEY = "pipewireao.reset-control.result"

function _run_control_token(token::Integer; allow_zero::Bool=false)
    (token < (allow_zero ? 0 : 1) || token > typemax(Int64)) &&
        throw(ArgumentError("control token is outside the supported Int64 range"))
    return Int64(token)
end
_run_control_token(::Bool; allow_zero::Bool=false) = throw(ArgumentError("a control token must not be Bool"))

function _run_control_result(result::Integer)
    (result < typemin(Int32) || result > typemax(Int32)) &&
        throw(ArgumentError("control result is outside the supported Int32 range"))
    return Int32(result)
end
_run_control_result(::Bool) = throw(ArgumentError("a control result must not be Bool"))

function _run_control_state(state::Symbol; allow_unknown::Bool=false)
    state === :stopped && return "stopped"
    state === :running && return "running"
    allow_unknown && state === :unknown && return "unknown"
    throw(ArgumentError("unsupported run-control state: $state"))
end

"""
    run_control_request(token::Integer, state::Symbol) -> Pod

Build a Version 1 native `SPA_PARAM_Props` request. `token` must be positive;
`state` must be `:stopped` or `:running`.
"""
function run_control_request(token::Integer, state::Symbol)
    request_token = _run_control_token(token)
    requested_state = _run_control_state(state)
    return Pod(props_param(SPA.Props(
        _RUN_CONTROL_VERSION_KEY => Int32(1),
        _RUN_CONTROL_REQUEST_TOKEN_KEY => request_token,
        _RUN_CONTROL_REQUESTED_STATE_KEY => requested_state,
    )))
end

"""
    run_control_status(token::Integer, result::Integer, state::Symbol) -> Pod

Build a Version 1 native run-control status. `token` must be nonnegative,
`result` must fit `Int32`, and `state` must be `:unknown`, `:stopped`, or
`:running`.
"""
function run_control_status(token::Integer, result::Integer, state::Symbol)
    completed_token = _run_control_token(token; allow_zero=true)
    native_result = _run_control_result(result)
    actual_state = _run_control_state(state; allow_unknown=true)
    return Pod(props_param(SPA.Props(
        _RUN_CONTROL_VERSION_KEY => Int32(1),
        _RUN_CONTROL_COMPLETED_TOKEN_KEY => completed_token,
        _RUN_CONTROL_RESULT_KEY => native_result,
        _RUN_CONTROL_ACTUAL_STATE_KEY => actual_state,
    )))
end

"Build a Version 1 native reset request. `token` must be positive."
function reset_control_request(token::Integer)
    request_token = _run_control_token(token)
    return Pod(props_param(SPA.Props(
        _RESET_CONTROL_VERSION_KEY => Int32(1),
        _RESET_CONTROL_REQUEST_TOKEN_KEY => request_token,
    )))
end

"Build a Version 1 native reset status. `token` must be nonnegative."
function reset_control_status(token::Integer, result::Integer)
    completed_token = _run_control_token(token; allow_zero=true)
    native_result = _run_control_result(result)
    return Pod(props_param(SPA.Props(
        _RESET_CONTROL_VERSION_KEY => Int32(1),
        _RESET_CONTROL_COMPLETED_TOKEN_KEY => completed_token,
        _RESET_CONTROL_RESULT_KEY => native_result,
    )))
end

function _run_control_state_code(state::Symbol; allow_unknown::Bool=false)
    state === :stopped && return LibPipeWire.PW_AO_RUN_CONTROL_STATE_STOPPED
    state === :running && return LibPipeWire.PW_AO_RUN_CONTROL_STATE_RUNNING
    allow_unknown && state === :unknown && return LibPipeWire.PW_AO_RUN_CONTROL_STATE_UNKNOWN
    throw(ArgumentError("unsupported run-control state: $state"))
end

function _control_pod!(buffer::PodBuffer, build!::F, arguments::Vararg{Any,N}) where {F,N}
    data = buffer.pod.data
    resize!(data, buffer.capacity)
    GC.@preserve data begin
        builder = buffer.builder
        builder[] = LibPipeWire.spa_pod_builder(
            pointer(data), UInt32(buffer.capacity), UInt32(0),
            LibPipeWire.spa_pod_builder_state(0, 0, C_NULL),
            LibPipeWire.spa_callbacks(C_NULL, C_NULL),
        )
        native = GC.@preserve builder build!(
            Base.unsafe_convert(Ptr{LibPipeWire.spa_pod_builder}, builder), arguments...,
        )
        native == C_NULL && throw(ArgumentError("control POD does not fit prepared buffer"))
        resize!(data, sizeof(LibPipeWire.spa_pod) + Int(unsafe_load(native).size))
    end
    return buffer.pod
end

"""
    run_control_request!(buffer::PodBuffer, token::Integer, state::Symbol) -> Pod

Build with the native SPA serializer into prepared bounded storage. The result
borrows `buffer` until its next use; do not retain it or use the buffer
concurrently. Preparation and exceptional rejection are outside the warmed
successful-call allocation budget.
"""
function run_control_request!(buffer::PodBuffer, token::Integer, state::Symbol)
    return _control_pod!(buffer, LibPipeWire.pw_ao_run_control_build_request,
        _run_control_token(token), _run_control_state_code(state))
end

"Build native run-control status into borrowed prepared storage."
function run_control_status!(buffer::PodBuffer, token::Integer, result::Integer, state::Symbol)
    return _control_pod!(buffer, LibPipeWire.pw_ao_run_control_build_status,
        _run_control_token(token; allow_zero=true), _run_control_result(result),
        _run_control_state_code(state; allow_unknown=true))
end

"Build a native reset request into borrowed prepared storage."
function reset_control_request!(buffer::PodBuffer, token::Integer)
    return _control_pod!(buffer, LibPipeWire.pw_ao_reset_control_build_request,
        _run_control_token(token))
end

"Build native reset status into borrowed prepared storage."
function reset_control_status!(buffer::PodBuffer, token::Integer, result::Integer)
    return _control_pod!(buffer, LibPipeWire.pw_ao_reset_control_build_status,
        _run_control_token(token; allow_zero=true), _run_control_result(result))
end

"""
    parse_run_control_request!(destination::Ref{RunControlRequest}, pod::Pod)::Cint

Parse with PipeWireAO's native Version 1 parser. The destination is valid only
when the return value is zero; on an error the native parser may have written
partial fields. Reuse a prepared `Ref` to parse without Julia heap allocation.
"""
function parse_run_control_request!(
    destination::Base.RefValue{RunControlRequest},
    pod::Pod,
)::Cint
    GC.@preserve destination pod begin
        return LibPipeWire.pw_ao_run_control_parse_request(
            _pod_pointer(pod),
            Base.unsafe_convert(Ptr{RunControlRequest}, destination),
        )
    end
end

"""Parse native run-control status; destination is valid only on return zero."""
function parse_run_control_status!(
    destination::Base.RefValue{RunControlStatus},
    pod::Pod,
)::Cint
    GC.@preserve destination pod begin
        return LibPipeWire.pw_ao_run_control_parse_status(
            _pod_pointer(pod),
            Base.unsafe_convert(Ptr{RunControlStatus}, destination),
        )
    end
end

"""Parse native reset request; destination is valid only on return zero."""
function parse_reset_control_request!(
    destination::Base.RefValue{ResetControlRequest},
    pod::Pod,
)::Cint
    GC.@preserve destination pod begin
        return LibPipeWire.pw_ao_reset_control_parse_request(
            _pod_pointer(pod),
            Base.unsafe_convert(Ptr{ResetControlRequest}, destination),
        )
    end
end

"""Parse native reset status; destination is valid only on return zero."""
function parse_reset_control_status!(
    destination::Base.RefValue{ResetControlStatus},
    pod::Pod,
)::Cint
    GC.@preserve destination pod begin
        return LibPipeWire.pw_ao_reset_control_parse_status(
            _pod_pointer(pod),
            Base.unsafe_convert(Ptr{ResetControlStatus}, destination),
        )
    end
end
