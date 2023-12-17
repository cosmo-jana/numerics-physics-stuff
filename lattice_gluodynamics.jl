module GluoDynamics

using Random
using StaticArrays
using PyPlot
using LinearAlgebra
using JLD2
using FileIO
using Test

include("su3.jl")
include("timeseries.jl")

export GluoDynamicsLattice, add_offset!, advance!, cold_start, compute_action, compute_action_diff
export compute_action_diff_naive, compute_stable, cyclic_dist_squared, cyclic_dist_squared_1d, eval_plaquetts
export eval_polyakov_loop, generate_plaquett_indicies, generate_possible_mc_steps, generate_stable_indicies
export get_link_index, info_every_secs, mc_step_metropolis!, mc_sweep_metropolis!, ndims
export update_polyakov_correlator!, warm_start, real_of_mul, run_simple_simulation!
export converge!

######################### simulation type ########################
const ndims = 4

Base.@kwdef mutable struct GluoDynamicsLattice
    # size of the time direction
    Nt::Int
    # size of the space directions
    N::Int
    # mc step
    step::Int
    # 4D lattice (4 link variables per side) + (1 euclidian time direction, 3 space directions)
    U::Array{SU3,ndims + 1}
    # neighbors (4D index) for each side in the 4D lattice (2*4 per side)
    stable_indicies::Array{CartesianIndex{ndims + 1},ndims + 3}
    # inverse coupling constant
    beta::Float64
    # precomputed prefactor -beta/N for the compution of the action difference
    action_prefactor::Float64
    # reproject every nth iterations
    reproject_every::Int
    # possible mc steps to choose from
    nchoices::Int
    choices::Vector{SU3}
    # regenerate possible random choices
    new_choices_every::Int
    # the prng is Xoshiro256++ which has a periode of 2^256 − 1 which is sufficient
    rng::Xoshiro
    # small number for generation of mc step proposals (which should be close to unity)
    epsilon::Float64
    # indicies for evlaulation of the plaquett observable
    plaquett_indicies::Array{CartesianIndex{ndims + 1},ndims + 3}
end

############################## links ############################
# index into the link variables (gluon field)
function add_offset!(coord, signed_direction, dims)
    dir = abs(signed_direction)
    sgn = sign(signed_direction)
    coord[dir] = mod1(coord[dir] + sgn, dims[dir])
end

function get_link_index(coord, signed_direction, offsets, dims)
    coord = collect(Tuple(coord)) # CartesianIndex -> Array
    for off in offsets
        add_offset!(coord, off, dims)
    end
    dir = abs(signed_direction)
    if signed_direction < 0
        coord[dir] = mod1(coord[dir] - 1, dims[dir])
    end
    return CartesianIndex(dir, coord...)
end

########################## computing the action ##################
function generate_stable_indicies(N, Nt)
    @info "generating stable indicies"
    dims = (N, N, N, Nt)
    nstables_per_side = (ndims - 1) * 2 # = 6 for ndims = 4
    stable_indicies = Array{CartesianIndex{ndims + 1}}(undef, nstables_per_side, ndims - 1, ndims, dims...)
    Threads.@threads for n in CartesianIndices(dims) # each lattice location
        for mu in 1:ndims # link direction
            nu_i = 1
            for nu in 1:ndims # other direction of the placett
                if mu != nu
                    stable_indicies[1, nu_i, mu, n] = get_link_index(n, nu, [mu], dims)
                    stable_indicies[2, nu_i, mu, n] = get_link_index(n, -mu, [nu, mu], dims)
                    stable_indicies[3, nu_i, mu, n] = get_link_index(n, -nu, [nu], dims)
                    stable_indicies[4, nu_i, mu, n] = get_link_index(n, -nu, [mu], dims)
                    stable_indicies[5, nu_i, mu, n] = get_link_index(n, -mu, [-nu, mu], dims)
                    stable_indicies[6, nu_i, mu, n] = get_link_index(n, nu, [-nu], dims)
                    nu_i += 1
                end
            end
        end
    end
    return stable_indicies
