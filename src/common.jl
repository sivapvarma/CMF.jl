using LinearAlgebra

const AbstractTensor{T} = AbstractArray{T, 3}

const EPSILON = eps()

function tensor_conv(W::AbstractTensor, H::AbstractMatrix)
    L, N, K = size(W)
    T = size(H)[2]

    pred = zeros(N, T)
    for lag = 0:(L-1)
        pred[:, lag+1:T] += s_dot(W[lag+1, :, :], H, lag)
    end
    return pred
end

"""Computes normalized quadratic loss."""
compute_loss(data::AbstractMatrix, W::AbstractTensor, H::AbstractMatrix) =
    norm(compute_resids(data, W, H)) / norm(data)

"""Computes matrix of residuals."""
compute_resids(data::AbstractMatrix, W::AbstractTensor, H::AbstractMatrix) =
    tensor_conv(W, H) - data


function tensor_transconv(W::AbstractTensor, X::AbstractMatrix)
    L, N, K = size(W)
    T = size(X)[2]

    result = zeros(K, T)
    for lag = 0:(L-1)
        result[:, 1:T-lag] += W[lag+1, :, :]' * shift_cols(X, -lag)
    end

    return result
end


function s_dot(Wl::AbstractMatrix, H::AbstractMatrix, lag::Integer)
    K, T = size(H)

    if (lag < 0)
        return Wl * H[:, 1-lag:T]

    else  # lag >= 0
        return Wl * H[:, 1:T-lag]
    end
end


function shift_cols(X::AbstractMatrix, lag::Integer)
    T = size(X)[2]

    if (lag <= 0)
        return X[:, 1-lag:T]

    else  # lag > 0
        return X[:, 1:T-lag]
    end
end


function shift_and_stack(H::AbstractMatrix, L::Integer)
    K, T = size(H)

    H_stacked = zeros(L*K, T)
    for lag = 0:(L-1)
        H_stacked[1+K*lag:K*(lag+1), 1+lag:T] = shift_cols(H, lag)
    end

    return H_stacked
end


function unpack_dims(W::AbstractTensor, H::AbstractMatrix)
    L, N, K = size(W)
    T = size(H, 2)

    return N, T, K, L
end
