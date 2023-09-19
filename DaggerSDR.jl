### A Pluto.jl notebook ###
# v0.19.27

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ 65c37596-2a2e-4d4f-95f8-ed7040272355
begin
	using Pkg
	Pkg.develop(path="/home/jpsamaroo/.julia/dev/NATS")
	using NATS
end

# ╔═╡ a577e8a8-39f0-11ee-0701-19305196139a
using FFTW, Statistics, LinearAlgebra

# ╔═╡ ecefd407-022b-4b73-9d3d-2f94234131ab
using CairoMakie

# ╔═╡ 49d56d70-5882-4a7d-b30d-e84871746891
using JSON3, Serialization, Unitful

# ╔═╡ 9b210176-6aad-43bf-9e30-35084d6f259f
using PlutoUI, PlutoHooks

# ╔═╡ 2d7f6e98-c0ce-49a5-9b39-78eaf7d44b70
conn = NATS.connect()

# ╔═╡ 3f2b5d8e-4bea-4bee-b6bc-708bf1a2fd84
null_data = zeros(ComplexF32, 20_000);

# ╔═╡ b7756414-83bf-460b-9adf-57d7f90e0beb
macro use_subscribe(name, null, f)
	quote
		name = $(esc(name))
		null = $(esc(null))
		f = $(esc(f))

		data, data_put = PlutoHooks.@use_state(null)

		PlutoHooks.@use_effect([$conn]) do
			data_sub = subscribe($conn, name)
			task = Task() do
				#@async println(stdout, "Subscribed!")
				for msg in data_sub
					data_interp = f(msg.payload)
					#println(stdout, "Got raw data: $(typeof(data_interp))")
					if data_put !== nothing
						data_put(data_interp)
						#println(stdout, "Pushed data")
					else
						@warn "null data_put"
						#println(stdout, "Got null data_put")
					end
					if !isopen(data_sub.channel)
						@warn "Exiting listen loop"
						break
					end
					yield()
				end
			end
			errormonitor(schedule(task))
			
			return function()
				#println(stdout, "Unsubscribing!")
				unsubscribe($conn, data_sub)
			end
		end
		data
	end
end

# ╔═╡ 39ec85a2-eb8b-4779-a315-0c1f9152eed8
data = @use_subscribe("data", null_data, payload->collect(reinterpret(ComplexF32, payload)));

# ╔═╡ d942a80d-5528-4e4d-97cb-2a192dbb45a6
begin
	plan = plan_fft(null_data)
	_data_fft_raw = similar(null_data)
	_data_fft = zeros(Float32, 20_000)
end;

# ╔═╡ cf3febba-61ae-4729-b8db-ac32919a7bc7
begin
	mul!(_data_fft_raw, plan, data)
	#data_fft_raw = plan * data;
	data_fft_raw = _data_fft_raw
end;

# ╔═╡ 29d62bc3-c76b-47e6-9f1f-a1cd4cadcade
begin
	_data_fft .= log10.(abs.(real.(fftshift(data_fft_raw))))
	data_fft = _data_fft
end;

# ╔═╡ 277e4c1b-edca-4349-ac18-f3ab8cd7874e
lines(data_fft; axis=(;xtickformat=xs->repr.((xs ./ length(data_fft)) .* (2*107.9)), limits=(nothing, (-1.0, 1.0))))

# ╔═╡ e8035ab6-6608-42fd-8e12-2727914e3b9f
@bind frequency PlutoUI.Slider(88.1:0.1:107.9; default=96.3, show_value=true)

# ╔═╡ 5d2f200e-224b-4690-a0e1-71ab55974466
@bind sample_rate PlutoUI.Slider(1:30; default=1, show_value=true)

# ╔═╡ e0363c46-7e0f-41d0-b1f8-d0c55ac56755
begin
	b_reset = @bind reset PlutoUI.Button("Reset")
	reset

	publish(conn, "cmd", "reset")

	b_reset
end

