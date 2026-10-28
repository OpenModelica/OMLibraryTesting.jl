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

2026-10-28: a signal is compared as OpenModelica's library testing does
(omc's diffSimulationResults, ported as tube_compare): at every time of the
reference, in a band around it; a reference event is not compared.
=#

import OMLibraryTesting as OLT

#= A solution stand-in: `sol(t; idxs)` of one signal, one time per call (compare_signal falls back to
   that). =#
struct SignalOf{F}
    f::F
end
(s::SignalOf)(t::Real; idxs = nothing) = s.f(t)

#= A solution stand-in that takes all the times in one call, as SciML's (the values in `u`). =#
struct ManyAtOnce{F}
    f::F
end
(s::ManyAtOnce)(t::Real; idxs = nothing) = error("one time per call")
(s::ManyAtOnce)(ts::AbstractVector; idxs = nothing) = (u = s.f.(ts),)

@testset "comparison: an event at a sample instant" begin
    #= A sawtooth reset at t = 0.5, as a Mean block's integrator: the
       reference stores the value before and after the reset at 0.5. =#
    local ref = OLT.ReferenceData([0.0, 0.25, 0.5, 0.5, 0.75, 1.0],
                                  Dict("x" => [0.0, 0.25, 0.5, 0.0, 0.25, 0.5]))
    local sawtooth(t) = t <= 0.5 ? t : t - 0.5          # the left limit at the reset
    local cmp = OLT.compare_signal(SignalOf(sawtooth), ref, "x", 1.0; npoints = 5)
    @test cmp.passed
    #= Neither limit: a reset that did not happen. =#
    local noReset = OLT.compare_signal(SignalOf(t -> t <= 0.5 ? t : t + 0.1), ref, "x", 1.0; npoints = 5)
    @test !noReset.passed
    #= 2026-10-22: the reference files store their times as Float32, an event at 0.099 as 0.098999995 (MSL
       HBridge_RL's switching, 4.1.0): the event at the sample instant 0.099 all the same. =#
    local t32 = Float64(Float32(0.099))
    local stored = OLT.ReferenceData([0.0, 0.05, t32, t32, 0.1], Dict("x" => [0.0, 0.05, 0.099, -0.099, -0.1]))
    @test t32 < 0.099
    @test OLT.compare_signal(SignalOf(t -> t <= 0.099 ? t : -t), stored, "x", 0.1; npoints = 1001).passed
end

"""A pulse on from 0.2 to 0.6, rows every 0.01, its switches recorded (the time repeated: before, after)."""
function pulse_reference()::Tuple{Vector{Float64}, Vector{Float64}}
    local tp::Vector{Float64} = Float64[]
    local yp::Vector{Float64} = Float64[]
    for k in 0:100
        local t::Float64 = k / 100
        if k == 20
            append!(tp, [t, t]); append!(yp, [0.0, 1.0])
        elseif k == 60
            append!(tp, [t, t]); append!(yp, [1.0, 0.0])
        else
            push!(tp, t); push!(yp, 0.2 < t < 0.6 ? 1.0 : 0.0)
        end
    end
    return (tp, yp)
end

"""A pulse on from `on` to `off` at the times `t`, the left limit at a switch (as a solution evaluated there)."""
pulse_values(t::Vector{Float64}, on::Float64, off::Float64)::Vector{Float64} = [on < s <= off ? 1.0 : 0.0 for s in t]

"""The cases of "tube_compare: OpenModelica's verdicts": name => (reference time, values, result time, values)."""
function tube_cases()::Vector{Pair{String, NTuple{4, Vector{Float64}}}}
    local ts::Vector{Float64} = collect(range(0.0, 1.0, length = 501))
    local sine::Vector{Float64} = sin.(2pi .* ts)
    local (tp, yp) = pulse_reference()
    local tr::Vector{Float64} = collect(range(0.0, 2.0, length = 201))
    local spike::Vector{Float64} = copy(tr)
    spike[101] += 0.05
    return [
        "sine, same" => (ts, sine, ts, copy(sine)),
        "sine, 0.0004 late" => (ts, sine, ts, sin.(2pi .* (ts .- 0.0004))),
        "sine, 0.003 late" => (ts, sine, ts, sin.(2pi .* (ts .- 0.003))),
        "sine, 1.005 times" => (ts, sine, ts, 1.005 .* sine),
        "sine, 0.004 higher" => (ts, sine, ts, sine .+ 0.004),
        "sine, 0.02 higher" => (ts, sine, ts, sine .+ 0.02),
        "pulse, on time" => (tp, yp, tp, pulse_values(tp, 0.2, 0.6)),
        "pulse, 0.005 late" => (tp, yp, tp, pulse_values(tp, 0.205, 0.605)),
        "pulse, 0.015 late" => (tp, yp, tp, pulse_values(tp, 0.215, 0.615)),
        "pulse, on a coarser grid" => (tp, yp, tp[1:3:end], pulse_values(tp[1:3:end], 0.2, 0.6)),
        "ramp, a spike" => (tr, tr, tr, spike),
    ]
