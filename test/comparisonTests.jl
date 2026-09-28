#=
OMLibraryTesting comparison tests.

2026-04-23: An earlier attempt in this file added `step_hold_interpolate`
and `is_discrete_reference` helpers to `src/comparison.jl` and auto-routed
digital/enum signals through step-hold semantics inside `compare_signal`.
That was the wrong layer.

The symptom — Electrical.Digital flip-flop models (DFFREG*, DLATREG*,
DFFREGSR*) failing validate on signals like `dFFREG.dFFR.clock`,
`inertialDelaySensitive[i].x` — is caused by OMBackend not classifying
Modelica `Boolean` / `Integer` / 9-value-logic enum variables as
DISCRETE. Continuous integrators interpolate between event times, which
turns a legal Logic enum step (e.g. 3 → 1) into illegal intermediate
values (2). The reference CSV is already step-hold by construction (omc
emits at event times).

The fix belongs in OMBackend:
  - Classify `Boolean`, `Integer`, and single-module enum types as
    DISCRETE during BDAE -> SimCode -> MTK lowering (related to the
    architectural note in `.claude/CLAUDE.md`:
    "Friction FSM lowering produces rank-deficient Jacobian").
  - Emit these as MTK discrete variables / register a SaveCallback
    at event times so the SciML solution hands back step-hold values
    for `sol(t, idxs=discrete_var)`.
  - Once the backend emits step-hold values for digital signals,
    `interpolate_reference` here is correct as-is (both sides step
    piecewise-constant and Linear interpolation of (t0, v) to (t0+ε, v)
    is just v).

2026-09-27: a sample instant on an event the reference recorded (its
time repeated: the values before and after) accepts either value. A
solution evaluated at the event returns its left limit (SciML's default
continuity), the reference interpolation the right one.
=#

import OMLibraryTesting as OLT

#= A solution stand-in: `sol(t; idxs)` of one signal. =#
struct SignalOf{F}
    f::F
end
(s::SignalOf)(t; idxs = nothing) = s.f(t)

@testset "comparison: an event at a sample instant" begin
    #= A sawtooth reset at t = 0.5, as a Mean block's integrator: the
       reference stores the value before and after the reset at 0.5. =#
    local ref = OLT.ReferenceData([0.0, 0.25, 0.5, 0.5, 0.75, 1.0],
                                  Dict("x" => [0.0, 0.25, 0.5, 0.0, 0.25, 0.5]))
    @test OLT._event_limits(ref.time, ref.signals["x"], 0.5) == (0.5, 0.0)
    @test OLT._event_limits(ref.time, ref.signals["x"], 0.25) === nothing
    local sawtooth(t) = t <= 0.5 ? t : t - 0.5          # the left limit at the reset
    local cmp = OLT.compare_signal(SignalOf(sawtooth), ref, "x", 1.0; npoints = 5)
    @test cmp.passed
    #= Neither limit: a reset that did not happen. =#
    local noReset = OLT.compare_signal(SignalOf(t -> t <= 0.5 ? t : t + 0.1), ref, "x", 1.0; npoints = 5)
    @test !noReset.passed
end

@testset "comparison: a stopTime past the reference's end" begin
    #= The reference covers the experiment, [0, StopTime]: a sample past its
       end would be compared with its last value, frozen (2026-09-29: Engine1b
       at 0.72 s against a reference that ends at its StopTime 0.5 s). =#
    mktempdir() do dir
        mkpath(joinpath(dir, "csv"))
        mkpath(joinpath(dir, "signals"))
        write(joinpath(dir, "csv", "M.csv"), "time,x\n0.0,0.0\n0.5,1.0\n")
        write(joinpath(dir, "signals", "M.txt"), "x\n")
        local spec(stop) = OLT.ModelSpec("M", "M", "Test", stop, OLT.VALIDATE, Dict{String, Float64}(),
                                         1e-4, 3e-3, "M", Dict{String, String}(), "", Set{OLT.Phase}())
        @test first(OLT.validate_against_reference(SignalOf(t -> 2t), spec(0.5), dir))
        @test_throws ErrorException OLT.validate_against_reference(SignalOf(t -> 2t), spec(0.72), dir)
    end
    #= Relative: a Spice3 reference spans 1e-7 s. =#
    @test OLT.stoptime_within_reference(1e-7, 1e-7)
    @test !OLT.stoptime_within_reference(1.01e-7, 1e-7)
    @test OLT.stoptime_within_reference(0.0, 0.0)
end
