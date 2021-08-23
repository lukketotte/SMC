module QuantileReg

export mcmc, MCMCparams

using Distributions, LinearAlgebra, StatsBase, SpecialFunctions, ProgressMeter, StaticArrays, ForwardDiff
include("Utilities.jl")
using .Utilities

abstract type MCMCAbstractType end
"""
Only use static arrays for small y, X and nMCMC.
"""
mutable struct MCMCparams <: MCMCAbstractType
    y::MixedVec
    X::MixedMat
    nMCMC::Int
    thin::Int
    burnIn::Int

    MCMCparams(y::MixedVec, X::MixedMat, nMCMC::Int, thin::Int, burnIn::Int) = length(y) ==
        size(X)[1] ? new(y, X, nMCMC, thin, burnIn) :
        throw(DomainError("Size of y and X not matching"))
end

"""
    δ(α, θ)

δ-function of the AEPD pdf
```math
\\delta_{\\alpha, \\theta} = \\frac{2\\alpha^\\theta (1-\\alpha)^\\theta}{\\alpha^\\theta + (1-\\alpha)^\\theta}
```

# Arguments
- `α::Real`: assymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
"""
function δ(α::Real, θ::Real)
    return 2*(α*(1-α))^θ / (α^θ + (1-α)^θ)
end

"""
    sampleLatent(X, y, β, α, θ, σ)

Samples latent u₁ and u₂ based on the uniform mixture

# Arguments
- `X::Array{<:Real, 2}`: model matrix
- `y::Array{<:Real, 1}`: dependent variable
- `β::Array{<:Real, 1}`: coefficient vector
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
- `σ::Real`: scale parameter, σ ≥ 0
"""
function sampleLatent(X::MixedMat, y::MixedVec, β::MixedVec, α::Real, θ::Real, σ::Real)
    n, p = validateParams(X, y, β, α, θ, σ)
    u₁, u₂ = zeros(n), zeros(n)
    μ = X*β
    for i ∈ 1:n
        if y[i] <= μ[i]
            l = ((μ[i] - y[i]) / (σ^(1/θ) * α))^θ
            u₁[i] = rand(truncated(Exponential(1/δ(α, θ)), l, Inf), 1)[1]
        else
            l = ((y[i] - μ[i]) / (σ^(1/θ) * (1-α)))^θ
            u₂[i] = rand(truncated(Exponential(1/δ(α, θ)), l, Inf), 1)[1]
        end
    end
    return u₁, u₂
end

"""
    θBlockCond(θ, X, y, β, α)

Computes the conditional distribution of θ with σ marginalized as
```math
\\int_0^\\infty \\pi(\\theta, \\sigma | \\ldots)\\ d\\sigma
```

# Arguments
- `θ::Real`: shape parameter, θ ≥ 0
- `X::Union{SArray{<:Tuple, <:Real}, Array{<:Real, 2}}`: model matrix
- `y::Union{SVector, Array{<:Real, 1}}`: dependent variable
- `β::Union{SVector, Array{<:Real, 1}}`: coefficient vector
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
"""
function θBlockCond(θ::Real, X::MixedMat, y::MixedVec, β::MixedVec, α::Real)
    z  = y-X*β
    n = length(y)
    a = δ(α, θ)*(sum((.-z[z.<0]).^θ)/α^θ + sum(z[z.>=0].^θ)/(1-α)^θ)
    return n/θ * log(δ(α, θ))  - n*log(gamma(1+1/θ)) - n*log(a)/θ + loggamma(n/θ)
end

"""
    sampleθ(θ, X, y, β, α, ε)

Samples from the marginalized conditional distribution of θ via MH using the proposal
```math
q(\\theta^*|\\theta) = U(\\max(0, \\theta - \\varepsilon), \\theta + \\varepsilon)
```

# Arguments
- `θ::Real`: shape parameter, θ ≥ 0
- `X::Union{SArray{<:Tuple, <:Real}, Array{<:Real, 2}}`: model matrix
- `y::Union{SVector, Array{<:Real, 1}}`: dependent variable
- `β::Union{SVector, Array{<:Real, 1}}`: coefficient vector
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `ε::Real`: Controls width of propsal interval, ε > 0
"""
function sampleθ(θ::Real, X::MixedMat, y::MixedVec, β::MixedVec, α::Real, ε::Real)
    prop = rand(Uniform(maximum([0., θ-ε]), minimum([3., θ + ε])), 1)[1]
    return θBlockCond(prop, X, y, β, α) - θBlockCond(θ, X, y, β, α) >= log(rand(Uniform(0,1), 1)[1]) ? prop : θ
