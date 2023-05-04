module graph
	using Agents, Random, DataFrames
	using DrWatson: @dict
	using StatsBase: sample, Weights
	using InteractiveDynamics
	using Statistics: mean
	using Distributions

	@agent Person GraphAgent begin
		days_infected::Int
		days_immunity::Int
		days_quarantined::Int
		status::Symbol # :S, :E, :I, :R (:V)
		detected::Symbol # :S, :I, :Q, :R (:V)
		happiness::Float64 # [-1, 1]
	end

	function init(;
		number_point_of_interest, migration_rate, 
		threshold_before_growth,
		ncontrols, control_growth, control_accuracy,
		R₀, # R₀ 
		γ,  # 1/ periodo infettivita'
		σ,  # 1/ periodo esposizione
		ω,  # 1/ periodo immunita
		ξ,  # 1 / vaccinazione per milion per day
		δ,  # mortality rate
		η,  # 1 / countermeasures
		ϵ,  # probability of strong immune system (only E to S)
		q,  # 1 / periodo quarantena
		θ,  # 1 / percentage of people under full lockdown
		θₜ, # duration of lockdown ≥ 0
		T,
		seed = 1234,
		)
		rng = Xoshiro(seed)
		C = length(number_point_of_interest)
		# normalizzo il migration rate
		migration_rate_sum = sum(migration_rate, dims=2)
		for c in 1:C
			migration_rate[c, :] ./= migration_rate_sum[c]
		end
		# scelgo il punto di interesse che avrà il paziente zero
		Is = [zeros(Int, length(number_point_of_interest) - 1)..., 1]
		ncontrols *= sum(number_point_of_interest)

		properties = @dict(
			number_point_of_interest, migration_rate, θₜ,
			control_accuracy, ncontrols, control_growth, θ,
			R₀, γ, σ, ω, δ, ξ, β = R₀/γ, η, ϵ, q, T, Is, C,
			threshold_before_growth, infected_detected_ratio, 
		)
		
		# creo il modello 
		model = ABM(Person, GraphSpace(Agents.Graphs.complete_graph(C)); properties, rng)

		# aggiungo la mia popolazione al modello
		for city in 1:C, _ in 1:number_point_of_interest[city]
			add_agent!(city, model, 0, 0, 0, :S, :S, 0.0) # Suscettibile
		end
		# aggiungo il paziente zero
		for city in 1:C
			inds = ids_in_position(city, model)
			for n in 1:Is[city]
				agent = model[inds[n]]
				agent.status = :I # Infetto
				agent.days_infected = 1
			end
		end
		return model
	end

	function model_step!(model)
		# campiono solamente gli agenti non in quarantena, 
		# in quanto di quelli in :Q conosco già lo stato
		population_vector = [agent for agent in allagents(model)]
		population_sample = sample(filter(x -> x.detected ≠ :Q, population_vector), round(Int, model.ncontrols))
		res = [result!(p, model) for p in population_sample]
		model.infected_detected_ratio = count(r == :I for r in res) / length(res)
		# TODO: DA SOSTITUIRE E METTERE ALL'INTERNO DEL CONTROLLER
		# aumento il numero di controlli sse ho una alta percentuale di infetti
		if model.infected_detected_ratio ≥ model.threshold_before_growth # percentuale infetti
			model.ncontrols *= model.control_growth
		end
		model.θₜ > 0 && (model.θₜ -= 1)
	end

	function agent_step!(agent, model)
		# mantengo la happiness tra [-1, 1]
		agent.happiness = agent.happiness > 1.0 ? 1.0 : agent.happiness < -1.0 ? -1.0 : agent.happiness
		# θ: variabile lockdown (percentuale)
		if rand(model.rng) ≤ model.θ && model.θₜ > 0
			agent.happiness += rand(Uniform(-0.2, 0.05))
		else
			if agent.detected ≠ :Q
				# possibilità di ottenere happiness negativa per via 
				# delle contromisure troppo stringenti
				rand(model.rng) > model.η && (agent.happiness += rand(Uniform(-0.01, 0.0)))
				# possibilità di migrare e infettare sse non in quarantena
				migrate!(agent, model)
				transmit!(agent, model)
			end
		end
		update_status!(agent, model)
		update_detection!(agent, model)
		recover_or_die!(agent, model)
		exit_quarantine!(agent, model)
	end	

	function result!(agent, model)
		if agent.status == :I
			agent.detected = rand(model.rng) ≤ model.control_accuracy[1] ? :I : :S
		elseif agent.status == :E
			agent.detected = rand(model.rng) ≤ model.control_accuracy[2] ? :I : :S
		else 
			agent.detected = rand(model.rng) ≤ model.control_accuracy[3] ? :S : :I
		end
		return agent.detected
	end

	function migrate!(agent, model)
		pid = agent.pos
		m = sample(model.rng, 1:(model.C), Weights(model.migration_rate[pid, :]))
		if m ≠ pid
			move_agent!(agent, m, model)
			agent.happiness += rand(Uniform(-0.05,  0.2))
		end
	end

	function transmit!(agent, model)
		agent.status != :I && return
		#println(ids_in_position(agent, model))
		for contactID in ids_in_position(agent, model)
			contact = model[contactID]  
			# assunzione stravagante sul lockdown
			lock = model.θₜ > 0 ? (1.0-model.θ) : 1
			if contact.status == :S && rand(model.rng) ≤ (model.β * model.η * lock)
				contact.status = :E 
				#println("[$agent - $contact]")
			end
		end
		#println()
	end

	function update_status!(agent, model)
		# fine periodo di latenza
		if agent.status == :E
			agent.days_infected += 1
			if rand(model.rng) ≤ model.ϵ
				agent.status = :S
				agent.days_infected = 0
			elseif agent.days_infected ≥ model.σ
				agent.status = :I
				agent.days_infected = 1
			end
		# avanzamento malattia + possibilità di andare in quarantena
		elseif agent.status == :I
			agent.days_infected += 1
		# perdita progressiva di immunità e aumento rischio exposure
		elseif agent.status == :R
			agent.days_immunity -= 1
			if rand(model.rng) ≤ 1/agent.days_immunity 
				agent.status = :S
				agent.days_infected = 0
				agent.days_immunity = 0
			end
		end
	end

	function update_detection!(agent, model)
		# probabilità di vaccinarsi
		if agent.detected == :S
			if rand(model.rng) ≤ model.ξ 
				agent.status = :R
				agent.detected = :R
				agent.days_immunity = model.ω
			end
		# metto in quarantena i pazienti che scopro essere positivi
		elseif agent.detected == :I
			agent.detected = :Q
			agent.days_quarantined = 1
		# avanzamento quarantena
		elseif agent.detected == :Q 
			agent.days_quarantined += 1
			agent.happiness += rand(Uniform(-0.05, 0.05))
			# troppa o troppo poca felicita' possono portare problemi
			if rand(model.rng) > 1-abs(agent.happiness) 
				migrate!(agent, model)
				transmit!(agent, model)
			end
		end
	end

	function recover_or_die!(agent, model)
		# fine malattia
		if agent.days_infected > model.γ
			# probabilità di morte
			if rand(model.rng) ≤ model.δ
				remove_agent!(agent, model)
				return
			else
				# probabilità di guarigione
				agent.status = :R
				agent.days_immunity = model.ω
				agent.days_infected = 0
			end
		end
	end	

	function exit_quarantine!(agent, model)
		if agent.detected == :Q && agent.days_quarantined ≥ model.q 
			if result!(agent, model) == :S
				agent.days_quarantined = 0
				agent.detected = :R
			else 
				# prolungo la quarantena
				agent.days_quarantined ÷= 2
			end
		end
	end

	function collect(model, astep, mstep; n = 100)
        susceptible(x) = count(i == :S for i in x)
        exposed(x) = count(i == :E for i in x)
        infected(x) = count(i == :I for i in x)
        recovered(x) = count(i == :R for i in x)
        dead(x) = sum(model.number_point_of_interest) - length(x)

		quarantined(x) = count(i == :Q for i in x)
		happiness(x) = mean(x)

        to_collect = [(:status, susceptible), (:status, exposed), (:status, infected), 
			(:status, recovered), (:happiness, happiness), (:detected, infected), 
			(:detected, quarantined), (:detected, recovered), (:status, dead)]
        data, _ = run!(model, astep, mstep, n; adata = to_collect)
		data[!, :dead_status] = data[!, end]
    	select!(data, :susceptible_status, :exposed_status, :infected_status, :recovered_status, 
			:infected_detected, :quarantined_detected, :recovered_detected, :dead_status, :happiness_happiness)
        for i in 1:ncol(data)
            data[!, i] = data[!, i] / sum(model.number_point_of_interest)
        end
        return data
    end
end