end

@testset "tube_compare: OpenModelica's verdicts (omc 1.27.1)" begin
    #= omc's diffSimulationResults on these cases (written as CSV), with OpenModelica's library testing
       settings, 2026-10-28 (REPORTS 2026-10-27-omlt-coverage-master-4.1.0, files/2026-10-28-omlt-tube-fixtures.*):
       its verdicts, and its band at a few rows of two failing ones (its diff file, 15 digits). =#
    local omcPassed::Vector{Bool} = [true, true, false, true, true, false, true, true, false, false, false]
    local cases = tube_cases()
    for ((name, (rt, ry, at, ay)), expected) in zip(cases, omcPassed)
        @test (name => OLT.tube_compare(copy(rt), ry, at, ay).passed) == (name => expected)
    end
    local (lt, ly, la, lv) = cases[3].second
    local late = OLT.tube_compare(copy(lt), ly, la, lv)
    @test late.high[2] ≈ 0.0227377591592959 rtol = 1e-13
    @test late.low[2] ≈ 0.00239370782096386 rtol = 1e-13
    @test late.high[167] ≈ 0.878749532730212 rtol = 1e-13
    @test late.low[167] ≈ 0.861593180979107 rtol = 1e-13
    local (rt, ry, ra, rv) = cases[11].second
    local ramp = OLT.tube_compare(copy(rt), ry, ra, rv)
    @test ramp.high[67] ≈ 0.668246211251235 rtol = 1e-13
    @test ramp.low[67] ≈ 0.651753788748765 rtol = 1e-13
    @test count(>(0.0), ramp.error) == 1 && ramp.time[argmax(ramp.error)] == 1.0
    #= Like omc, the band moves an event's repeated times apart (1e-15 of the span) in the times it is given. =#
    local (tp, yp) = pulse_reference()
    local moved::Vector{Float64} = copy(tp)
    OLT.tube_compare(moved, yp, tp, pulse_values(tp, 0.2, 0.6))
    @test moved != tp && maximum(abs.(moved .- tp)) <= 1e-14 && issorted(moved)
    #= omc's quirk: a reference with all its rows at one time (StopTime 0) compares nothing, any value passes. =#
    @test OLT.tube_compare([0.0, 0.0], [0.5236, 0.5236], [0.0, 0.0], [0.6, 0.6]).passed
end

