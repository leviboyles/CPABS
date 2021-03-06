include("tree.jl")
include("wang_landau.jl")

import Base.copy
import Base.ref
import Base.assign
import Base.serialize

type ModelState
    lambda::Float64
    gamma::Float64
    alpha::Float64

    rate_k::Float64

    tree::Tree{Vector{Float64}} # Tree state holds the \eta variables (one eta variable for each observed sample)
    Z::Vector{Int64} # Assignment of datapoints to nodes
    rates::Vector{Float64} # Mutation rate variables for each branch 
    WL_state::WangLandauState
end

function copy(model::ModelState)
    ModelState(model.lambda, model.gamma, model.alpha, model.rate_k, copy(model.tree), copy(model.Z), copy(model.rates), copy(model.WL_state))
end

function serialize(stream::SerializationState, model::ModelState)
    serialize(stream, (model.lambda, model.gamma, model.alpha, model.rate_k )) 
    serialize(stream, model.tree)
    serialize(stream, model.Z)
    serialize(stream, model.rates)
    serialize(stream, model.WL_state)
end

function serialize(stream::SerializationState, models::Vector{ModelState})
    N = length(models)

    serialize(stream, N)
    for i = 1:N
        serialize(stream, models[i])
    end

end

function deserializeModel(stream::SerializationState)
    (lambda, gamma, alpha, rate_k) = deserialize(stream)
    tree = deserializeTree(stream)
    Z = deserialize(stream)
    rates = deserialize(stream)
    WL_state = deserialize(stream)

    ModelState(lambda, gamma, alpha, rate_k, tree, Z, rates, WL_state)
end

function deserializeModels(stream::SerializationState)
    N = deserialize(stream)
    models = Array(ModelState, N)

    for i = 1:N
        models[i] = deserializeModel(stream)
    end

    models
end

function loadModels(filename)
    f = open(filename)
    models = deserializeModels(f)
    close(f)
    models
end


type ModelSpecification
    latent_rates::Bool # do we use the latent rate variables model.rates

    rrj_jump_probabilities::Array{Float64} #assumes L \in {k-1,k,k+1}

    debug::Bool
    verbose::Bool
    plot::Bool

end

copy(ms::ModelSpecification) = ModelSpecification(ms.latent_rates, ms.rrj_jump_probabilities, ms.debug,
                                                  ms.verbose, ms.plot)

type DataState
    reference_counts::Matrix{Float64}
    total_counts::Matrix{Float64}
    mu_r::Vector{Float64}
    mu_v::Vector{Float64}

    paired_reads::Matrix{Float64} # Nx9 matrix, each row is (index_A, index_B, phasing, sample_index, errorRate, var0Reads, varAReads, varBReads, varABReads) 
                                  # where phasing is probability that the mutations are co-phased (ie 1/2 for no information)
                                  # and read indicates whether the mutation is present  

    mutation_names::Vector{ASCIIString}
end

# Find ancestor to whose population t belongs
# As we assume the right children are the "new" subpopulations,
# tau will be the most recent ancestor such that the path from tau to
# t contains tau's right child
function tau(t::TreeNode)
    @assert t != Nil()
    p = t.parent
    if p == Nil()
        return p
    end

    c = t 
    while p.children[1] != c
        c = p
        p = p.parent

        if p == Nil()
            return p
        end
    end 

    return p
end

# Like tau, but returns the full path from t to tau(t)
function tau_path(t::TreeNode)
    @assert t != Nil()
    path = Array(Node,0)
    p = t.parent
    if p == Nil()
        push!(path,t)
        return path
    end

    c = t
    push!(path,t) 
    while p.children[1] != c
        push!(path,p)
        c = p

        p = p.parent
        if p == Nil()
            return path
        end
    end 

    return path

end

function compute_times(model::ModelState)
    tree = model.tree
    gam = model.gamma
    root = FindRoot(tree, 1)
    indices = GetLeafToRootOrdering(tree, root.index)

    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2

    t = ones(2N-1)

    for i = reverse(indices)
        cur = tree.nodes[i]
        parent = cur.parent    

        if i != root.index
            self_direction = find(parent.children .== cur)[1]
            cur_mu_prop = self_direction == 1 ? parent.rho : 1-parent.rho
            t[i] = t[parent.index]*(cur.rhot*cur_mu_prop)^gam

        else
            t[i] = cur.rhot^gam
        end

    end

    return t
end

function compute_taus(model::ModelState)
    tree = model.tree

    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2

    Tau = zeros(Int64, 2N-1)
    root = FindRoot(tree, 1)
    indices = GetLeafToRootOrdering(tree, root.index)

    for i = reverse(indices)
        cur = tree.nodes[i]
        if i == root.index
            Tau[i] = 0
        end

        if i > N
            l = cur.children[2].index
            r = cur.children[1].index

            Tau[l] = Tau[i]
            Tau[r] = i 
        end 
    end

    return Tau
