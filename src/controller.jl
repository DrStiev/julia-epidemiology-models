module controller

using Agents, DataFrames, Random, Distributions, Distributed
using Statistics: mean

# https://github.com/epirecipes/sir-julia

include("utils.jl")

function save_dataframe(data::DataFrame, path::String, title="StandardABM")
    isdir(path) == false && mkpath(path)
    CSV.write(path * title * "_" * string(today()) * ".csv", data)
end

function controller_vaccine!(
    model::StandardABM,
    avg_effectiveness::Float64=0.83;
    time::Int=365
)
    if rand(model.rng) < 1 / time
        v =
            (1 - (1 / model.R₀ᵢ)) /
            rand(model.rng, Normal(avg_effectiveness, avg_effectiveness / 10))
        model.ξ = v / model.ω
        model.vaccine_coverage = model.all_variants
        model.variant_tolerance =
            round(Int, tanh(model.step_count / time * avg_effectiveness) * 1024)
    end
end

slope(pred) = tanh(pred[3, end] - pred[3, 1]) + tanh(pred[5, end] - pred[5, 1])

function get_node_status(model::StandardABM, pos::Int; mininfects::Int=1)
    agents = filter(x -> x.pos == pos, [a for a in allagents(model)])
    infects = filter(x -> x.status == :I, agents)
    if length(infects) > mininfects
        return length(infects) / length(agents)
    else
        return 0.0
    end
end

function apply_lockdown!(model::StandardABM, node::Int, restriction::Float64)
    model.new_migration_rate = model.migration_rate
    model.new_migration_rate[node, :] -= model.migration_rate[node, :] * restriction
    model.new_migration_rate[:, node] -= model.migration_rate[:, node] * restriction
    model.new_migration_rate[node, node] +=
        (1 - model.migration_rate[node, node]) * restriction
    model.new_migration_rate[model.new_migration_rate.<0.0] .= 0.0
    model.new_migration_rate[model.new_migration_rate.>1.0] .= 1.0
end


function controller_η!(
    model::StandardABM,
    data::Matrix,
    step::Int;
    mininfects::Int=1,
    vaccine::Bool=false,
    check_happiness::Bool=true
)

    rate = slope(data[:, (end-step)+1:end])
    for i = 1:length(model.η)
        if get_node_status(model, i; mininfects) > 0.0
            if rate > 0.0
                model.η[i] = rate ≥ model.η[i] ? rate : model.η[i]
                # TODO: aggiungere gestione lockdown e gestione riapertura
                # if rate > 0.2
                #     apply_lockdown!(model, i, rate)
                # end
            else
                model.η[i] *= (1.0 + rate)
            end
            if check_happiness
                controller_happiness!(model)
            end
        end
    end
end

function controller_happiness!(model::StandardABM)
    for i = 1:length(model.η)
        h = model.happiness[i]
        model.η[i] =
            h + model.η[i] < model.η[i] / 2 ? model.η[i] * (1 - (model.η[i] / abs(h))) :
            model.η[i]
    end
end

function controller_voc()
    # prova a predire quando uscira' la nuova variante
    # idea molto ambiziosa
end

function predict(model::StandardABM, tspan::Int; traindata_size::Int=30)
    data = select(model.outresults, [:susceptible, :exposed, :infected, :recovered, :dead])
    p_true = [model.R₀, model.γ, model.σ, model.ω, model.δ, model.η, model.ξ]
    l = length(data[:, 1])
    l == 0 && return nothing
    traindata_size = min(l, traindata_size)
    res = nothing
    try
        res = udePredict.ude_prediction(data[:, l-trainingdata_size+1:l], p_true, tspan)
    catch ex
        isdir("data/error/") == false && mkpath("data/error/")
        joinpath("data/error/", "log_" * string(today()) * ".txt")
        log = @error "prediction failed" exception = (ex, catch_backtrace())
        open("data/error/log_" * string(today()) * ".txt", "a") do io
            write(io, log)
        end
        AgentsIO.save_checkpoint("data/error/abm_checkpoint_" * string(today()) * ".jld2", model)
        save_dataframe(data, "data/error/", "abm_dataframe")
    finally
        if isnothing(res)
            return nothing
        elseif isnothing(res[3])
            return res[1]
        else
            return res[3]
        end
    end
end
end