@testset "comparison: as OpenModelica's library testing (MSL BooleanNetwork1)" begin
    #= Until 2026-10-28 a signal was compared at 101 plotted samples only: a switch up to a sample interval
       late passed (BooleanNetwork1: its switches on samples 0.1 apart), so did a dip between samples. Now at
       every reference time, in OpenModelica's band: 0.1 % of the span (here 0.001) wide in time. =#
    local (tp, yp) = pulse_reference()
    local ref = OLT.ReferenceData(tp, Dict("p" => yp))
    local pulse(on::Float64, off::Float64) = SignalOf(t -> on < t <= off ? 1.0 : 0.0)   # left limits
    local onTime = OLT.compare_signal(pulse(0.2, 0.6), ref, "p", 1.0; npoints = 11)
    @test onTime.passed && onTime.n_compared == 103 && onTime.n_events == 4 && onTime.n_outside == 0
    @test onTime.max_abs_err == 0.0 && isnan(onTime.worst_time)
    @test length(onTime.low) == 11 && all(onTime.low .<= onTime.expected .<= onTime.high)
    #= A switch late by less than the reference's row spacing shows at its event rows only: not compared. =#
    @test OLT.compare_signal(pulse(0.205, 0.605), ref, "p", 1.0; npoints = 11).passed
    local late = OLT.compare_signal(pulse(0.215, 0.615), ref, "p", 1.0; npoints = 11)
    @test !late.passed && late.n_outside == 2 && late.worst_time == 0.21
    @test late.worst_actual == 0.0 && late.worst_expected == 1.0
    local dip = OLT.compare_signal(SignalOf(t -> 0.2 < t <= 0.6 && !(0.425 < t < 0.445) ? 1.0 : 0.0), ref, "p", 1.0;
                                   npoints = 11)
    @test !dip.passed && dip.n_outside == 2 && 0.43 <= dip.worst_time <= 0.44
    @test dip.actual == onTime.actual    # the plotted samples do not show it
    #= All the times in one call, as a SciML solution: the same comparison. =#
    local many = OLT.compare_signal(ManyAtOnce(t -> 0.2 < t <= 0.6 ? 1.0 : 0.0), ref, "p", 1.0; npoints = 11)
    @test many.passed && many.n_events == 4 && many.actual == onTime.actual
    @test OLT._solution_values(ManyAtOnce(t -> 2t), :x, [0.0, 0.5]) == [0.0, 1.0]
    @test OLT._solution_values(SignalOf(t -> 2t), :x, [0.0, 0.5]) == [0.0, 1.0]
end

@testset "comparison: over what OM.jl simulated, [startTime, stopTime]" begin
    #= omc extrapolates a result that ends before its reference: the reference is cut to the rows OM.jl
       simulated (MSL 4.1.0 HysteresisModelComparison: stopTime 1, reference to 14; ForceStrokeBehaviour:
       StartTime -4, simulated from 0 until 2026-10-28). =#
    local t::Vector{Float64} = collect(-1.0:0.01:3.0)
    local ref = OLT.ReferenceData(t, Dict("x" => 2 .* t))
    @test OLT.comparison_rows(ref.time, 0.0, 1.0) == 101:201
    @test OLT.comparison_rows(ref.time, -1.0, 1.0) == 1:201
    @test OLT.comparison_rows([0.0, 2.0], 0.0, 1.0) == 1:2     # too coarse for the interval: all rows
    local simulated = SignalOf(s -> 0.0 <= s <= 1.0 ? 2s : 1e6)   # nothing outside [0, 1]
    local c = OLT.compare_signal(simulated, ref, "x", 1.0; npoints = 11)
    @test c.passed && c.n_compared == 101
    #= From the experiment's StartTime: compared and plotted from there. =#
    local fromStart = OLT.compare_signal(SignalOf(s -> s <= 1.0 ? 2s : 1e6), ref, "x", 1.0; startTime = -1.0, npoints = 11)
    @test fromStart.passed && fromStart.n_compared == 201 && fromStart.times[1] == -1.0
    mktempdir() do dir
        mkpath(joinpath(dir, "csv"))
        write(joinpath(dir, "csv", "M.csv"), "time,x\n" * join(["$(u),$(2u)" for u in t], "\n") * "\n")
        local spec = OLT.ModelSpec("M", "M", "Test", 1.0, OLT.VALIDATE, Dict{String, Float64}(), 1e-4, 3e-3, "M",
                                   Dict{String, String}(), "", Set{OLT.Phase}())
        @test first(OLT.validate_against_reference(simulated, spec, dir))
    end
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
    #= 8 significant digits in the MSL 4.1.0 references. =#
    @test OLT.stoptime_within_reference(1e-8, 9.9999999e-9)
    @test OLT.stoptime_within_reference(0.32, 0.31999999)
end

