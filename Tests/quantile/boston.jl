using Distributions, QuantileRegressions, LinearAlgebra, Random, SpecialFunctions, QuadGK, RCall
include("../aepd.jl")
include("../../QuantileReg/QuantileReg.jl")
using .AEPD, .QuantileReg

using Plots, PlotThemes, CSV, DataFrames, StatFiles, CSVFiles, HTTP
theme(:juno)

using RDatasets

## Detta ska vi ha!
dat = HTTP.get("https://raw.githubusercontent.com/jbrownlee/Datasets/master/daily-max-temperatures.csv") |> x -> CSV.File(x.body) |> DataFrame
scatter(dat[1:(size(dat,1)-1), :Temperature], dat[2:size(dat,1), :Temperature])

y = log.(dat[2:size(dat, 1),:Temperature])
X = hcat(ones(length(y)), log.(dat[1:(size(dat,1)-1),:Temperature]))

quants = rcopy(R"""
suppressWarnings(suppressMessages(library(bayesQR, lib.loc = "C:/Users/lukar818/Documents/R/win-library/4.0")))
y = $y
x = $X
quants = seq(0.1, 0.9, length.out = 9)
res = numeric(9)
for(i in 1:9){
        beta = bayesQR(y ~ x[,2], quantile=quants[i], ndraw = 12000, keep = 1)[[1]]$betadraw
        ids = complete.cases(beta)
        res[i] = mean(y[ids] <= c(x[ids,] %*% colMeans(beta[ids, ])))
    }
res
""")
quants

quants2 = quants

[mean(β[findall(.!isnan.(β[:,i])),i]) for i in 1:2] |> println
[√var(β[findall(.!isnan.(β[:,i])),i]) for i in 1:2] |> println

par = Sampler(y, X, 0.5, 10000, 1, 1000);
β, θ, σ, α = mcmc(par, .3, 0.11, 1.1, 2, 1, 0.5, rand(size(par.X, 2)));

## Stocks seems to work ok
dat = load(string(pwd(), "/Tests/data/AMZN.csv")) |> DataFrame
y = log.(dat[2:size(dat, 1),:Close])
X = hcat(ones(length(y)), log.(dat[1:(size(dat,1)-1),:Close]))

par = Sampler(y, X, 0.5, 10000, 1, 1000);
β, θ, σ, α = mcmc(par, .3, 0.11, 1.1, 2, 1, 0.5, rand(size(par.X, 2)));
plot(α)
plot(θ)
plot(β[:,2])
acceptance(θ)
acceptance(β)
acceptance(α)

par.α = mcτ(0.9, mean(α), mean(θ), mean(σ), 5000)
#par.nMCMC, par.burnIn = 6000, 1000
βres = mcmc(par, 0.5, mean(θ), mean(σ), rand(size(par.X, 2)))
mean(par.y .<= par.X *  median(βres, dims = 1)')
acceptance(βres)
median(βres, dims = 1) |> println
sqrt.(var(βres, dims = 1)) |> println
plot(βres[:,2])

control =  Dict(:tol => 1e-3, :max_iter => 1000, :max_upd => 0.3,
  :is_se => true, :est_beta => true, :est_sigma => true,
  :est_p => true, :est_tau => true, :log => false, :verbose => false)

res = quantfreq(y, X, control)

τ = mcτ(0.9, res[:tau], res[:p], res[:sigma], 5000)
freq = quantfreq(y, X, control, res[:sigma], res[:p], τ)

freq[:beta] |> println
freq[:se] |> println


τ = 0.9
N = 2000
B = zeros(N, size(X, 2))
for i ∈ 1:N
    println(i)
    ids = sample(1:length(y), length(y))
    B[i,:] =  DataFrame(hcat(y[ids], X[ids,:]), :auto) |> x ->
    qreg(@formula(x1 ~ x3), x, τ) |> coef
    #freq = quantfreq(y[ids], X[ids,:], control, res[:sigma], res[:p], τ)
    #B[i,:] = freq[:beta]
end
mean(B, dims = 1) |> println
sqrt.(var(B, dims = 1)) |> println

par.α = 0.9
β1, θ1, _ = mcmc(par, .25, 1., 1., 2, rand(size(par.X, 2)));
mean(par.y .<= par.X *  median(β1, dims = 1)')
plot(θ1)
acceptance(θ1)
acceptance(β1)

b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3), x, 0.7) |> coef;
q = X * b;
μ = X * mean(β, dims = 1)' |> x -> reshape(x, size(x, 1));
par.α = [quantconvert(q[j], mean(θ), mean(α), μ[j], mean(σ)) for j in 1:length(par.y)] |> mean



##
RDatasets.datasets("mlmRev") |> println
RDatasets.datasets("MASS") |> println

dat = dataset("MASS", "GAGurine")
y = log.(dat[!, :GAG])
X = hcat(ones(length(y)), dat[!,:Age], dat[!,:Age].^2)

