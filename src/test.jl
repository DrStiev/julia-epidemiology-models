using Pkg
Pkg.activate(".")
Pkg.instantiate()
# Pkg.precompile()
# Pkg.resolve()

@time include("params.jl") # ottengo i parametri che passo al modello
@time include("graph.jl") # creo il modello ad agente
@time include("ode.jl") # creo un modello ode che fa da supporto al modello ad agente 
@time include("optimizer.jl") # trovo i parametri piu' adatti al modello cercando di minimizzare specifici parametri
@time include("controller.jl") # applico tecniche di ML per addestrare un modello e estrapolare policy di gestione

# test parameters creation
@time u0, tspan, p = model_params.ode_dummyparams()
@time params = model_params.dummyparams()

# test ODE solver
@time prob = ode.get_ODE_problem(ode.SEIRS!, u0, tspan, p)
@time sol = ode.get_solution(prob)
@time ode.line_plot(sol)

# FIXME test ABM model
@time model = graph.model_init(; params...)
@time data = graph.collect(model)
@time graph.line_plot(data)