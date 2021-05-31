using Distributions, LinearAlgebra, StatsBase, SpecialFunctions
using Plots, PlotThemes
theme(:juno)

## generate data
n = 100
β = [2.1, 0.8]
α, θ, σ = 0.5, 2., 1.
x₁ = rand(Normal(0, 5), n)
repeat([1], 100)
x₂ = rand(Normal(2, 5), n)
X = [repeat([1], n) x₂]
y = X * β .+ rand(Normal(0, σ), n)

function δ(α::T, θ::T)::T where {T <: Real}
    2*(α*(1-α))^θ / (α^θ + (1-α)^θ)
end

function sampleLatent(X::Array{T, 2}, y::Array{T, 1}, β::Array{T, 1}, α::T, θ::T, σ::T) where {T <: Real}
    n,_ = size(X)
    u₁ = zeros(n)
    u₂ = zeros(n)
    for i in 1:n
        μ = X[i,:] ⋅ β
        if y[i] <= μ
            l = ((μ - y[i]) * gamma(1+1/θ) / (σ * α))^θ
            u₁[i] = rand(truncated(Exponential(1), l, Inf), 1)[1]
        else
            l = ((y[i] - μ) * gamma(1+1/θ) / (σ * (1- α)))^θ
            u₂[i] = rand(truncated(Exponential(1), l, Inf), 1)[1]
        end
    end
    u₁, u₂
end

function sampleSigma(X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, θ::T, ν::N = 1) where {T, N <: Real}
    u1Pos = u₁ .> 0
    u2Pos = u₂ .> 0
    l₁ = maximum((X[u1Pos,:] * β .- y[u1Pos]) .* gamma(1+1/θ) ./ (α .* u₁[u1Pos].^(1/θ)))
    l₂ = maximum((y[u2Pos] .- X[u2Pos,:] * β) .* gamma(1+1/θ) ./ ((1-α) .* u₂[u2Pos].^(1/θ)))
    rand(Pareto(ν + length(y) - 1, maximum([l₁ l₂])), 1)[1]
end

function sampleSigma(X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, θ::T, ν::N = 1) where {T, N <: Real}
    n = length(y)
    lower = zeros(n)
    for i in 1:n
        μ = X[i,:] ⋅ β
        if u₁[i] > 0
            lower[i] = (μ - y[i]) * gamma(1+1/θ) / (α * u₁[i]^(1/θ))
        else
            lower[i] = (y[i] - μ) * gamma(1+1/θ) / ((1-α) * u₂[i]^(1/θ))
        end
    end
    rand(Pareto(ν + length(y) - 1, maximum(lower)), 1)[1]
end

function θinterval(X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, σ::T) where {T <: Real}
    n = length(y)
    θ = range(0.01, 4, length = 2500)
    θₗ, θᵤ = zeros(n), zeros(n)
    for i in 1:n
        if u₁[i] > 0
            θside = (u₁[i] .^ (1 ./ θ)) ./ gamma.(1 .+ 1 ./ θ)
            c = (X[i,:] ⋅ β - y[i]) / (α * σ)
            ids = findall(θside .> c)
            θᵤ[i] = length(ids) > 0 ? θ[maximum(findall(θside .> c))] : Inf
            θₗ[i] = length(ids) > 0 ? θ[minimum(findall(θside .> c))] : 0
        else
            θside = (u₂[i] .^ (1 ./ θ)) ./ gamma.(1 .+ 1 ./ θ)
            c = (y[i] - X[i,:] ⋅ β) / ((1-α) * σ)
            ids = findall(θside .> c)
            θᵤ[i] = length(ids) > 0 ? θ[maximum(findall(θside .> c))] : Inf
            θₗ[i] = length(ids) > 0 ? θ[minimum(findall(θside .> c))] : 0
        end
    end
    [maximum(θₗ) minimum(θᵤ)]
end

function θcond(θ::T, u₁::Array{T, 1}, u₂::Array{T, 1}, α::T) where {T <: Real}
    n = length(u₁)
    n*(1+1/θ) * log(δ(α, θ)) - δ(α, θ) * sum(u₁ .+ u₂)
end

function sampleθ(θ::T, X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, σ::T) where {T <: Real}
    interval = θinterval(X, y, u₁, u₂, β, α, σ)
    minimum(interval) >= maximum(interval) ? minimum(interval) : rand(Uniform(minimum(interval), maximum(interval)), 1)[1]
end


## conditional density seems to be centered 0.5 too high
u1, u2 = sampleLatent(X, y, [2.1, 0.8], α, 2., 1.)
θinterval(X, y, u1, u2, β, α, σ) |> println

n*(1+1/θ) * log(δ(α, θ)) - δ(α, θ) * sum( u1 .+ u2)

p = range(0.5, 4., length = 200)
pl = [θcond(a, u1, u2, 0.73)  for a in p]
plot(p, pl, legend = false)

##