par = Sampler(y, X, 0.5, 10000, 1, 2000);
β, θ, σ, α = mcmc(par, 1., 0.15, 1., 2, 1, 0.5, zeros(size(X, 2)));
plot(α)
plot(θ)
plot(β[:,3])
acceptance(α)

mean(θ)

b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3 + x4), x, 0.1) |> coef;
q = X * b;
μ = X * mean(β, dims = 1)' |> x -> reshape(x, size(x, 1));
par.α = [quantconvert(q[j], mean(θ), mean(α), μ[j], mean(σ)) for j in 1:length(par.y)] |> mean
par.α = mcτ(0.1, mean(α), mean(θ), mean(σ), 5000)
par.α = 0.1
βres = mcmc(par, 0.3, median(θ), median(σ), zeros(size(par.X, 2)))
mean(par.y .<= par.X *  median(βres, dims = 1)')
acceptance(βres)
mean(y .<= q)


## works ok
dat = dataset("MASS", "nlschools")
dat
y = log.(dat[!, :Lang])
X = hcat(ones(length(y)), Matrix(dat[!, [2,4,5]]))

par = Sampler(y, X, 0.5, 10000, 1, 2000);
β, θ, σ, α = mcmc(par, 1., 0.15, 1., 2, 1, 0.5, zeros(size(X, 2)));
plot(α)
acceptance(α)

b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3 + x4 + x5), x, 0.7) |> coef;
q = X * b;
μ = X * median(β, dims = 1)' |> x -> reshape(x, size(x, 1));
par.α = [quantconvert(q[j], median(θ), median(α), μ[j], median(σ)) for j in 1:length(par.y)] |> mean
mcτ(0.7, median(α), median(θ), median(σ), 5000)
βres = mcmc(par, 0.6, median(θ), median(σ), zeros(size(par.X, 2)))
mean(par.y .<= par.X *  median(βres, dims = 1)')
acceptance(βres)
mean(y .<= q)

## QuantileReg data
dat = load(string(pwd(), "/Tests/data/Immunog.csv")) |> DataFrame;
names(dat)
y = dat[:, :IgG];
X = hcat(ones(size(dat,1)), dat[:,:Age], dat[:,:Age].^2)

par = Sampler(y, X, 0.5, 6000, 1, 2000);
b = DataFrame(hcat(par.y, par.X), :auto) |> x ->
    qreg(@formula(x1 ~  x3 + x4), x, 0.5) |> coef;
β, θ, σ, α = mcmc(par, 1.3, 0.2, 1.5, 2, 1, 0.5, b);

plot(β[:,2])
plot(σ)
plot(θ)
plot(α)
acceptance(β)
acceptance(θ)
acceptance(α)

b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3 + x4), x, 0.6) |> coef;
q = X * b;
μ = X * mean(β, dims = 1)' |> x -> reshape(x, size(x, 1));
par.α = [quantconvert(q[j], median(θ), median(α), μ[j], median(σ)) for j in 1:length(par.y)] |> mean

par.α = mcτ(0.7, median(α), median(θ), median(σ))
βres = mcmc(par, 1, median(θ), median(σ), zeros(size(par.X, 2)))
[par.y[i] <= X[i,:] ⋅ median(βres, dims = 1)  for i in 1:length(par.y)] |> mean


reps = 50
res = zeros(reps)
for i in 1:reps
    βres, _ = mcmc(par, 1, median(θ), median(σ), zeros(size(par.X, 2)));
    res[i] = ([par.y[i] <= X[i,:] ⋅ median(βres, dims = 1)  for i in 1:length(par.y)] |> mean)
end

mean(res)

## Boston
#dat = load(string(pwd(), "/Tests/data/BostonHousing2.csv")) |> DataFrame;
dat = dataset("MASS", "Boston")
y = log.(dat[:, :MedV])
X = dat[:, Not(["MedV"])] |> Matrix
X = hcat([1 for i in 1:length(y)], X);

rcopy(R"""
suppressWarnings(suppressMessages(library(bayesQR, lib.loc = "C:/Users/lukar818/Documents/R/win-library/4.0")))
dat = $dat
bayesQR(MedV ~ ., dat, ndraw = 2000)
""")

function bayesQR(dat::DataFrame, y::Symbol, quant::Real, ndraw::Int, keep::Int)
    rcopy(R"""
        suppressWarnings(suppressMessages(library(bayesQR, lib.loc = "C:/Users/lukar818/Documents/R/win-library/4.0")))
        quant = $quant
        ndraw = $ndraw
        keep = $keep
        bayesQR(y ~ X[,2] + X[,3], quantile = quant, ndraw = ndraw, keep=keep)[[1]]$betadraw
    """)
end

par = Sampler(y, X, 0.5, 10000, 5, 2000);
b = DataFrame(hcat(par.y, par.X), :auto) |> x ->
    qreg(@formula(x1 ~  x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10 +
        x11 + x12 + x13 + x14 + x15), x, 0.5) |> coef;