end

# compute the action difference when changing one link
@inline function compute_stable(s::GluoDynamicsLattice, i::CartesianIndex{5})
    A = zero(SMatrix{3,3,ComplexF64})
    @inbounds for nu_i in 1:ndims-1
        A += to_matrix(s.U[s.stable_indicies[1, nu_i, i]] *
                       s.U[s.stable_indicies[2, nu_i, i]] *
                       s.U[s.stable_indicies[3, nu_i, i]])
        A += to_matrix(s.U[s.stable_indicies[4, nu_i, i]] *
                       s.U[s.stable_indicies[5, nu_i, i]] *
                       s.U[s.stable_indicies[6, nu_i, i]])
    end
    return A
end

@inline real_of_mul(a::ComplexF64, b::ComplexF64)::Float64 = a.re * b.re - a.im * b.im

@inline function compute_action_diff(s::GluoDynamicsLattice, i::CartesianIndex{ndims + 1}, U_new::SU3)
    A = compute_stable(s, i)
    @inbounds U = to_matrix(s.U[i])
    U_new_matrix = to_matrix(U_new)
    # return -s.beta / s.N * real(tr((U_new_matrix - U) * A))
    U_diff = U_new_matrix - U
    @inbounds trace = (
        real_of_mul(U_diff[1, 1], A[1, 1]) + real_of_mul(U_diff[1, 2], A[2, 1]) + real_of_mul(U_diff[1, 3], A[3, 1]) +
        real_of_mul(U_diff[2, 1], A[1, 2]) + real_of_mul(U_diff[2, 2], A[2, 2]) + real_of_mul(U_diff[2, 3], A[3, 2]) +
        real_of_mul(U_diff[3, 1], A[1, 3]) + real_of_mul(U_diff[3, 2], A[2, 3]) + real_of_mul(U_diff[3, 3], A[3, 3])
    )
    return s.action_prefactor * trace
end

