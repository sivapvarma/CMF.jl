import JLD
import HDF5

ALGORITHMS = Dict(
    :mult => MULT,
    :hals => HALS,
    :anls => ANLS,
    :sep => Separable,
)

"""Holds results from a single CNMF fit."""
struct CNMF_results
    data::AbstractMatrix
    W::AbstractTensor
    H::AbstractMatrix
    time_hist::AbstractVector
    loss_hist::AbstractVector
    l1_H::AbstractFloat
    l2_H::AbstractFloat
    l1_W::AbstractFloat
    l2_W::AbstractFloat
    alg::Symbol
end


"""Returns width of each motif."""
num_lags(r::CNMF_results) = size(r.W, 1)

"""Returns the number of measured time series."""
num_units(r::CNMF_results) = size(r.W, 2)

"""Returns number of model motifs."""
num_components(r::CNMF_results) = size(r.W, 3)

"""Returns number of iterations performed."""
num_iter(r::CNMF_results) = length(loss_hist)

"""Sorts units to reveal sequences."""
function sortperm(r::CNMF_results)
    W_norm = zeros(size(r.W))
    for k in 1:size(r.W, 3)
        W_norm[:, :, k] = r.W[:, :, k] / norm(r.W[:, :, k])
    end

    # For each unit, compute the largest weight across
    # components.
    sum_over_lags = dropdims(sum(W_norm, dims=1), dims=1)
    rows = [view(sum_over_lags, i, :) for i in axes(sum_over_lags, 1)]
    max_component = argmax.(rows)

    # For each unit, compute the largest weight across
    # lags (within largest component).
    max_lag = Int64[]
    for (n, c) in enumerate(max_component)
        push!(max_lag, argmax(W_norm[:, n, c]))
    end

    # Lexographically sort units.
    return sortperm(
        [CartesianIndex(i, j) for (i, j) in zip(max_lag, max_component)])
end


function fit_cnmf(
    data::AbstractMatrix;
    L::Integer=10,
    K::Integer=5,
    alg::Symbol=:mult,
    max_itr::Real=100,
    max_time::Real=Inf,
    l1_H::Real=0,
    l2_H::Real=0,
    l1_W::Real=0,
    l2_W::Real=0,
    check_convergence::Bool=false,
    tol::Real=1e-4,
    patience::Real=3,
    kwargs...
)
    seed = get(kwargs, :seed, nothing)
    if (seed != nothing)
        Random.seed!(seed)
    end

    # Initialize
    W, H = init_rand(data, L, K)
    W = deepcopy(get(kwargs, :initW, W))
    H = deepcopy(get(kwargs, :initH, H))

    meta = nothing

    # Set up optimization tracking
    loss_hist = [compute_loss(data, W, H)]
    time_hist = [0.0]

    # Use separable algorithm if applicable
    sep_init = get(kwargs, :sep_init, false)
    if (alg == :sep || sep_init)
        t0 = time()
        W, H = ALGORITHMS[:sep].fit(data, K, L; kwargs...)
        dur = time() - t0
    end

    if (alg == :sep)
        push!(time_hist, time_hist[end] + dur)
        push!(loss_hist, compute_loss(data, W, H))
        max_itr = 0
    elseif (sep_init)
        loss_hist = [compute_loss(data, W, H)]
    end

    # Update
    itr = 1
    while (itr <= max_itr) && (time_hist[end] <= max_time)
        itr += 1

        # Update with timing
        t0 = time()
        if alg == :anls
            (l1_H == 0 &&
             l2_H == 0 &&
             l1_W == 0 &&
             l2_W == 0) || error("Regularization not supported with ANLS")
        end

        loss, meta = ALGORITHMS[alg].update!(data, W, H, meta;
                                             l1_H=l1_H, l2_H=l2_H, l1_W=l1_W, l2_W=l2_W,
                                             kwargs...)
        dur = time() - t0

        # Record time and loss
        push!(time_hist, time_hist[end] + dur)
        push!(loss_hist, loss)

        # Check convergence
        if check_convergence && converged(loss_hist, patience, tol)
            break
        end
    end

    return CNMF_results(data, W, H, time_hist, loss_hist,
                        l1_H, l2_H, l1_W, l2_W, alg)
end


"""
Check for model convergence
"""
function converged(loss_hist::AbstractVector, patience::Real, tol::Real)

    # If we have not run for `patience` iterations,
    # we have not converged.
    if length(loss_hist) <= patience
        return false
    end

    d_loss = diff(loss_hist[end-patience:end])

    # Objective converged
    if (all(abs.(d_loss) .< tol))
        return true
    else
        return false
    end
end


"""
Initialize randomly, scaling to minimize square error.
"""
function init_rand(data::AbstractMatrix, L::Integer, K::Integer)
    N, T = size(data)

    W = rand(L, N, K)
    H = rand(K, T)

    est = tensor_conv(W, H)
    alpha = (reshape(data, N*T)' * reshape(est, N*T)) / norm(est)^2
    W *= sqrt(alpha)
    H *= sqrt(alpha)

    return W, H
end


"""
Fit several models with varying parameters.
Possible to iterate over lags (L), number of components (K), and different algorithms (alg).
"""
function parameter_sweep(
    data;
    L_vals=[7],
    K_vals=[3],
    alg_vals=[:mult],
    alg_options=Dict(),
    max_itr=100,
    max_time=Inf,
    lambda1=0,
    lambda2=0,
    initW=nothing,
    initH=nothing
)
    all_results = Dict()
    for (L, K, alg) in Iterators.product(L_vals, K_vals, alg_vals)
        all_results[(L, K, alg)] = fit_cnmf(
            data, L=L, K=K, alg=alg,
            alg_options=alg_options, max_itr=max_itr, max_time=max_time,
            lambda1=lambda1, lambda2=lambda2, initW=initW, initH=initH
        )
    end

    return all_results
end


"""Saves CNMF_results."""
function save_model(results::CNMF_results, path::String)
    HDF5.h5open(path, "w") do file
        HDF5.write(file, "W", results.W)
        HDF5.write(file, "H", results.H)
        HDF5.write(file, "data", results.data)
        HDF5.write(file, "loss_hist", results.loss_hist)
        HDF5.write(file, "time_hist", results.time_hist)
        HDF5.write(file, "l1_H", results.l1_H)
        HDF5.write(file, "l2_H", results.l2_H)
        HDF5.write(file, "l1_W", results.l1_W)
        HDF5.write(file, "l2_W", results.l2_W)
        HDF5.write(file, "alg", String(results.alg))
    end

end


"""Loads CNMF_results."""
function load_model(path::String)
    f = HDF5.h5open(path, "r")
    W = HDF5.read(f, "W")
    H = HDF5.read(f, "H")
    data = HDF5.read(f, "data")
    loss_hist = HDF5.read(f, "loss_hist")
    time_hist = HDF5.read(f, "time_hist")
    l1_H = HDF5.read(f, "l1_H")
    l2_H = HDF5.read(f, "l2_H")
    l1_W = HDF5.read(f, "l1_W")
    l2_W = HDF5.read(f, "l2_W")
    alg = Symbol(HDF5.read(f, "alg"))
    return CNMF_results(data, W, H, time_hist, loss_hist,
                        l1_H, l2_H, l1_W, l2_W, alg)
end
