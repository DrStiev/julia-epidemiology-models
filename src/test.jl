module test_parameters
	using DataFrames
	include("params.jl")

	df = model_params.download_dataset("data/OWID/", "https://covid.ourworldindata.org/data/owid-covid-data.csv")
	date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

	# LinearAlgebra.SingularException(3)
	# https://stackoverflow.com/questions/68967232/why-does-julia-fails-to-solve-linear-system-systematically
	# @time sys, params = model_params.system_identification(Array(day_info)', [i for i in 1:length(day_info[!, 1])])

	abm_parameters = model_params.get_abm_parameters(20, 0.01)
	model_params.save_parameters(abm_parameters, "data/parameters/", "abm_parameters")
	params = model_params.load_parameters("data/parameters/abm_parameters.jld2")
end

module test_plot
	using DataFrames, Plots
	include("params.jl")
	include("pplot.jl")

	df = model_params.read_local_dataset("data/OWID/owid-covid-data.csv")
	date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

	p = plot(plot(Array(day_info), labels=["Infected" "Tests" "Vaccinations" "Deaths"], title="Detected Dynamics"), 
		plot(Array(total_count), labels=["Susceptible" "Infected" "Deaths" "Tests"], title="Overall Dynamics"),
		plot(Array(R₀), labels="R₀", title="Reproduction Rate"))

	pplot.save_plot(p, "img/data_plot/", "cumulative_plot", "pdf")
end

module test_abm
	using Agents, DataFrames, Plots, Distributions
	using Statistics: mean

	include("params.jl")
	include("pplot.jl")
	include("graph.jl")

	df = model_params.read_local_dataset("data/OWID/owid-covid-data.csv")
	date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

	abm_parameters = model_params.get_abm_parameters(20 , 0.01, 2000)
	@time model = graph.init(; abm_parameters...)
	@time data = graph.collect(model, graph.agent_step!, graph.model_step!; n=length(date[!,1])-1)
	
	p1 = select(data, 
		Not([:happiness_happiness, :infected_detected, 
		:quarantined_detected, :recovered_detected, 
		:lockdown_detected, :vaccined_detected]))
	p2 = select(data, 
		[:infected_detected, :quarantined_detected, 
		:recovered_detected, :vaccined_detected])
	p3 = select(data, [:happiness_happiness])

	p = plot(
		plot(Array(p1), labels=["Susceptible" "Exposed" "Infected" "Recovered" "Dead"], title="ABM Full Dynamics"),
		plot(Array(p2), labels=["Infected" "Quarantined" "Recovered" "Vaccined"], title="ABM Detected Agents"),
		plot(Array(p3), labels="Happiness", title="Cumulative Happiness"),
	)
	pplot.save_plot(p, "img/abm/", "cumulative_plot", "pdf")
	
	# InexactError: Int64(122232.19613926377)
	# sys, params = model_params.system_identification(Array(p1)', 1:length(p1[!,1]))

	@time model = graph.init(; abm_parameters...)
	@time pplot.custom_video(model, graph.agent_step!, graph.model_step!; 
		title="graph_abm", path="img/video/", 
		format=".mp4", frames=length(date[!,1])-1)
end

module test_uode
	using Plots, DataFrames, Random, Distributions
	include("uode.jl")
	include("params.jl")
	include("pplot.jl")

	# must be between [0-1] otherwise strange behaviour
	u = [35488/35489, 0, 1/35489, 0, 0]
	p = [3.54, 1.0/14, 1.0/5, 1.0/280, 0.007]
	t = (1, 1231)
	prob = uode.get_ode_problem(uode.seir!, u, t, p)
	sol = uode.get_ode_solution(prob)
	
	p = plot(sol, labels=["Susceptible" "Exposed" "Infected" "Recovered" "Dead"], title="SEIR Dynamics")
	pplot.save_plot(p, "img/ode/", "cumulative_plot", "pdf")

	# LinearAlgebra.SingularException(3)
	# sys, params = model_params.system_identification(Array(sol), sol.t)
end

module test_controller
	# https://link.springer.com/article/10.1007/s40313-023-00993-8
	include("params.jl")
	include("pplot.jl")
	include("controller.jl")
	# il controllore dovrebbe prendere i dati dopo tot passi del collect e tirare le somme
	# successivamente modifica i parametri e fa riprendere il collect  e cosi via fino alla fine
end