using PipeWireAO
using Test

function copy_parameter!(buffer, pod)
    GC.@preserve pod PipeWireAO._stream_parameter_pod(
        buffer, Ptr{PipeWireAO.LibPipeWire.spa_pod}(pointer(pod.data)),
    )
end

function parameter_copy_bytes(buffer, pod)
    copy_parameter!(buffer, pod)
    # The callback consumes the borrowed Pod and returns nothing. Returning a
    # boxed optional Pod to the test caller measures an additional owned result.
    @allocated begin
        copy_parameter!(buffer, pod)
        nothing
    end
end

@testset "bounded reusable stream parameter storage" begin
    @test_throws ArgumentError PodBuffer(7)
    @test_throws ArgumentError PodBuffer((1 << 20) + 1)
    buffer = PodBuffer(4096)
    request = run_control_request(73, :stopped)
    status = run_control_status(73, 0, :stopped)
    destination = Ref{RunControlRequest}()
    first = copy_parameter!(buffer, request)
    @test first.data == request.data
    @test parse_run_control_request!(destination, first) == 0
    @test destination[].token == 73
    @test parameter_copy_bytes(buffer, request) == 0
    retained = Pod(first.data)
    second = copy_parameter!(buffer, status)
    @test first === second
    @test second.data == status.data
    @test retained.data == request.data
    @test parameter_copy_bytes(buffer, status) == 0
    # Alternate lengths within capacity, including growth after shrinking.
    for value in (Pod(Int32(5)), status, request, Pod(SPA.Bytes(zeros(UInt8, 4088))))
        @test parameter_copy_bytes(buffer, value) == 0
        @test buffer.pod.data == value.data
    end
    original = copy(buffer.pod.data)
    oversized = Pod(SPA.Bytes(zeros(UInt8, 4096)))
    @test_throws ArgumentError copy_parameter!(buffer, oversized)
    @test buffer.pod.data == original
    @test PipeWireAO._stream_parameter_pod(buffer, Ptr{PipeWireAO.LibPipeWire.spa_pod}(C_NULL)) === nothing
end