end

"""
    sampleσ(X, y, β, α, θ)

Samples from the marginalized conditional distribution of σ as a Gibbs step

# Arguments
- `θ::Real`: shape parameter, θ ≥ 0
- `X::Union{SArray{<:Tuple, <:Real}, Array{<:Real, 2}}`: model matrix
- `y::Union{SVector, Array{<:Real, 1}}`: dependent variable
- `β::Union{SVector, Array{<:Real, 1}}`: coefficient vector
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
"""
function sampleσ(X::MixedMat, y::MixedVec, β::MixedVec, α::Real, θ::Real)
    n = length(y)
    z = y - X*β
    b = (δ(α, θ) * sum((.-z[z.<0]).^θ) / α^θ) + (δ(α, θ) * sum(z[z.>=0].^θ) / (1-α)^θ)
    return rand(InverseGamma(n/θ, b), 1)[1]
end

"""
    logβCond(X, y, β, α, θ, σ, τ, λ)

Computes log of the conditional distribution of β with X being a n × p matrix

# Arguments
- `β::Union{SVector, Array{<:Real, 1}}`: coefficient vector
- `X::Union{SArray{<:Tuple, <:Real}, Array{<:Real, 2}}`: model matrix
- `y::Union{SVector, Array{<:Real, 1}}`: dependent variable
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
- `σ::Real`: scale parameter, σ ≥ 0
- `τ::Real`: scale of π(β), τ ≥ 0
- `λ::Union{SVector, Array{<:Real, 1}}`: Horse-shoe hyper-parameter
"""
function logβCond(β::MixedVec, X::MixedMat, y::MixedVec, α::Real, θ::Real,
        σ::Real, τ::Real, λ::MixedVec)
    z = y - X*β
    pos = findall(z .> 0)
    b = δ(α, θ)/σ * (sum((.-z[z.< 0]).^θ) / α^θ + sum(z[z.>=0].^θ) / (1-α)^θ)
    return -b -1/(2*τ) * β'*diagm(λ.^(-2))*β
end

