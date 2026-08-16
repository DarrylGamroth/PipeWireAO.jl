module VideoCapture

using PipeWireAO

struct FormatReporter end

function (::FormatReporter)(::Stream, id::UInt32, parameter::Union{Nothing,Pod})
    id == SPA.PARAM_FORMAT || return nothing
    parameter === nothing && return nothing
    info = VideoInfoRaw(parameter)
    println(
        "Negotiated ",
        info.size.width,
        '×',
        info.size.height,
        " format=",
        info.format,
        " at ",
        info.framerate.num,
        '/',
        info.framerate.denom,
        " fps",
    )
    return nothing
end

mutable struct CaptureProcess
    buffer::StreamBuffer
    frames::UInt64
    report_every::UInt64
end

function CaptureProcess(; report_every::Integer=120)
    report_every > 0 || throw(ArgumentError("report interval must be positive"))
    return CaptureProcess(StreamBuffer(), UInt64(0), UInt64(report_every))
end

function (process::CaptureProcess)(stream::Stream)
    dequeue_buffer!(process.buffer, stream) || return nothing
    try
        plane = buffer_data(process.buffer)
        payload_size = length(bytes(plane))
        process.frames += 1
        if process.frames % process.report_every == 0
            println("Captured frame ", process.frames, " (", payload_size, " bytes)")
        end
        queue_buffer!(process.buffer, stream)
    catch
        return_buffer!(process.buffer, stream)
        rethrow()
    end
    return nothing
end

function usage(io::IO=stdout)
    println(io, "Usage: julia --project=. examples/video_capture.jl [target_global_id]")
    println(io, "Capture RGBx video frames until interrupted with Ctrl-C.")
    return nothing
end

function main(args=ARGS)
    if any(argument -> argument in ("-h", "--help"), args)
        usage()
        return nothing
    end
    length(args) <= 1 || throw(ArgumentError("expected at most one target global ID"))
    target = isempty(args) ? typemax(UInt32) : parse(UInt32, only(args))

    context = Context()
    try
        core = CoreConnection(context)
        try
            process = CaptureProcess()
            stream = Stream(
                core,
                "Julia video capture";
                properties=Dict(
                    "media.type" => "Video",
                    "media.category" => "Capture",
                    "media.role" => "Camera",
                ),
                on_param_changed=FormatReporter(),
                on_process=process,
            )
            try
                connect!(
                    stream,
                    :input;
                    target=target,
                    params=[
                        video_format(
                            format=Video.RGBx,
                            size=SPA.Rectangle(640, 480),
                            framerate=SPA.Fraction(30, 1),
                        ),
                    ],
                )
                println("Capturing video; press Ctrl-C to stop")
                run!(stream)
            finally
                close(stream)
            end
        finally
            close(core)
        end
    finally
        close(context)
    end
    return nothing
end

end # module VideoCapture

if abspath(PROGRAM_FILE) == @__FILE__
    VideoCapture.main()
end
