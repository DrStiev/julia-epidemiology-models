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
    return select(df, [:date]), select(
        df,
        [
            :new_cases_smoothed,
            :new_tests_smoothed,
            :new_vaccinations_smoothed,
            :new_deaths_smoothed,
        ],
    ), select(df, [:total_susceptible, :total_cases, :total_deaths, :total_tests]),
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
    η = 1.0 / 1000 # Countermeasures speed
    R₀ = 3.54

    return @dict(number_point_of_interest, migration_rate, R₀, γ, σ, ω, ξ, δ, η, Rᵢ = 0.99,)
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
using Random, DataDrivenSparse

function SIR_id(data::Core.AbstractArray, ts::Core.AbstractArray; seed=1337)
    prob = ContinuousDataDrivenProblem(float.(data), float.(ts), GaussianKernel())
    println(prob)

    @variables t s(t) i(t) r(t)
    u = [s; i; r]
    Ψ = Basis(polynomial_basis(u, 5), u, iv=t)
    println(Ψ)

    # use SINDy to inference the system. Could use EDMD but 
    # for noisy data SINDy is stabler and find simpler (sparser)
    # solution. However, large amounts of noise can break SINDy too.
    opt = STLSQ(exp10.(-5:0.1:1))
    res = solve(prob, Ψ, opt, options=DataDrivenCommonOptions(digits=1))
    println(get_basis(res))
    system = result(res)
    return equations(system), parameter_map(system)
end
end