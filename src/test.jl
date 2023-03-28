using Distributed # distributed computing

addprocs(10)
@time @everywhere include("graph_model.jl")

@time params = create_params(
	C = 8,
	min_population = 50,
	max_population = 5000,
	max_travel_rate = 0.01, 
	infection_period = 18, 
	reinfection_probability = 0.15,
	detection_time = 5,
	quarantine_time = 14,
	death_rate = 0.044,
	)
@time model = model_init(; params...)
# parametri interattivi modello
@time interactive_params = Dict(
	:infection_period => 1:1:45,
	:detection_time => 1:1:21,
	:quarantine_time => 1:1:45,
)
@time fig = interactive_graph_plot(model, interactive_params)
# @time abmobs
@time fig