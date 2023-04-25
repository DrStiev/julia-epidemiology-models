module model_params
    using CSV, Random, Distributions, DataFrames, DelimitedFiles
	using Statistics: mean
    using LinearAlgebra: diagind
	using Downloads, Parameters, DifferentialEquations, LsqFit
	using DrWatson: @dict

	# FIXME: not very flexible
	const population = 60_217_965

	# https://raw.githubusercontent.com/owid/covid-19-data/master/public/data/owid-covid-data.csv
	# https://covid19.who.int/WHO-COVID-19-global-data.csv
	# https://raw.githubusercontent.com/pcm-dpc/COVID-19/master/dati-andamento-nazionale/dpc-covid19-ita-andamento-nazionale.csv
	function get_data(path, url="https://raw.githubusercontent.com/pcm-dpc/COVID-19/master/dati-andamento-nazionale/dpc-covid19-ita-andamento-nazionale.csv")
		title = split(url,"/")
		isdir(path) == false && mkpath(path)
		df = DataFrame(CSV.File(
			Downloads.download(url, path*title[length(title)]), 
			delim=",", header=1))
		return df
	end

	function read_data(path="data/italy/dpc-covid19-ita-andamento-nazionale.csv")
		return DataFrame(CSV.File(path, delim=",", header=1))
	end

	function estimate_R₀(data)
		return [data[i+1]/data[i] for i in 1:length(data)-1]
	end

	function extract_params(df, C, min_max_population, max_travel_rate, seed=1234)
		Random.seed!(seed)
		number_point_of_interest = rand(min_max_population[1]:min_max_population[2], C)
		migration_rate = zeros(C, C)
		for c in 1:C
			for c2 in 1:C
				migration_rate[c,c2] = (number_point_of_interest[c] + number_point_of_interest[c2]) / number_point_of_interest[c]
			end
		end
		maxM = maximum(migration_rate)
		migration_rate = (migration_rate .* max_travel_rate) ./ maxM
		migration_rate[diagind(migration_rate)] .= 1.0

		T = length(df[!,1])

		i = df[1,:nuovi_positivi]/population
		r = df[1,:dimessi_guariti]/population

		γ = 1.0/14 # infective period
		σ = 1.0/5.6 # exposed period
		ω = 1.0/240 # immunity period
		ξ = 0.0 # vaccine ratio
		δ = df[nrow(df), :deceduti] / sum(df[!, :nuovi_positivi]) # mortality
		η = 1.0/20 # Countermeasures (social distancing, masks, etc...) (lower is better)
		ϵ = 1E-1 # strong immune system
		θ = 0.0 # llockdown (percentage)
		q = γ # quarantine period
		R₀ = mean(estimate_R₀(df[!, :nuovi_positivi])) 
		ncontrols = df[1, :tamponi]/population # ratio of controls per day
		control_growth = mean([df[i+1, :tamponi] / df[i, :tamponi] for i in 1:length(df[!, :tamponi]) - 1])
		# https://www.cochrane.org/CD013705/INFECTN_how-accurate-are-rapid-antigen-tests-diagnosing-covid-19#:~:text=In%20people%20with%20confirmed%20COVID,cases%20had%20positive%20antigen%20tests).
		# people with confirmed covid case (:I) -> (73 with symptoms + 55 no symptoms)/2 = 64% accuracy
		# people with confirmed covid case (:E) -> 82% accuracy
		# people with no covid (:S, :R) -> 99.7% accuracy 
		control_accuracy = [0.64, 0.82, 0.997]

		return @dict(
			number_point_of_interest, migration_rate,  
			ncontrols, control_growth, T, control_accuracy,
			R₀, γ, σ, ω, ξ, δ, η, ϵ, q, θ, 
		)
	end

	function extract_params(df)
		e = 0.0/length(df[!, 1])
		i = df[1,:nuovi_positivi]/population
		r = df[1,:dimessi_guariti]/population
		d = df[1,:deceduti]/population
		s = (1.0-e-i-r-d)

		γ = 1.0/14 
		σ = 1.0/5.6 
		ω = 1.0/240 
		ξ = 0.0 
		δ = df[nrow(df), :deceduti] / sum(df[!, :nuovi_positivi]) 
		η = 1.0/20
		R₀ = mean(estimate_R₀(df[!, :nuovi_positivi]))

		u = [s, e, i, r, d] # scaled between [0-1]
		p = [R₀, γ, σ, ω, ξ, δ, η]
		return u, p, (0.0, length(df[!, 1]))
	end

	function save_parameters(params, path, title = title)
		isdir(path) == false && mkpath(path) 
		CSV.write(path*title*"_"*string(today())*".csv", DataFrame(params))
	end
end
