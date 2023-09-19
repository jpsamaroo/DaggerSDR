using SoapySDR, SoapyLMS7_jll
using FFTW
using JSON3, Serialization
using NATS
using Dagger

function configure_channel!(c_rx, config)
    c_rx.bandwidth = config[:bandwidth] * 1u"Hz"
    c_rx.frequency = config[:frequency] * 1u"Hz"
    c_rx.sample_rate = config[:sample_rate] * 1u"Hz"
end

if !isdefined(Main, :dev)
    const dev = SoapySDR.Device(Devices()[1])
    const c_rx = dev.rx[1]
    @show c_rx

    const conn = NATS.connect()

    # Listen for configuration updates
    const config_chan = Channel{Any}()
    const config_sub = subscribe(conn, "config")
    errormonitor(Threads.@spawn begin
        for msg in config_sub
            config = JSON3.read(msg.payload)
            @info "Got config: $config"
            put!(config_chan, config)
        end
        @warn "Exiting config loop!"
    end)

    # Listen for commands
    const reset = Ref{Bool}(false)
    const cmd_sub = subscribe(conn, "cmd")
    errormonitor(Threads.@spawn begin
        for msg in cmd_sub
            payload = String(msg.payload)
            if payload == "reset"
                reset[] = true
                @async begin
                    sleep(1)
                    exit(0)
                end
            else
                @warn "Unknown command: $payload"
            end
        end
    end)

    # Launch workflows
    const define_workflow_sub = subscribe(conn, "define_workflow")
    struct Workflow
        f
        args
        task
    end
    const workflows = Dict{String,Workflow}()
    errormonitor(Threads.@spawn begin
        for msg in define_workflow_sub
            def = deserialize(IOBuffer(msg.payload))
            name = def[:name]
            raw_f = def[:f]
            raw_args = def[:args]
            @info "Got workflow definition: $name = ($raw_f)($raw_args)"
            if haskey(workflows, name)
                @info "Stopping existing workflow: $name"
                Dagger.kill!(workflows[name].task)
            end
            try
                f = eval(Meta.parse(raw_f))
                args = map(arg->workflows[arg::String].task, raw_args)
                task = Dagger.spawn_streaming() do
                    Dagger.spawn(f, args...)
                end
                workflows[name] = Workflow(f, args, task)

                # Run data forwarder
                forwarding_task = Dagger.spawn_streaming() do
                    iob = IOBuffer()
                    Dagger.spawn(task) do data
                        seek(iob, 0)
                        serialize(iob, data)
                        publish(conn, "workflow/$name/data", take!(iob))
                    end
                end

                # Report any failures
                errormonitor(Threads.@spawn begin
                    try
                        fetch(forwarding_task)
                    catch err
                        err_iob = IOBuffer()
                        Base.showerror(err_iob, err)
                        Base.show_backtrace(err_iob, catch_backtrace())
                        publish(conn, "workflow/$name/status", JSON3.write((;status="error", err=String(take!(err_iob)))))
                    end
                end)
                publish(conn, "workflow/$name/status", JSON3.write((;status="running")))
            catch err
                err_iob = IOBuffer()
                Base.showerror(err_iob, err)
                Base.show_backtrace(err_iob, catch_backtrace())
                publish(conn, "workflow/$name/status", JSON3.write((;status="failure", err=String(take!(err_iob)))))
            end
        end
    end)

    # Configure and read from the SDR
    errormonitor(Threads.@spawn begin
        function set_initial_config!()
            @info "Setting initial configuration..."
            config = Dict(
                :bandwidth => 40_000_000,
                :frequency => 96_300_000,
                :sample_rate => 1_000_000
            )
            @info "Configuring to $config"
            try
                configure_channel!(c_rx, config)
            catch err
                Base.showerror(stderr, err)
                Base.show_backtrace(stderr, catch_backtrace())
                println(stderr)
                exit(0)
            end
        end
        set_initial_config!()
        stream = SDRStream(ComplexF32, c_rx)
        SoapySDR.activate!(stream)
        bufs = [zeros(ComplexF32, 20_000) for _ in 1:1]#16]
        u8_bufs = collect.(reinterpret.(UInt8, copy.(bufs)))
        function sample_sdr!()
            if reset[]
                return Dagger.finish_streaming()
            end
            if !isempty(config_chan)
                config = take!(config_chan)
                @info "Reconfiguring to $config"
                SoapySDR.deactivate!(stream)
                finalize(stream)
                sleep(0.01)
                try
                    configure_channel!(c_rx, config)
                catch err
                    @warn "Failed to reconfigure!"
                    Base.showerror(stderr, err)
                    Base.show_backtrace(stderr, catch_backtrace())
                    println(stderr)
                    set_initial_config!()
                end
                @show c_rx
                stream = SDRStream(ComplexF32, c_rx)
                SoapySDR.activate!(stream)
            end
            read!(stream, bufs)
            for idx in 1:length(bufs)
                copyto!(u8_bufs[idx], reinterpret(UInt8, bufs[idx]))
                publish(conn, "data", u8_bufs[idx])
            end
            sleep(0.1)
            return bufs[1]
        end
        t = Dagger.spawn_streaming() do
            Dagger.spawn(sample_sdr!)
        end
        workflows["sample_sdr"] = Workflow(sample_sdr!, [], t)
        fetch(t)
        @info "Exiting!"
        SoapySDR.deactivate!(stream)
        exit(0)
    end)
    #= GPS
    c_rx.bandwidth = 1.4u"kHz" #1.023u"MHz"
    c_rx.frequency = 1575.42u"MHz"
    c_rx.gain = 61u"dB"
    c_rx.sample_rate = 40u"MHz"
    =#

    #= TODO: Manage running workflows
    const workflow_cmd_sub = subscribe(conn, "workflow_cmd")
    errormonitor(Threads.@spawn begin
        for msg in workflow_cmd_sub
            cmd = JSON.read(msg.payload)
            @info "Got workflow command: $cmd"
            name = cmd.name
            if cmd.operation == "stop"
                Dagger.kill!(workflows[name].task)
            else
                @warn "Invalid workflow command: $(cmd.operation)"
            end
        end
    end)
    =#
end

wait()