#mcmc(par, 0.5, 0.5, 1., 1, 2, 0.5, [0., 0., 0.]);
β, θ, σ, α = mcmc(par, 0.25, .2, 0.4, 1, 2, 0.5, zeros(14));

acceptance(β)
acceptance(θ)
acceptance(α)
plot(α)
plot(θ)
plot(β[:,2])

b = DataFrame(hcat(par.y, par.X), :auto) |> x ->
    qreg(@formula(x1 ~  x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10 +
        x11 + x12 + x13 + x14 + x15), x, 0.9) |> coef;
q = X * b;
μ = X * median(β, dims = 1)' |> x -> reshape(x, size(x, 1));
τ = [quantconvert(q[j], median(θ), median(α), μ[j],
    median(σ)) for j in 1:length(par.y)] |> mean

par.α = mcτ(0.9, mean(α), mean(θ), mean(σ))
βlp = mcmc(par, .0001, mean(θ), mean(σ), b)
acceptance(βlp)

plot(βlp[:,3])

par.α = τ;
par.nMCMC = 4000
βres, _ = mcmc(par, 0.01, median(θ), median(σ), b);
plot(βres[:,1])
[par.y[i] <= X[i,:] ⋅ median(βres, dims = 1)  for i in 1:length(par.y)] |> mean

## Fishery data
dat = HTTP.get("https://people.brandeis.edu/~kgraddy/datasets/fish.out") |> x -> CSV.File(x.body) |> DataFrame
names(dat)

y = dat[:,:qty]
X = hcat(ones(length(y)), dat[:,:price])

par = Sampler(y, X, 0.5, 10000, 1, 5000);
b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3), x, 0.5) |> coef;

β, θ, σ, α = mcmc(par, 1, 0.25, 0.7, 1, 2, 0.5, b);

q = par.X * (DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3), x, 0.4) |> coef);
μ = X * median(β, dims = 1)' |> x -> reshape(x, size(x, 1));
τ = [quantconvert(q[j], median(θ), median(α), μ[j], median(σ)) for j in 1:length(par.y)] |> mean

par = Sampler(y, X, τ, 10000, 1, 5000);

n = 2000
s,p,a = median(σ), median(θ), median(α)
res = zeros(n)
for i in 1:n
    dat = rand(Aepd(0, s, p, a), n)
    q = DataFrame(hcat(dat), :auto) |> x -> qreg(@formula(x1 ~  1), x, 0.4) |> coef;
    res[i] = quantconvert(q[1], p, a, 0, s)
end
par.α = mean(res)

βres, _ = mcmc(par, 0.4, median(θ), median(σ), b);
plot(βres[:,2])

[par.y[i] <= q[i] for i in 1:length(y)] |> mean
[par.y[i] <= X[i,:] ⋅ median(βres, dims = 1)  for i in 1:length(par.y)] |> mean

## Prostate data
dat = load(string(pwd(), "/Tests/data/prostate.csv")) |> DataFrame;

names(dat)
y = dat[:, :lpsa]
X = hcat(ones(length(y)), Matrix(dat[:,2:9]))

par = Sampler(y, X, 0.5, 10000, 1, 5000);
b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10), x, 0.5) |> coef;

β, θ, σ, α = mcmc(par, 1, 0.25, 0.7, 1, 2, 0.5, zeros(9));
acceptance(β)
acceptance(α)
acceptance(θ)
plot(σ)
plot(β[:,2])
plot(θ)

b = DataFrame(hcat(par.y, par.X), :auto) |> x -> qreg(@formula(x1 ~  x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10), x, 0.1) |> coef;
q = par.X * b

n = 2000
s,p,a = median(σ), median(θ), median(α)
res = zeros(n)
for i in 1:n
    dat = rand(Aepd(0, s, p, a), n)
    q = DataFrame(hcat(dat), :auto) |> x -> qreg(@formula(x1 ~  1), x, 0.1) |> coef;
    res[i] = quantconvert(q[1], p, a, 0, s)
end
par.α = mean(res)

par.α = mcτ(0.9, mean(α), mean(θ), mean(σ))
βres = mcmc(par, 0.6, median(θ), median(σ), zeros(9));
plot(βres[:,4])
acceptance(βres)

[par.y[i] <= q[i] for i in 1:length(y)] |> mean
[par.y[i] <= X[i,:] ⋅ median(βres, dims = 1)  for i in 1:length(par.y)] |> mean

dat2 = dat[:,2:10]
b = rcopy(R"""
suppressWarnings(suppressMessages(library(bayesQR, lib.loc = "C:/Users/lukar818/Documents/R/win-library/4.0")))
dat = $dat2
bayesQR(lpsa ~ ., dat, quantile = 0.9, ndraw = 10000, keep=4)[[1]]$betadraw
""")

.√(var(b,dims=1)) |> println
.√(var(βres,dims=1)) |> println

mean(βres,dims=1) |> println
mean(b,dims=1) |> println