@inline function compute_action(s::GluoDynamicsLattice)
    unity = to_matrix(one(SU3))
    S_atomic = Threads.Atomic{Float64}(0.0)
    Threads.@threads for n in CartesianIndices(s.U[1, :, :, :, :])
        @inbounds for mu in 1:ndims
            for nu_i in 1:length(mu+1:ndims)
                @inbounds S_local = real(tr(
                    unity -
                    to_matrix(
                        s.U[s.plaquett_indicies[1, nu_i, mu, n]] *
                        s.U[s.plaquett_indicies[2, nu_i, mu, n]] *
                        s.U[s.plaquett_indicies[3, nu_i, mu, n]]' *
                        s.U[s.plaquett_indicies[4, nu_i, mu, n]]')
                ))
                Threads.atomic_add!(S_atomic, S_local)
            end
        end
    end
    S = S_atomic[]
    return s.action_prefactor * S
end

@inline function compute_action_diff_naive(s::GluoDynamicsLattice, i::CartesianIndex{ndims + 1}, U_new::SU3)
    S = compute_action(s)
    U = s.U[i]
    s.U[i] = U_new
    S_new = compute_action(s)
    s.U[i] = U
    return S - S_new
end

######################## observables ###########################
function generate_plaquett_indicies(N, Nt)
    @info "generating plaquett indicies"
    dims = (N, N, N, Nt)
    plaquett_indicies = Array{CartesianIndex{ndims + 1}}(undef, 4, ndims - 1, ndims, dims...) # 4 is the length of a plaquett
    Threads.@threads for n in CartesianIndices(dims)
        @inbounds for mu in 1:ndims
            for (nu_i, nu) in enumerate(mu+1:ndims)
                plaquett_indicies[1, nu_i, mu, n] = get_link_index(n, mu, [], dims)
                plaquett_indicies[2, nu_i, mu, n] = get_link_index(n, nu, [mu], dims)
                plaquett_indicies[3, nu_i, mu, n] = get_link_index(n, mu, [nu], dims)
                plaquett_indicies[4, nu_i, mu, n] = get_link_index(n, nu, [], dims)
            end
        end
    end
    return plaquett_indicies
end

function eval_plaquetts(s::GluoDynamicsLattice)
    @info "evaluating plaquetts"
    P_atomic = Threads.Atomic{Float64}(0.0)
    Threads.@threads for n in CartesianIndices(s.U[1, :, :, :, :])
        @inbounds for mu in 1:ndims
            for nu_i in 1:length(enumerate(mu+1:ndims))
                @inbounds P_local = real(tr(
                    s.U[s.plaquett_indicies[1, nu_i, mu, n]] *
                    s.U[s.plaquett_indicies[2, nu_i, mu, n]] *
                    s.U[s.plaquett_indicies[3, nu_i, mu, n]]' *
                    s.U[s.plaquett_indicies[4, nu_i, mu, n]]'
                ))
                Threads.atomic_add!(P_atomic, P_local)
            end
        end
    end
    P = P_atomic[]
    return P / (6 * s.N^3 * s.Nt) # normalization depends on ndims
end

Base.@kwdef mutable struct Polyakov
    # state for the evaluation of polyakov loops
    polyakov::Array{ComplexF64,ndims - 1}
    polyakov_corr::Vector{Vector{Float64}}
    # polyakov_corr_single::Vector{Float64}
    counts::Vector{Int}
end

function Polyakov(s::GluoDynamicsLattice)
    polyakov_corr_size = cld((ndims - 1) * (s.N - 1)^2, 2)
    return Polyakov(
        polyakov=Array{Float64}(undef, s.N, s.N, s.N),
        polyakov_corr=Vector{Float64}[],
        counts=zeros(Int, polyakov_corr_size),
    )
end

@inline eval_polyakov_loop(s, n) = tr(prod(@inbounds s.U[ndims, n, nt] for nt in 1:s.Nt))

@inline cyclic_dist_squared_1d(x1, x2, N) = min((x1 - x2)^2, (N - x1 + x2)^2, (N - x2 + x1)^2)

@inline function cyclic_dist_squared(n, m, N)
    @inbounds return (
        cyclic_dist_squared_1d(n[1], m[1], N) +
        cyclic_dist_squared_1d(n[2], m[2], N) +
        cyclic_dist_squared_1d(n[1], m[2], N)
    )
end

function update_polyakov_correlator!(s::GluoDynamicsLattice, o::Polyakov)
    @info "evaluating polyako loops"
    # eval each polyakov loop
    Threads.@threads for n in CartesianIndices((s.N, s.N, s.N))
        @inbounds o.polyakov[n] = eval_polyakov_loop(s, n)
    end
    # compute their correlator as a histogram
    # only the distance between the points matters bc of translation invariance
    fill!(o.counts, 0)
    push!(o.polyakov_corr, zeros(length(o.counts)))
    @inbounds for n in CartesianIndices(o.polyakov)
        for m in CartesianIndices(o.polyakov)
            d2 = cyclic_dist_squared(n, m, s.N)
            val = o.polyakov[n] * o.polyakov[m]'
            # if !isapprox(val, 0.0, atol=1e-10)
            #     @warn "imaginary part of polyakov loop correlator is $(imag(val))"
            # end
            o.polyakov_corr[end][d2] += real(val)
            o.counts[d2] += 1
        end
    end
    @inbounds for i in eachindex(o.counts)
        if o.counts[i] != 0
            o.polyakov_corr[end][i] /= o.counts[i]
        end
    end
end

############################ initialization ########################
# cold start = low temp = 1 on each link
cold_start(N, Nt) = ones(SU3, (ndims, N, N, N, Nt))

warm_start(rng, epsilon, N, Nt) = [random_su3_close_to_1(rng, epsilon) for _ in CartesianIndices((ndims, N, N, N, Nt))]

# generate mc steps
function generate_possible_mc_steps(rng, n, epsilon)
    choices_half = [random_su3_close_to_1(rng, epsilon) for _ in 1:n]
    inv_half = inv.(choices_half)
    return vcat(choices_half, inv_half)
end

function GluoDynamicsLattice(seed, N, Nt, nchoices, beta, reproject_every, new_choices_every, epsilon; use_cold_start=true)
    @info "building new lattice simulation $N^3*$Nt with seed $seed @ beta = $beta"
    rng = Xoshiro(seed)
    return GluoDynamicsLattice(
        Nt=Nt,
        N=N,
        step=0,
        U=use_cold_start ? cold_start(N, Nt) : warm_start(rng, epsilon, N, Nt),
        stable_indicies=generate_stable_indicies(N, Nt),
        beta=beta,
        action_prefactor=-beta / N,
        reproject_every=reproject_every,
        nchoices=nchoices,
        choices=generate_possible_mc_steps(rng, nchoices, epsilon),
        new_choices_every=new_choices_every,
        rng=rng,
        epsilon=epsilon,
        plaquett_indicies=generate_plaquett_indicies(N, Nt),
    )
end

function GluoDynamicsLattice(N::Int, Nt::Int, beta::Real)
    return GluoDynamicsLattice(8_5_1996, N, Nt, 1000, beta, 100, 100, 0.01)
end

######################### mc algorithm ########################
@inline function mc_step_metropolis!(s::GluoDynamicsLattice, i::CartesianIndex{5})
    # metropolis for a first test
    # use a random step
    X = rand(s.choices)
    @inbounds U = s.U[i]
    U_new = X * U
    # compute action difference for acceptance propability
    Delta_S = compute_action_diff(s, i, U_new)
    # accept
    p = rand()
    if p <= exp(-Delta_S)
        @inbounds s.U[i] = U_new
    end
end

function mc_sweep_metropolis!(s::GluoDynamicsLattice)
    for n in CartesianIndices(s.U)
        mc_step_metropolis!(s, n)
    end
    s.step += 1
end

##################### the main mc loop #########################
const info_every_secs = 1

function advance!(s::GluoDynamicsLattice, nsteps)
    # last time we printed loop update (step) info
    last_info = time()
    # main mc loop
    for step in 1:nsteps
        now = time()
        if abs(last_info - now) > info_every_secs
            # use the step of this run, so we can watch the progress
            @info "step = $step / $nsteps, total_step = $(s.step)"
            # restart timer for step printing
            last_info = now
        end
        # here we use the total step (for reproducablity)
        # make sure that the su3 field stays in su3
        if s.step % s.reproject_every == 0
            map!(reproject_su3, s.U, s.U)
        end
        # here we use the total step (for reproducablity)
        # new possible mc steps
        if s.step % s.new_choices_every == 0
            s.choices = generate_possible_mc_steps(s.rng, s.nchoices, s.epsilon)
        end
        # apply one mc sweep (touch all lattcie sides/links)
        mc_sweep_metropolis!(s)
    end
end

function equilibrate!(s::GluoDynamicsLattice, plaquetts, nsteps, discard)
    for i in 1:nsteps
        @info "step $i / $nsteps"
        advance!(s, discard + 1)
        push!(plaquetts, eval_plaquetts(s))
    end
end

function run_simple_simulation!(s::GluoDynamicsLattice;
    equilibrating_steps=50, discarded_updates=1, nsamples=200, fileprefix="",
)
    @info "running simulation"

    @info "equilibrating for $equilibrating_steps steps"
    advance!(s, equilibrating_steps)

    @info "collecting data"
    poly = Polyakov(s)
    plaquetts = Float64[]
    for nth_sample in 1:nsamples
        # discard step inbetween observable evaluations
        @info "collecting sample $nth_sample / $nsamples"
        advance!(s, discarded_updates + 1)

        # observables
        @info "evaluating observables"
        push!(plaquetts, eval_plaquetts(s))
        update_polyakov_correlator!(s, poly)
    end
    @info "done running simulation"

    filename_polyakov="$(fileprefix)polyakov_loops$(s.beta).jld"
    filename_plaquetts="$(fileprefix)plaquetts$(s.beta).jld"
    filename_simulation="$(fileprefix)simulation$(s.beta).jld"
    @info "saving dataseries of plaquetts in $filename_plaquetts"
    save_object(filename_plaquetts, plaquetts)
    @info "saving dataseries of polyakov loops in $filename_polyakov"
    save_object(filename_polyakov, poly.polyakov_corr)
    # saving the final simulation state for restarts
    @info "saving simulation state to $filename_simulation"
    save_object(filename_simulation, s)
end

function test()
    @testset verbose = true "gluodynamics" begin
        @testset "su3" begin
            epsilon = 1e-15
            unit = one(SU3)
            @test unit * unit == unit

            u = reproject_su3(from_matrix(rand(3, 3) + rand(3, 3) * im))
            v = reproject_su3(from_matrix(rand(3, 3) + rand(3, 3) * im))

            @test isapprox(dot(get_last_row(u), u.u), 0.0, atol=epsilon)
            @test isapprox(dot(get_last_row(u), u.v), 0.0, atol=epsilon)
            @test isapprox(norm(get_last_row(u)), 1.0, atol=epsilon)
            @test isapprox(get_last_row(u), [get_last_row_1(u), get_last_row_2(u), get_last_row_3(u)], atol=epsilon)

            @test isapprox(to_matrix(unit * u), to_matrix(u), atol=epsilon)
            @test isapprox(to_matrix(u * unit), to_matrix(u), atol=epsilon)

            @test isapprox(to_matrix(u * u'), to_matrix(unit), atol=epsilon)
            @test isapprox(to_matrix(u) * to_matrix(v), to_matrix(u * v), atol=epsilon)
        end

        @testset "action" begin
            beta = 1.0
            i = CartesianIndex(1, 1, 1, 1, 1)
            U_new = random_su3_close_to_1(Random.default_rng(), 0.1)

            s = GluoDynamicsLattice(8_5_1996, 12, 12, 1000, beta, 100, 100, 0.01)
            delta_s1 = compute_action_diff(s, i, U_new)
            delta_s2 = compute_action_diff_naive(s, i, U_new)
            @test isapprox(delta_s1, delta_s2)

            s = GluoDynamicsLattice(8_5_1996, 12, 12, 1000, beta, 100, 100, 0.01; use_cold_start=false)
            delta_s1 = compute_action_diff(s, i, U_new)
            delta_s2 = compute_action_diff_naive(s, i, U_new)
            @test isapprox(delta_s1, delta_s2, rtol=1e-3)
        end
    end
    return nothing
end

end # module GluoDynamics

using JLD2
using PyPlot
using LsqFit

function main(run=false)

    beta = 1.0
    N = Nt = 10
    if run
        GluoDynamics.run_simple_simulation!(GluoDynamics.GluoDynamicsLattice(N, Nt, beta); equilibrating_steps=6000)
    end

    plaq = Float64[]
    s  = GluoDynamics.GluoDynamicsLattice(N, Nt, beta);
    GluoDynamics.converge!(s, plaq, 100, 10)
    plot(plaq)

    # analysis
    plaq = load_object("plaquetts$beta.jld")

    polyakov = load_object("polyakov_loops$beta.jld")
    d2 = collect(1:length(polyakov[1]))
    for p in polyakov
        plot(log.(abs.(p[p.!=0.0])), ".k")
    end
end