# ╔═╡ 434e15c0-1db0-4d9b-85b1-1c691c75de01
function define_workflow!(name::String, f::String, args::Vector{String}=String[])
	workflow = Dict(
		:name => name,
		:f => f,
		:args => args
	)
	iob = IOBuffer()
	serialize(iob, workflow)
	publish(conn, "define_workflow", String(take!(iob)))
end

# ╔═╡ 1266cde6-bb33-410d-83b5-c51f69718388
define_workflow!("signal_avg",
				 "signal -> sum(signal) / length(signal)",
				 ["sample_sdr"])

# ╔═╡ 4c0f451a-8c25-44e7-841f-bdd1c51a6194
@use_subscribe("workflow/signal_avg/status", nothing, JSON3.read)

# ╔═╡ a43193df-8786-4a2f-93f6-8ae4985feb99
@use_subscribe("workflow/signal_avg/data", nothing, x->deserialize(IOBuffer(x)))

# ╔═╡ e10d775f-848d-453f-ae58-ee5e4cef988c
define_workflow!("signal_avg_str",
				 "avg -> \"Average is \$avg\"",
				 ["signal_avg"])

# ╔═╡ 8537944b-86e1-451f-adde-ffff44fd14d3
@use_subscribe("workflow/signal_avg_str/status", nothing, JSON3.read)

# ╔═╡ 28f2a499-b4d4-43bb-ad28-a4e9514bbee0
@use_subscribe("workflow/signal_avg_str/data", nothing, x->deserialize(IOBuffer(x)))

# ╔═╡ 790fbe16-1673-4200-bc04-16817b7e2553
begin
	config = Dict(
		# FM Radio (JackFM Nashville)
		:bandwidth => 1_400_000,
		:frequency => round(Int, frequency * 1_000_000),
		:sample_rate => round(Int, sample_rate * 1_000_000),
	);
end

# ╔═╡ a91996a3-2eed-4938-accb-890cd80285f2
begin
	b_send_config = @bind send_config PlutoUI.Button("Send Config")
	send_config

	publish(conn, "config", JSON3.write(config))

	b_send_config
end

# ╔═╡ Cell order:
# ╠═65c37596-2a2e-4d4f-95f8-ed7040272355
# ╠═a577e8a8-39f0-11ee-0701-19305196139a
# ╠═ecefd407-022b-4b73-9d3d-2f94234131ab
# ╠═49d56d70-5882-4a7d-b30d-e84871746891
# ╠═9b210176-6aad-43bf-9e30-35084d6f259f
# ╠═2d7f6e98-c0ce-49a5-9b39-78eaf7d44b70
# ╟─3f2b5d8e-4bea-4bee-b6bc-708bf1a2fd84
# ╟─b7756414-83bf-460b-9adf-57d7f90e0beb
# ╠═39ec85a2-eb8b-4779-a315-0c1f9152eed8
# ╟─d942a80d-5528-4e4d-97cb-2a192dbb45a6
# ╟─cf3febba-61ae-4729-b8db-ac32919a7bc7
# ╟─29d62bc3-c76b-47e6-9f1f-a1cd4cadcade
# ╠═277e4c1b-edca-4349-ac18-f3ab8cd7874e
# ╠═e8035ab6-6608-42fd-8e12-2727914e3b9f
# ╠═5d2f200e-224b-4690-a0e1-71ab55974466
# ╟─a91996a3-2eed-4938-accb-890cd80285f2
# ╟─e0363c46-7e0f-41d0-b1f8-d0c55ac56755
# ╟─434e15c0-1db0-4d9b-85b1-1c691c75de01
# ╠═1266cde6-bb33-410d-83b5-c51f69718388
# ╠═4c0f451a-8c25-44e7-841f-bdd1c51a6194
# ╠═a43193df-8786-4a2f-93f6-8ae4985feb99
# ╠═e10d775f-848d-453f-ae58-ee5e4cef988c
# ╠═8537944b-86e1-451f-adde-ffff44fd14d3
# ╠═28f2a499-b4d4-43bb-ad28-a4e9514bbee0
# ╟─790fbe16-1673-4200-bc04-16817b7e2553