"""
    ∇ᵦ(β, X, y, α, θ, σ, τ, λ)

Computes
```math
\\nabla_\\beta \\log \\pi(\\beta | \\ldots)
```

# Arguments
- `β::Union{SVector, Array{<:Real, 1}}`: coefficient vector
- `X::Union{SArray{<:Tuple, <:Real}, Array{<:Real, 2}}`: model matrix
- `y::Union{SVector, Array{<:Real, 1}}`: dependent variable
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
- `σ::Real`: scale parameter, σ ≥ 0
- `τ::Real`: scale of π(β), τ ≥ 0
- `λ::Union{SVector, Array{<:Real, 1}}`: Horse-shoe hyper-parameter
"""
function ∇ᵦ(β::MixedVec, X::MixedMat, y::MixedVec, α::Real, θ::Real, σ::Real, τ::Real, λ::MixedVec)
    z = y - X*β # z will be SArray, not MArray
    p = length(β)
    # ∇ = MVector{p}(zeros(p))
    ∇ = zeros(length(β))
    for i in 1:length(z)
        if z[i] < 0
            ∇ -= ((δ(α,θ)/σ) * (θ/α^θ) * (-z[i])^(θ-1)) .* X[i, :]
        else
            ∇ += ((δ(α,θ)/σ) * (θ/(1-α)^θ) * z[i]^(θ-1)).* X[i, :]
        end
    end

    """
    for k in 1:p
        inner∇ᵦ!(∇, β, k, z, X, α, θ, σ, τ, λ)
    end
    """
    ∇ - 1/τ^2 * (β' * diagm(1 ./ λ.^2))'
end
"""
Helper function for ∇ᵦ
"""
function inner∇ᵦ!(∇::MVector, β::MixedVec, k::Int, z::MixedVec,
        X::MixedMat, α::Real, θ::Real, σ::Real, τ::Real, λ::MixedVec)
    ℓ₁ = θ/α^θ * sum((.-z[z.<0]).^(θ-1) .* X[z.<0, k])
    ℓ₂ = θ/(1-α)^θ * sum(z[z.>=0].^(θ-1) .* X[z.>=0, k])
    ∇[k] = -δ(α,θ)/σ * (ℓ₁ - ℓ₂) - 2*β[k]/((τ*λ[k])^2)
    nothing
end

∂β(β::MixedVec, X::MixedMat, y::MixedVec, α::Real, θ::Real, σ::Real, τ::Real, λ::MixedVec) = ForwardDiff.gradient(β -> logβCond(β, X, y, α, θ, σ, τ, λ), β)

"""
    sampleβ(X, y, u₁, u₂, β, α, θ, σ)

Samples β using latent u₁ and u₂ via Gibbs

# Arguments
- `X::Array{<:Real, 2}`: model matrix
- `y::Array{<:Real, 1}`: dependent variable
- `u₁::Array{<:Real, 1}`: latent variable
- `u₂::Array{<:Real, 1}`: latent variable
- `β::Array{<:Real, 1}`: coefficient vector
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
- `σ::Real`: scale parameter, σ ≥ 0
- `τ::Real`: scale of π(β), τ ≥ 0
"""
function sampleβ(X::MixedMat, y::MixedVec, u₁::MixedVec, u₂::MixedVec,
    β::MixedVec, α::Real, θ::Real, σ::Real, τ::Real)
    n, p = validateParams(X, y, β, α, θ, σ)
    βsim = zeros(p)
    for k in 1:p
        l, u = Float64[-Inf], Float64[Inf]
        for i in 1:n
            a = (y[i] - X[i, 1:end .!= k] ⋅  β[1:end .!= k]) / X[i, k]
            b₁ = α*σ^(1/θ)*(u₁[i]^(1/θ)) / X[i, k]
            b₂ = (1-α)*σ^(1/θ)*(u₂[i]^(1/θ)) / X[i, k]
            if (u₁[i] > 0) && (X[i, k] < 0)
                append!(l, a + b₁)
            elseif (u₂[i] > 0) && (X[i, k] > 0)
                append!(l, a - b₂)
            elseif (u₁[i] > 0) && (X[i, k] > 0)
                append!(u, a + b₁)
            elseif (u₂[i] > 0) && (X[i, k] < 0)
                append!(u, a - b₂)
            end
        end
        λ = abs(rand(Cauchy(0 , 1), 1)[1])
        βsim[k] =  maximum(l) < minimum(u) ? rand(truncated(Normal(0, λ*τ), maximum(l), minimum(u)), 1)[1] : β[k]
    end
    return βsim
end

"""
    sampleβ(X, y, β, α, θ, σ, MALA)

Samples β using via MALA-MH

# Arguments
- `β::Array{<:Real, 1}`: coefficient vector
- `ε::Union{Real, Array{<:Real, 1}}`: vector or scalar of propsal variance(s)
- `X::Array{<:Real, 2}`: model matrix
- `y::Array{<:Real, 1}`: dependent variable
- `α::Real`: Asymmetry parameter, α ∈ (0,1)
- `θ::Real`: shape parameter, θ ≥ 0
- `σ::Real`: scale parameter, σ ≥ 0
- `τ::Real`: scale of π(β), τ ≥ 0
- `MALA::Bool`: Set to true for MALA-MH step, false otherwise
"""
function sampleβ(β::MixedVec, ε::Union{Real, Array{<:Real, 1}},  X::MixedMat,
        y::MixedVec, α::Real, θ::Real, σ::Real, τ::Real, MALA::Bool = true) where {T <: Real}
    λ = abs.(rand(Cauchy(0,1), length(β)))
    # λ = ones(length(β))
    if MALA
        # ∇ = ∇ᵦ(β, X, y, α, θ, σ, τ, λ)
        ∇ = ∂β(β, X, y, α, θ, σ, τ, λ)
        prop = β + ε .^2 / 2 .* ∇ + ε .* vec(rand(MvNormal(zeros(length(β)), 1), 1))
        # ∇ₚ = ∇ᵦ(prop, X, y, α, θ, σ, τ, λ)
        ∇ₚ = ∂β(prop, X, y, α, θ, σ, τ, λ)
        αᵦ = logβCond(prop, X, y, α, θ, σ, τ, λ) - logβCond(β, X, y, α, θ, σ, τ, λ)
        αᵦ += - logpdf(MvNormal(β + ε .^2 / 2 .* ∇, ε), prop) + logpdf(MvNormal(prop + ε .^2/2 .* ∇ₚ, ε), β)
        αᵦ > log(rand(Uniform(0,1), 1)[1]) ? prop : β
    else
        prop = vec(rand(MvNormal(β, ε), 1))
        logβCond(prop, X, y, α, θ, σ, 100., λ) - logβCond(β, X, y, α, θ, σ, 100., λ) >
            log(rand(Uniform(0,1), 1)[1]) ? prop : β
    end
end

"""
function sampleβ(β::MixedVec, ε::Union{Real, MixedVec},  X::MixedMat,
        y::MixedVec, α::Real, θ::Real, σ::Real, τ::Real, MALA::Bool = true)
    # _, p = validateParams(X, y, β, ε, α, θ, σ)
    λ = abs.(rand(Cauchy(0,1), length(β)))
    if MALA
        ∇ = ∇ᵦ(β, X, y, α, θ, σ, τ, λ)
        prop = rand(MvNormal(β - ε .* ∇, typeof(ε) <: Real ? ε : diagm(ε)), 1) |> vec
    else
        prop = vec(rand(MvNormal(β, typeof(ε) <: Real ? ε : diagm(ε)), 1))
    end
    logβCond(prop, X, y, α, θ, σ, 100., λ) - logβCond(β, X, y, α, θ, σ, 100., λ) >
        log(rand(Uniform(0,1), 1)[1]) ? prop : β
end

"""

"""
    MCMC(Params)

MCMC algorithm for the the AEPD with known α not using the uniform scale mixture representation. Uses the
Uniform(0,1) transformation for params.y <: Integer to ensure the quantiles are continuous.

# Arguments
- `params <: MCMCAbstractType`: struct with all settings for sampler
- `α::Real`: Asymmetry parameter which determines quantile, α ∈ (0,1)
- `τ::Real`: Hyperparameter for π(β) scale, τ > 0
- `ε::Real`: Width of proposal interval for MH step for θ, ε > 0
- `εᵦ::Union{Real, Array{<:Real, 1}}`: Variance of proposal for MH step for β
- `β₁::Union{Real, Array{<:Real, 1}, Nothing}`: Initial value for β
- `σ₁::Real`: Initial value for σ
- `θ₁::Real`: Initial value for θ
- `MALA::Bool`: Set to true for MALA-MH step, false otherwise
"""
function mcmc(params::MCMCparams, α::Real, τ::Real, ε::Real, εᵦ::Union{Real, Array{<:Real, 1}},
        β₁::Union{MixedVec, Nothing} = nothing, σ₁::Real = 1, θ₁::Real = 1, MALA::Bool = true)
    # TODO: validation
    n, p = size(params.X)
    β = zeros(params.nMCMC, p)
    σ, θ = zeros(params.nMCMC), zeros(params.nMCMC)
    β[1,:] = typeof(β₁) <: Nothing ? inv(params.X'*params.X)*params.X'*params.y : β₁
    σ[1], θ[1] = σ₁, θ₁

    p = Progress(params.nMCMC-1, dt=0.5,
        barglyphs=BarGlyphs('|','█', ['▁' ,'▂' ,'▃' ,'▄' ,'▅' ,'▆', '▇'],' ','|',),
        barlen=50, color=:green)

    for i ∈ 2:params.nMCMC
        next!(p; showvalues=[(:iter,i) (:θ, round(θ[i-1], digits = 3)) (:σ, round(σ[i-1], digits = 3))])
        mcmcInner!(θ, σ, β, i, params, ε, εᵦ, α, τ, MALA)
    end
    return mcmcThin(θ, σ, β, params)
end

"""
    MCMC(Params)

MCMC algorithm for the the AEPD with known α using the scale mixture representation. Uses the
Uniform(0,1) transformation for params.y <: Integer to ensure the quantiles are continuous.

# Arguments
- `params <: MCMCAbstractType`: struct with all settings for sampler
- `α::Real`: Asymmetry parameter which determines quantile, α ∈ (0,1)
- `τ::Real`: Hyperparameter for π(β) scale, τ > 0
- `ε::Real`: Width of proposal interval for MH step for θ, ε > 0
- `β₁::Union{Real, Array{<:Real, 1}, Nothing}`: Initial value for β
- `σ₁::Real`: Initial value for σ
- `θ₁::Real`: Initial value for θ
"""
function mcmc(params::MCMCparams, α::Real, τ::Real, ε::Real,
    β₁::Union{MixedVec, Nothing} = nothing, σ₁::Real = 1, θ₁::Real = 1)
    # TODO: validation
    n, p = size(params.X)
    β = zeros(params.nMCMC, p)
    σ, θ = zeros(params.nMCMC), zeros(params.nMCMC)
    β[1,:] = typeof(β₁) <: Nothing ? inv(params.X'*params.X)*params.X'*params.y : β₁
    σ[1], θ[1] = σ₁, θ₁

    p = Progress(params.nMCMC-1, dt=0.5,
        barglyphs=BarGlyphs('|','█', ['▁' ,'▂' ,'▃' ,'▄' ,'▅' ,'▆', '▇'],' ','|',),
        barlen=50, color=:green)

    for i ∈ 2:params.nMCMC
        next!(p; showvalues=[(:iter,i) (:θ, round(θ[i-1], digits = 3)) (:σ, round(σ[i-1], digits = 3))])
        mcmcInner!(θ, σ, β, i, params, ε, α, τ)
    end
    return mcmcThin(θ, σ, β, params)
end

function mcmcInner!(θ::Array{<:Real, 1}, σ::Array{<:Real, 1}, β::MixedMat, i::Int, params::MCMCparams, ε::Real,
    εᵦ::Union{Real, Array{<:Real, 1}}, α::Real, τ::Real, MALA::Bool)
        # if y is integer, transform so that the quantiles are continuous
        y = typeof(params.y[1]) <: Integer ?
            log.(params.y + rand(Uniform(), length(params.y)) .- α) : params.y
        θ[i] = sampleθ(θ[i-1], params.X, y, β[i-1,:], α, ε)
        σ[i] = sampleσ(params.X, y, β[i-1,:], α, θ[i])
        β[i,:] = sampleβ(β[i-1,:], εᵦ, params.X, y, α, θ[i], σ[i], τ, MALA)
        nothing
end

# function sampleβ(X::MixedMat, y::MixedVec, u₁::MixedVec, u₂::MixedVec, β::MixedVec, α::Real, θ::Real, σ::Real, τ::Real)
function mcmcInner!(θ::Array{<:Real, 1}, σ::Array{<:Real, 1}, β::MixedMat, i::Int,
    params::MCMCparams, ε::Real, α::Real, τ::Real)
        # if y is integer, transform so that the quantiles are continuous
        y = typeof(params.y[1]) <: Integer ?
            log.(params.y + rand(Uniform(), length(params.y)) .- α) : params.y
        θ[i] = sampleθ(θ[i-1], params.X, y, β[i-1,:], α, ε)
        σ[i] = sampleσ(params.X, y, β[i-1,:], α, θ[i])
        u1, u2 = sampleLatent(params.X, y, β[i-1,:], α, θ[i], σ[i])
        β[i,:] = sampleβ(params.X, y, u1, u2, β[i-1,:], α, θ[i], σ[i], τ)
        nothing
end

function mcmcThin(θ::Array{<:Real, 1}, σ::Array{<:Real, 1}, β::Array{<:Real, 2}, params::MCMCparams) where {M <: MVector, A <: MArray}
    thin = ((params.burnIn:params.nMCMC) .% params.thin) .=== 0

    β = (β[params.burnIn:params.nMCMC,:])[thin,:]
    θ = (θ[params.burnIn:params.nMCMC])[thin]
    σ = (σ[params.burnIn:params.nMCMC])[thin]
    return β, θ, σ
end

end
