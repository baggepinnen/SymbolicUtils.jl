using Metatheory.Rewriters

function EGraphs.preprocess(t::Symbolic)
    toterm(unflatten(t)) 
end

function symbolicegraph()
    g = EGraph()
    analyze!(g, SymbolicUtils.SymtypeAnalysis)
    settermtype!(g, Term{Number})
    return g
end


function symbolicegraph(ex)
    g = EGraph(ex)
    analyze!(g, SymbolicUtils.SymtypeAnalysis)
    settermtype!(g, Term{symtype(ex)})
    return g
end


"""
Equational rewrite rules for optimizing expressions
"""
opt_theory = @theory a b x y  begin
    a + b == b + a
    a * b == b * a
    a * x + a * y == a*(x+y)
    -1 * a == -a
    a + (-1 * b) == a - b
    x^-1 == 1/x 
    1/x * a == a/x
    # fraction rules 
    # (a/b) + (c/b) => (a+c)/b
    # trig functions
    sin(x)/cos(x) == tan(x)
    cos(x)/sin(x) == cot(x)
    sin(x)^2 + cos(x)^2 --> 1
    sin(2a) == 2sin(a)cos(a)
end


"""
Approximation of costs of operators in number 
of CPU cycles required for the numerical computation

See 
 * https://latkin.org/blog/2014/11/09/a-simple-benchmark-of-various-math-operations/
 * https://streamhpc.com/blog/2012-07-16/how-expensive-is-an-operation-on-a-cpu/
 * https://github.com/triscale-innov/GFlops.jl
"""
const op_costs = Dict(
    (+)     => 1,
    (-)     => 1,
    abs     => 2,
    (*)     => 3,
    exp     => 18,
    (/)     => 24,
    (^)     => 100,
    log1p   => 124,
    deg2rad => 125,
    rad2deg => 125,
    acos    => 127,
    asind   => 128,
    acsch   => 133,
    sin     => 134,
    cos     => 134,
    atan    => 135,
    tan     => 156,
)
# TODO some operator costs are in FLOP and not in cycles!!

function costfun(n::ENodeTerm, g::EGraph, an)
    op = operation(n)
    cost = 0
    cost += get(op_costs, op, 1)

    for id ∈ n.args
        eclass = g[id]
        !hasdata(eclass, an) && (cost += Inf; break)
        cost += last(getdata(eclass, an))
    end
    cost
end

costfun(n::ENodeLiteral, g::EGraph, an) = 0

egraph_simterm(x, head, args, symtype=nothing; metadata=nothing, exprhead=exprhead(x)) = 
TermInterface.similarterm(typeof(x), head, args, symtype; metadata=metadata, exprhead=exprhead)


# Custom similarterm to use in EGraphs on <:Symbolic types that treats everything as a Term 
function egraph_simterm(x::Type{<:Term}, f, args, symtype=nothing; metadata=nothing, exprhead=:call)
    T = symtype
    if T === nothing
        T = _promote_symtype(f, args)
    end
    res = Term{T}(f isa Symbol ? eval(f) : f, args; metadata=metadata);
    return res
end 

default_opt_params = SaturationParams(
    timeout=15, 
    printiter=true,
    eclasslimit=300_000,
    matchlimit=50_000
)

function optimize(ex; params=default_opt_params)
    # @show ex
    g = symbolicegraph(ex)
    params.simterm = egraph_simterm
    report = saturate!(g, opt_theory, params)
    # @info report
    return extract!(g, costfun; simterm=egraph_simterm)
end

function optimize(exs::AbstractArray; params=default_opt_params, batchsize=Inf)
    # @show ex
    # params.eclasslimit=
    # println("optimizing $(length(exs))")
    # println.(exs)

    if length(exs) > batchsize
        # println("batch size $batchsize")
        batches = collect(Iterators.partition(exs, batchsize))
        # println("$(length(batches)) batches")
        v = Vector(undef, length(batches))
        l = ReentrantLock()

        println(Threads.nthreads())

        Threads.@threads for i in 1:length(batches)
            batch = batches[i]
            opt_b = optimize_many(batch; params)
            lock(l) do 
                v[i] = opt_b
            end
        end

        return Iterators.flatten(v)
    end

    g = symbolicegraph()
    ids = map(exs) do ex
        ec, _ = addexpr!(g, ex)
        return ec.id
    end

    params.simterm = egraph_simterm
    report = saturate!(g, opt_theory, params)
    # @info report
    res = map(ids) do id
        extract!(g, costfun; root=id, simterm=egraph_simterm)
    end
    # println.(res)
    return res
end

Base.map(::typeof(SymbolicUtils.optimize), x::AbstractArray) = optimize(exs)


function getcost(ex)
    !istree(typeof(ex)) && return 1
    return get(SymbolicUtils.op_costs, operation(ex), 1) + mapreduce(getcost, (+), arguments(ex))
end
