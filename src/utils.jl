module dataset
using CSV, DataFrames, Downloads

function download_dataset(path::String, url::String)
    # https://github.com/owid/covid-19-data/tree/master/public/data/
    title = split(url, "/")
    isdir(path) == false && mkpath(path)
    return DataFrame(
        CSV.File(
            Downloads.download(url, path * title[length(title)]),
            delim=",",
            header=1,
        ),
    )
end

function dataset_from_location(df::DataFrame, iso_code::String)
    df = filter(:iso_code => ==(iso_code), df)
    df[!, :total_susceptible] = df[!, :population] - df[!, :total_cases]
    return select(df, [:date]),
    select(
        df,
        [
            :new_cases_smoothed,
            :new_tests_smoothed,
            :new_vaccinations_smoothed,
            :new_deaths_smoothed,
        ],
    ),
    select(df, [:total_susceptible, :total_cases, :total_deaths, :total_tests]),
    select(df, [:reproduction_rate])
end

function read_dataset(path::String)
    return DataFrame(CSV.File(path, delim=",", header=1))
end
end

module parameters
using JLD2, FileIO, Dates
using Random, Distributions, DataFrames
using LinearAlgebra: diagind
using DrWatson: @dict

function get_abm_parameters(C::Int, max_travel_rate::Float64, avg=1000; seed=1337)
    pop = randexp(Xoshiro(seed), C) * avg
    number_point_of_interest = map((x) -> round(Int, x), pop)
    migration_rate = zeros(C, C)
    for c = 1:C
        for c2 = 1:C
            migration_rate[c, c2] =
                (number_point_of_interest[c] + number_point_of_interest[c2]) /
                number_point_of_interest[c]
        end
    end
    maxM = maximum(migration_rate)
    migration_rate = (migration_rate .* max_travel_rate) ./ maxM
    migration_rate[diagind(migration_rate)] .= 1.0

    γ = 14 # infective period
    σ = 5 # exposed period
    ω = 280 # immunity period
    ξ = 0.0 # vaccine ratio
    # https://www.nature.com/articles/s41467-021-22944-0
    δ = 0.007
    R₀ = 3.54

    return @dict(number_point_of_interest, migration_rate, R₀, γ, σ, ω, ξ, δ, Rᵢ = 0.99,)
end

function get_ode_parameters(C::Int, avg=1000; seed=1337)
    pop = randexp(Xoshiro(seed), C) * avg
    number_point_of_interest = map((x) -> round(Int, x), pop)
    γ = 14 # infective period
    σ = 5 # exposed period
    ω = 280 # immunity period
    δ = 0.007
    R₀ = 3.54
    S = (sum(number_point_of_interest) - 1) / sum(number_point_of_interest)
    E = 0
    I = 1 / sum(number_point_of_interest)
    R = 0
    D = 0
    tspan = (1, 1200)
    return [S, E, I, R, D], [R₀, 1 / γ, 1 / σ, 1 / ω, δ], tspan
end

function save_parameters(params, path, title="parameters")
    isdir(path) == false && mkpath(path)
    save(path * title * ".jld2", params)
end

load_parameters(path) = load(path)
end

module SysId
using OrdinaryDiffEq, DataDrivenDiffEq, ModelingToolkit
using Random, DataDrivenSparse, LinearAlgebra, DataFrames, Plots