end

function compute_phis(model::ModelState)
    tree = model.tree

    S = length(tree.nodes[end].state)
    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2

    B = zeros(2N-1,S)
    root = FindRoot(tree, 1)
    indices = GetLeafToRootOrdering(tree, root.index)

    for i = reverse(indices)
        if i > N
            cur = tree.nodes[i]
            parent = cur.parent    

            if i != root.index
                self_direction = find(parent.children .== cur)[1]

                for s = 1:S
                    # the eta variable held by a node is the eta for the right child
                    eta_self = self_direction == 1 ? parent.state[s] : (1 - parent.state[s])
                    B[i,s] = B[parent.index,s]*eta_self
                end
            else
                B[i,:] = 1.0
            end
        end
    end

    for i = indices
        if i > N
            cur = tree.nodes[i]
            for s = 1:S
                B[i,s] .*= cur.state[s]
            end
        end
    end

    return B
end

function compute_dphi_deta(model::ModelState)
    tree = model.tree

    S = length(tree.nodes[end].state)
    _2Nm1 = length(tree.nodes)
    N::Int = (_2Nm1+1)/2

    B = zeros(2N-1,S)

    dphi_deta = zeros(2N-1, S, N-1, S)

    root = FindRoot(tree, 1)
    indices = GetLeafToRootOrdering(tree, root.index)

    for i = reverse(indices)
        if i > N
            cur = tree.nodes[i]
            parent = cur.parent    

            if i != root.index
                self_direction = find(parent.children .== cur)[1]

                for s = 1:S
                    # the eta variable held by a node is the eta for the right child
                    eta_self = self_direction == 1 ? parent.state[s] : (1 - parent.state[s])

                    B[i,s] = B[parent.index,s]*eta_self
                end
            else
                B[i,:] = 1.0
            end
        end
    end

    for i = indices
        if i > N
            cur = tree.nodes[i]
            for s = 1:S
                B[i,s] .*= cur.state[s]
            end
        end
    end


    for i = reverse(indices)
        cur = tree.nodes[i]
        parent = cur.parent    

        if i != root.index
            self_direction = find(parent.children .== cur)[1]
            for s = 1:S
                is_right = self_direction == 1
                eta_self = is_right ? parent.state[s] : (1 - parent.state[s])

                ancestors = GetAncestors(model.tree, i)

                for anc = ancestors
                    j = anc.index
                    for t = 1:S
                        d_eta = B[j, t] / eta_self
                        dphi_deta[j,t, parent.index-N,s] += is_right ? d_eta : -d_eta
                    end
                end
            end

        end
    end 

    for i = indices

        if i > N
            cur = tree.nodes[i]
            for s = 1:S
                ancestors = GetAncestors(model.tree, i)
                for anc = ancestors
                    j = anc.index
                    for t = 1:S
                        dphi_deta[j,t, i-N,s] = B[j, t] / cur.state[s]

                    end

                end
            end
        end
    end
    return dphi_deta
end

function model2array(model::ModelState; return_leaf_times::Bool=false)
    tree2array(model.tree, model.gamma, return_leaf_times=return_leaf_times)
end

function model2dict(model::ModelState, wl_state::WangLandauState, log_likelihood::Float64, log_pdf::Float64, mutation_names::Vector{ASCIIString})
    dict = Dict{ASCIIString, Any}()
    dict["llh"] = log_likelihood

    N::Int = (length(model.tree.nodes)+1)/2
    log_weight = get_partition_function(wl_state, N, log_pdf)
    dict["log_weight"] = log_weight


    T = GetAdjacencyMatrix(model.tree)
    phis = compute_phis(model)
    perm = reverse(sortperm(sum(phis[N+1:end,:],2)[:]))
    perm_phis = phis[N+1:end,:][perm,:]
    perm_T = T[perm,perm]

    structure = Dict{ASCIIString, Any}()
    for i = 1:size(T,1)
        if length(find(perm_T[i,:])) > 0
            structure["$i"] = find(perm_T[i,:])
        end
    end
    dict["structure"] = structure

    Z = model.Z
    C = [Int64[] for x = 1:maximum(Z)]
    for i = 1:length(Z)
        push!(C[perm[Z[i]-N]], i)
    end

    populations = Dict{ASCIIString, Any}()
    mutation_assignments = Dict{ASCIIString, Any}()
    for i = 1:size(T,1)
        d = Dict{ASCIIString, Any}()
        d["num_ssms"] = length(C[i])
        d["num_cnvs"] = 0
        d["cellular_prevalence"] = perm_phis[i,:][:]
 
        populations["$i"] = d

        m = Dict{ASCIIString, Any}()
        names = [mutation_names[c] for c in C[i]]
        m["ssms"] = names
        m["cnvs"] = ASCIIString[]
        
        mutation_assignments["$i"] = m
    end
    dict["populations"] = populations

   

    dict, mutation_assignments
end