@testset "comparison: no reference signal in the solution" begin
    #= Every signal skipped (not in the solution): nothing was compared, so the
       model does not validate. One signal found is compared as usual. =#
    mktempdir() do dir
        mkpath(joinpath(dir, "csv"))
        mkpath(joinpath(dir, "signals"))
        write(joinpath(dir, "csv", "M.csv"), "time,x,y\n0.0,0.0,0.0\n0.5,1.0,1.0\n")
        write(joinpath(dir, "signals", "M.txt"), "x\ny\n")
        local spec = OLT.ModelSpec("M", "M", "Test", 0.5, OLT.VALIDATE, Dict{String, Float64}(),
                                   1e-4, 3e-3, "M", Dict{String, String}(), "", Set{OLT.Phase}())
        local absent = SignalOf(t -> error("not in the solution"))
        @test !first(OLT.validate_against_reference(absent, spec, dir))
        #= x found and right, y missing: every listed signal is compared, so not validated
           (it validated on x alone until 2026-10-13). =#
        local onlyX = (t; idxs = nothing) -> idxs === :x ? 2t : error("not in the solution")
        @test !first(OLT.validate_against_reference(onlyX, spec, dir))
        local both = (t; idxs = nothing) -> 2t
        @test first(OLT.validate_against_reference(both, spec, dir))
    end
end

@testset "comparison: what a validation must not let pass (audit 2026-10-13)" begin
    local ref = OLT.ReferenceData([0.0, 0.5, 1.0], Dict("x" => [0.0, 1.0, 2.0]))
    #= NaN was never above the threshold. =#
    @test !OLT.compare_signal(SignalOf(t -> NaN), ref, "x", 1.0; npoints = 5).passed
    @test !OLT.compare_signal(SignalOf(t -> t < 0.5 ? 2t : Inf), ref, "x", 1.0; npoints = 5).passed
    @test OLT.compare_signal(SignalOf(t -> 2t), ref, "x", 1.0; npoints = 5).passed
    #= A quoted name with a comma is one column (MSL 4.1.0's stack.cell[1, 1]...). =#
    @test OLT.split_csv_header("\"time\",\"a.b\",\"c[1, 2].d\",\"e\"") ==
          ["\"time\"", "\"a.b\"", "\"c[1, 2].d\"", "\"e\""]
    @test OLT.modelica_to_omjl_name("stack.cell[1, 2].y") == "stack_cell[1][2]_y"
    @test OLT.modelica_to_omjl_name("r.v[3]") == "r_v[3]"
    mktempdir() do dir
        mkpath(joinpath(dir, "csv"))
        mkpath(joinpath(dir, "signals"))
        write(joinpath(dir, "csv", "M.csv"), "\"time\",\"c[1, 2].d\",\"e\"\n0.0,0.0,5.0\n0.5,1.0,5.0\n")
        local r = OLT.load_reference_csv(joinpath(dir, "csv", "M.csv"))
        @test r.signals["c[1, 2].d"] == [0.0, 1.0] && r.signals["e"] == [5.0, 5.0]
        #= `//` lines of a comparisonSignals file are comments. =#
        write(joinpath(dir, "signals", "M.txt"), "time\n// a comment\nc[1, 2].d\ne\n")
        @test OLT.load_comparison_signals(joinpath(dir, "signals", "M.txt")) == ["c[1, 2].d", "e"]
        #= A listed signal without a column is an error of the reference, not a pass. =#
        write(joinpath(dir, "signals", "M.txt"), "c[1, 2].d\nf\n")
        local spec = OLT.ModelSpec("M", "M", "Test", 0.5, OLT.VALIDATE, Dict{String, Float64}(),
                                   1e-4, 3e-3, "M", Dict{String, String}(), "", Set{OLT.Phase}())
        @test_throws ErrorException OLT.validate_against_reference(SignalOf(t -> 2t), spec, dir)
    end
end

@testset "comparison: a run that terminate()d" begin
    #= Compared up to where it ended, which must be where its reference ends (MSL 4 RobotR3). =#
    mktempdir() do dir
        mkpath(joinpath(dir, "csv"))
        write(joinpath(dir, "csv", "M.csv"), "time,x\n0.0,0.0\n0.25,0.5\n0.5,1.0\n")
        local spec = OLT.ModelSpec("M", "M", "Test", 1.0, OLT.VALIDATE, Dict{String, Float64}(),
                                   1e-4, 3e-3, "M", Dict{String, String}(), "", Set{OLT.Phase}())
        local s = SignalOf(t -> 2t)
        @test_throws ErrorException OLT.validate_against_reference(s, spec, dir)
        @test first(OLT.validate_against_reference(s, spec, dir; terminatedAt = 0.5 + 1e-8))
        @test_throws ErrorException OLT.validate_against_reference(s, spec, dir; terminatedAt = 0.3)
    end
end