# works but have wonky behaviour
function system_identification(
    data::DataFrame;
    # opt=ADMM,
    # λ=exp10.(-3:0.01:3),
    opt=STLSQ,
    λ=exp10.(-5:0.1:-1),
    maxiters=10_000,
    seed=1234,
    saveplot=false,
    title="title"
)
    # handle the input in a correct way to avoid wonky behaviours
    s = sum(data[1, :]) # total number of individuals
    X = DataFrame(float.(Array(data)'), :auto) ./ s # normalize and obtain numerical stability
    t = float.([i for i = 1:size(X, 2)])

    # generate the datadriven problem
    ddprob = ContinuousDataDrivenProblem(Array(X), t)

    # generate the variable and the basis
    @variables t (u(t))[1:(size(X, 1))]
    b = []
    for i = 1:size(X, 1)
        push!(b, u[i])
    end
    basis = Basis(polynomial_basis(b, size(X, 1)), u, iv=t) # construct a Basis

    # use SINDy to inference the system. Could use EDMD but
    # for noisy data SINDy is stabler and find simpler (sparser)
    # solution. However, large amounts of noise can break SINDy too.
    opt = opt(λ) # define the optimization algorithm

    options = DataDrivenCommonOptions(
        maxiters=maxiters,
        normalize=DataNormalization(ZScoreTransform),
        selector=bic,
        digits=1,
        data_processing=DataProcessing(
            split=0.9,
            batchsize=30,
            shuffle=true,
            rng=Xoshiro(seed),
        ),
    )

    # ERROR: DimensionMismatch: arrays could not be broadcast to a common size;
    # ERROR:LinearAlgebra.SingularException if data has more than 30 rows
    ddsol = solve(ddprob, basis, opt, options=options, verbose=false)
    # return the information about the inferred model and parameters
    sys = get_basis(ddsol)
    # sys = structural_simplify(sys)
    # display(sys)
    if saveplot
        p = plot(plot(ddprob), plot(ddsol))
        save_plot(p, "img/system_identification/", title, "pdf")
    end
    return sys
end
end

module udePredict

using OrdinaryDiffEq, ModelingToolkit, DataDrivenDiffEq, SciMLSensitivity, DataDrivenSparse
using Optimization, OptimizationOptimisers, OptimizationOptimJL, CUDA

# Standard Libraries
using LinearAlgebra, Statistics

# External Libraries
using ComponentArrays, Lux, Zygote, StableRNGs, DataFrames, Dates, Plots

function ude_prediction(
    data::DataFrame,
    p_true::Array{Float64},
    timeshift::Int;
    seed=1234,
    plotLoss=false,
    maxiters=5000,
    activation_function=tanh,
    lossTitle="loss"
)
    X = Array(data)'
    tspan = float.([i for i = 1:size(Array(data), 1)])
    timeshift = float.([i for i = 1:timeshift])
    # Normalize the data if not between [0-1]
    if (any(X .<= 0) || any(X .>= 1))
        X = X ./ sum(data[1, :])
    end

    s = size(X, 1)

    # Multilayer FeedForward
    U = Lux.Chain(
        Lux.Dense(s, s^2, activation_function),
        Lux.Dense(s^2, s^2, activation_function),
        Lux.Dense(s^2, s^2, activation_function),
        Lux.Dense(s^2, s),
    )
    # Get the initial parameters and state variables of the model
    p, st = Lux.setup(StableRNG(seed), U)

    function ude_dynamics!(du, u, p, t, p_true)
        û = U(u, p, st)[1] # network prediction
        S, E, I, R, D = u
        R₀, γ, σ, ω, δ, η, ξ = p_true
        du[1] = ((-R₀ * γ * (1 - η) * S * I) + (ω * R) - (S * ξ)) * û[1] # dS
        du[2] = ((R₀ * γ * (1 - η) * S * I) - (σ * E)) * û[2] # dE
        du[3] = ((σ * E) - (γ * I) - (δ * I)) * û[3] # dI
        du[4] = (((1 - δ) * γ * I - ω * R) + (S * ξ)) * û[4] # dR
        du[5] = ((δ * I * γ)) * û[5] # dD
    end

    # Closure with the known parameter
    nn_dynamics!(du, u, p, t) = ude_dynamics!(du, u, p, t, p_true)
    # Define the problem
    prob_nn = ODEProblem(nn_dynamics!, X[:, 1], (tspan[1], tspan[end]), p)

    function predict(θ, X=X[:, 1], T=tspan)
        _prob = remake(prob_nn, u0=X, tspan=(T[1], T[end]), p=θ)
        Array(
            solve(
                _prob,
                Vern7(; thread=OrdinaryDiffEq.True()),
                saveat=T,
                abstol=1e-6,
                reltol=1e-6,
                verbose=false,
            ),
        )
    end

    function loss(θ)
        X̂ = predict(θ)
        mean(abs2, X .- X̂)
    end

    losses = Float64[]
    callback = function (p, l)
        push!(losses, l)
        if length(losses) % 50 == 0
            println("Current loss after $(length(losses)) iterations: $(losses[end])")
        end
        return false
    end

    adtype = Optimization.AutoZygote()
    optf = Optimization.OptimizationFunction((x, p) -> loss(x), adtype)
    optprob = Optimization.OptimizationProblem(optf, ComponentVector{Float64}(p))

    iterations = round(Int, maxiters / 2)
    res1 = Optimization.solve(optprob, ADAM(), callback=callback, maxiters=iterations)
    optprob2 = Optimization.OptimizationProblem(optf, res1.u)
    res2 = Optimization.solve(
        optprob2,
        Optim.LBFGS(),
        callback=callback,
        maxiters=iterations,
    )

    # plot the loss
    if plotLoss
        function save_plot(plot, path="", title="title", format="png")
            isdir(path) == false && mkpath(path)
            savefig(plot, path * title * "_" * string(today()) * "." * format)
        end

        # Plot the losses
        pl_losses = plot(
            1:iterations,
            losses[1:iterations],
            yaxis=:log10,
            xaxis=:log10,
            xlabel="Iterations",
            ylabel="Loss",
            label="ADAM",
            color=:blue,
        )
        plot!(
            iterations+1:length(losses),
            losses[iterations+1:end],
            yaxis=:log10,
            xaxis=:log10,
            xlabel="Iterations",
            ylabel="Loss",
            label="LBFGS",
            color=:red,
        )

        save_plot(pl_losses, "img/prediction/", lossTitle, "pdf")
    end

    # Rename the best candidate
    p_trained = res2.u

    ts = first(timeshift):(mean(diff(timeshift))):last(timeshift)
    X̂ = predict(p_trained, X[:, 1], ts)
    # Neural network guess
    Ŷ = U(X̂, p_trained, st)[1]
    # prediction over time
    return (X̂, Ŷ)
    # return symbolic_regression(X̂, Ŷ, p_true, timeshift), (X̂, Ŷ)
end

# I'd like to use both but this seems to not work properly
function symbolic_regression(
    X̂,
    Ŷ,
    p_true::Vector{Float64},
    timeshift::Int;
    opt=ADMM,
    λ=exp10.(-3:0.01:3),
    maxiters=10_000,
    seed=1234
)

    tspan = (1.0, float(timeshift))
    u0 = X̂[:, 1]
    # Symbolic regression via sparse regression (SINDy based)
    nn_problem = DirectDataDrivenProblem(X̂, Ŷ)
    opt = opt(λ)
    @variables u[1:size(X̂, 1)]
    b = polynomial_basis(u, size(X̂, 1))
    basis = Basis(b, u)

    options = DataDrivenCommonOptions(
        maxiters=maxiters,
        normalize=DataNormalization(ZScoreTransform),
        selector=bic,
        digits=1,
        data_processing=DataProcessing(
            split=0.9,
            batchsize=30,
            shuffle=true,
            rng=StableRNG(seed),
        ),
    )

    # ERROR: DimensionMismatch: arrays could not be broadcast to a common size;
    nn_res = solve(nn_problem, basis, opt, options=options)
    nn_eqs = get_basis(nn_res)

    function recovered_dynamics!(du, u, p, t, p_true)
        û = nn_eqs(u, p) # network prediction
        S, E, I, R, D = u
        R₀, γ, σ, ω, δ, η, ξ = p_true
        du[1] = ((-R₀ * γ * (1 - η) * S * I) + (ω * R) - (S * ξ)) * û[1] # dS
        du[2] = ((R₀ * γ * (1 - η) * S * I) - (σ * E)) * û[2] # dE
        du[3] = ((σ * E) - (γ * I) - (δ * I)) * û[3] # dI
        du[4] = (((1 - δ) * γ * I - ω * R) + (S * ξ)) * û[4] # dR
        du[5] = ((δ * I * γ)) * û[5] # dD
    end

    dynamics!(du, u, p, t) = recovered_dynamics!(du, u, p, t, p_true)
    estimation_prob =
        ODEProblem(dynamics!, u0, tspan, get_parameter_values(nn_eqs))
    # ERROR: TypeError: non-boolean (Symbolics.Num) used in boolean context
    estimate = solve(estimation_prob, Tsit5(; thread=OrdinaryDiffEq.True()), saveat=1.0)

    function parameter_loss(p)
        Y = reduce(hcat, map(Base.Fix2(nn_eqs, p), eachcol(X̂)))
        sum(abs2, Ŷ .- Y)
    end

    losses = Float64[]
    callback = function (p, l)
        push!(losses, l)
        if length(losses) % 50 == 0
            println("Current loss after $(length(losses)) iterations: $(losses[end])")
        end
        return false
    end

    adtype = Optimization.AutoZygote()
    optf = Optimization.OptimizationFunction((x, p) -> parameter_loss(x), adtype)
    optprob = Optimization.OptimizationProblem(optf, get_parameter_values(nn_eqs))
    parameter_res =
        Optimization.solve(
            optprob,
            Optim.LBFGS(),
            callback=callback,
            maxiters=trunc(Int, maxiters / 10)
        )

    # Look at long term prediction
    estimation_prob = ODEProblem(dynamics!, u0, tspan, parameter_res)
    # ERROR: TypeError: non-boolean (Symbolics.Num) used in boolean context
    estimate_long =
        solve(estimation_prob, Tsit5(; thread=OrdinaryDiffEq.True()), saveat=1.0) # Using higher tolerances here results in exit of julia
    return estimate_long
end
end
