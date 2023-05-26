module test_parameters
using DataFrames
include("params.jl")

model_params.download_dataset(
    "data/OWID/",
    "https://covid.ourworldindata.org/data/owid-covid-data.csv",
)
df = model_params.read_local_dataset("data/OWID/owid-covid-data.csv")
date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

# LinearAlgebra.SingularException(3)
@time sys, params = model_params.system_identification(
    float.(Array(day_info))',
    float.((1:length(day_info[!, 1]))),
)

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

p = plot(
    plot(
        Array(day_info),
        labels = ["Infected" "Tests" "Vaccinations" "Deaths"],
        title = "Detected Dynamics",
    ),
    plot(
        Array(total_count),
        labels = ["Susceptible" "Infected" "Deaths" "Tests"],
        title = "Overall Dynamics",
    ),
    plot(Array(R₀), labels = "R₀", title = "Reproduction Rate"),
)

pplot.save_plot(p, "img/data_plot/", "cumulative_plot", "pdf")
end

module test_abm
using Agents, DataFrames, Plots, Distributions, Random
using Statistics: mean

include("params.jl")
include("pplot.jl")
include("graph.jl")

df = model_params.read_local_dataset("data/OWID/owid-covid-data.csv")
date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

abm_parameters = model_params.get_abm_parameters(20, 0.01, 3300)
model = graph.init(; abm_parameters...)

data = graph.collect(model; n = 30, controller_step = 7)
data = graph.collect(model; n = length(date[!, 1]) - 1)

p1 = select(
    data,
    [:susceptible_status, :exposed_status, :infected_status, :recovered_status, :dead],
)
p2 = select(data, [:active_countermeasures])
p3 = select(data, [:happiness_happiness])
p4 = select(data, [:R₀])

p = plot(
    plot(
        Array(p1),
        labels = ["Susceptible" "Exposed" "Infected" "Recovered" "Dead"],
        title = "ABM Full Dynamics",
    ),
    plot(Array(p2), labels = "η", title = "Countermeasures strickness"),
    plot(Array(p3), labels = "Happiness", title = "Cumulative Happiness"),
    plot(Array(p4), labels = "R₀", title = "Reproduction number"),
)
pplot.save_plot(p, "img/abm/", "cumulative_plot", "pdf")

# sys, params = model_params.system_identification(Array(p1)', (1:length(p1[!,1])))

# TODO: SISTEMAMI
# model = graph.init(; abm_parameters...)
# pplot.custom_video(
#     model,
#     graph.agent_step!,
#     graph.model_step!;
#     title="graph_abm",
#     path="img/video/",
#     format=".mp4",
#     frames=length(date[!, 1]) - 1
# )
end

module test_uode
using Plots, DataFrames, Random, Distributions
include("uode.jl")
include("params.jl")
include("pplot.jl")

# must be between [0-1] otherwise strange behaviour
u, p, t = model_params.get_ode_parameters()
prob = uode.get_ode_problem(uode.seir!, u, t, p)
sol = uode.get_ode_solution(prob)

p = plot(
    sol,
    labels = ["Susceptible" "Exposed" "Infected" "Recovered" "Dead"],
    title = "SEIR Dynamics",
)
pplot.save_plot(p, "img/ode/", "cumulative_plot", "pdf")

# LinearAlgebra.SingularException(3)
# sys, params = model_params.system_identification(Array(sol), sol.t)
end

module test_controller
# https://link.springer.com/article/10.1007/s40313-023-00993-8
using Agents, DataFrames, Plots, Distributions, Random
using Statistics: mean

include("params.jl")
include("pplot.jl")
include("graph.jl")
include("controller.jl")

df = model_params.read_local_dataset("data/OWID/owid-covid-data.csv")
date, day_info, total_count, R₀ = model_params.dataset_from_location(df, "ITA")

abm_parameters = model_params.get_abm_parameters(20, 0.001, 3300)
@time model = graph.init(; abm_parameters...)

data = graph.collect(model, graph.agent_step!, graph.model_step!; n = 30)
select(data, [:infected_detected, :controls])
model.step_count
model.properties

end

module to_be_implemented
# creo una matrice di spostamento tra i vari nodi
# creo un grafo come Graph(M+M')
end
