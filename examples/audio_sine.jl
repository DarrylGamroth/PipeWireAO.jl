module AudioSine

using PipeWireAO

mutable struct SineProcess
    buffer::StreamBuffer
    phase::Float32
    phase_step::Float32
    amplitude::Float32
    channels::Int
end

function SineProcess(frequency::Real, amplitude::Real, rate::Integer, channels::Integer)
    rate > 0 || throw(ArgumentError("sample rate must be positive"))
    channels > 0 || throw(ArgumentError("channel count must be positive"))
    0 <= amplitude <= 1 || throw(ArgumentError("amplitude must be between zero and one"))
    phase_step = 2f0 * Float32(pi) * Float32(frequency) / Float32(rate)
    return SineProcess(StreamBuffer(), 0f0, phase_step, Float32(amplitude), Int(channels))
end

function (process::SineProcess)(stream::Stream)
    dequeue_buffer!(process.buffer, stream) || return nothing
    try
        plane = buffer_data(process.buffer)
        samples_per_frame = process.channels
        frames = capacity(plane) ÷ (samples_per_frame * sizeof(Float32))
        samples = Ptr{Float32}(data_pointer(plane))
        phase = process.phase
        for frame in 0:(frames - 1)
            sample = process.amplitude * sin(phase)
            first_sample = frame * samples_per_frame + 1
            for channel in 0:(samples_per_frame - 1)
                unsafe_store!(samples, sample, first_sample + channel)
            end
            phase += process.phase_step
            phase >= 2f0 * Float32(pi) && (phase -= 2f0 * Float32(pi))
        end
        process.phase = phase
        set_chunk!(
            plane;
            size=frames * samples_per_frame * sizeof(Float32),
            stride=samples_per_frame * sizeof(Float32),
        )
        queue_buffer!(process.buffer, stream)
    catch
        return_buffer!(process.buffer, stream)
        rethrow()
    end
    return nothing
end

function usage(io::IO=stdout)
    println(io, "Usage: julia --project=. examples/audio_sine.jl [frequency_hz]")
    println(io, "Play a stereo Float32 sine wave until interrupted with Ctrl-C.")
    return nothing
end

function main(args=ARGS)
    if any(argument -> argument in ("-h", "--help"), args)
        usage()
        return nothing
    end
    length(args) <= 1 || throw(ArgumentError("expected at most one frequency argument"))
    frequency = isempty(args) ? 440.0 : parse(Float64, only(args))
    frequency > 0 || throw(ArgumentError("frequency must be positive"))

    rate = 48_000
    channels = 2
    context = Context()
    try
        core = CoreConnection(context)
        try
            process = SineProcess(frequency, 0.1, rate, channels)
            stream = Stream(
                core,
                "Julia sine";
                properties=Dict(
                    "media.type" => "Audio",
                    "media.category" => "Playback",
                    "media.role" => "Music",
                ),
                on_process=process,
            )
            try
                connect!(
                    stream,
                    :output;
                    params=[audio_format(format=Audio.F32, rate=rate, channels=channels)],
                )
                println("Playing ", frequency, " Hz; press Ctrl-C to stop")
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

end # module AudioSine

if abspath(PROGRAM_FILE) == @__FILE__
    AudioSine.main()
end