function sampleβ(X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, θ::T, σ::T, τ::T) where {T <: Real}
    n, p = size(X)
    βsim = zeros(p)

    for k in 1:p
        u1Pos = (X[:, k] .< 0) .& (u₁ .> 0)
        u2Pos = (X[:, k] .> 0) .& (u₂ .> 0)
        l = []
        if sum(u1Pos) > 0
            a1 = (y[u1Pos] .- X[u1Pos, 1:end .!= k] * β[1:end .!= k]) ./ X[u1Pos, k]
            b1 = σ*α ./ X[u1Pos, k] .* u₁[u1Pos].^(1/θ) ./ gamma(1 + 1/θ)
            l = append!(l, a1.+b1)
        end
        if sum(u2Pos) > 0
            a2 = (y[u2Pos] .- X[u2Pos, 1:end .!= k] * β[1:end .!= k]) ./ X[u2Pos, k]
            b2 = σ*(1-α) ./ X[u2Pos, k] .* u₂[u2Pos].^(1/θ) ./ gamma(1 + 1/θ)
            l = append!(l, a2.-b2)
        end
        u1Pos = (X[:, k] .> 0) .& (u₁ .> 0)
        u2Pos = (X[:, k] .< 0) .& (u₂ .> 0)
        u = []
        if sum(u1Pos) > 0
            a1 = (y[u1Pos] .- X[u1Pos, 1:end .!= k] * β[1:end .!= k]) ./ X[u1Pos, k]
            b1 = σ*α ./ X[u1Pos, k] .* u₁[u1Pos].^(1/θ) ./ gamma(1 + 1/θ)
            u = append!(u, a1.+b1)
        end
        if sum(u2Pos) > 0
            a2 = (y[u2Pos] .- X[u2Pos, 1:end .!= k] * β[1:end .!= k]) ./ X[u2Pos, k]
            b2 = σ*(1-α) ./ X[u2Pos, k] .* u₂[u2Pos].^(1/θ) ./ gamma(1 + 1/θ)
            u = append!(u, a2.-b2)
        end

        βsim[k] = maximum(l) < minimum(u) ? rand(truncated(Normal(0, τ), maximum(l), minimum(u)), 1)[1] : maximum(l)
    end
    βsim
end

function sampleβ(X::Array{T, 2}, y::Array{T, 1}, u₁::Array{T, 1}, u₂::Array{T, 1},
    β::Array{T, 1}, α::T, θ::T, σ::T, τ::T) where {T <: Real}
    n, p = size(X)
    βsim = zeros(p)

    for k in 1:p
        l, u = [], []
        for i in 1:n
            a = (y[i] - X[i, 1:end .!= k] ⋅  β[1:end .!= k]) / X[i, k]
            b₁ = (α*σ*(u₁[i]^(1/θ)) / gamma(1+1/θ)) / X[i, k]
            b₂ = ((1-α)*σ*(u₂[i]^(1/θ)) / gamma(1+1/θ)) / X[i, k]
            if (u₁[i] > 0) && (X[i, k] < 0)
                l = append!(l, a + b₁)
            elseif (u₂[i] > 0) && (X[i, k] > 0)
                l = append!(l, a - b₂)
            elseif (u₁[i] > 0) && (X[i, k] > 0)
                u = append!(u, a + b₁)
            else
                u = append!(u, a - b₂)
            end
        end
        βsim[k] = maximum(l) < minimum(u) ? rand(truncated(Normal(0, τ), maximum(l), minimum(u)), 1)[1] : maximum(l)
    end
    βsim
end

u1, u2 = sampleLatent(X, y, β, α, θ, σ)
sampleβ(X, y, u1, u2, β, α, θ, σ, 10.)

k = 1
i = 2


nMCMC = 1000
σ = zeros(nMCMC)
σ[1] = 1
β = zeros(nMCMC, 2)
β[1, :] = [2.1, 0.8]
θ = zeros(nMCMC)
θ[1] = 2.
simU1 = zeros(nMCMC, n)
simU2 = zeros(nMCMC, n)

for i in 2:nMCMC
    (i % 250 === 0) && println(i)
    # print(i)
    u1, u2 = sampleLatent(X, y, β[i-1,:], α, θ[i-1], σ[i-1])
    simU1[i,:] = u1
    simU2[i,:] = u2
    β[i,:] = sampleβ(X, y, u1, u2, β[i-1,:], α, θ[i-1], σ[i-1], 10.)
    σ[i] = sampleSigma(X, y, u1, u2, β[i, :], α, θ[i-1], 1)
    # σ[i] = 1.
    θ[i] = sampleθ(θ[i-1], X, y, u1, u2, β[i, :], α, σ[i])
end



plot(β[:, 2])
plot(σ)
plot(θ)


plot(cumsum(σ) ./ (1:nMCMC))
plot(cumsum(β[:, 2]) ./ (1:nMCMC))
plot(cumsum(θ) ./ (1:nMCMC))

mean(σ) * √(gamma(1+1/θ))

σ

i = 3
sampleSigma(X, y, simU1[i,:], simU2[i,:], β[i, :], α, θ[i-1], 1)

lower = zeros(n)
for j in 1:n
    μ = X[j,:] ⋅ β[i,:]
    if y[j] <= μ
        lower[j] = (μ - y[j]) * gamma(1+1/θ[i-1]) / (α * simU1[i,j]^(1/θ[i-1]))
    else
        lower[j] = (y[j] - μ) * gamma(1+1/θ[i-1]) / ((1-α) * simU2[i,j]^(1/θ[i-1]))
    end
end

findall(lower .=== Inf)

j = 42

(y[j] - μ) * gamma(1+1/θ[i-1]) / ((1-α) * simU2[i,j]^(1/θ[i-1]))

maximum(lower)
rand(Pareto(1 + length(y) - 1, maximum(lower)), 1)[1]

sampleβ(X, y, simU1[i,:], simU2[i,:], β[i-1,:], α, θ[i-1], σ[i-1], 10.)
sum(simU1[i,:])
sum(simU2[i,:])
β[i-2, :]
