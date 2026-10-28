#=
* This file is part of OpenModelica.
*
* Copyright (c) 1998-CurrentYear, Open Source Modelica Consortium (OSMC),
* c/o Linköpings universitet, Department of Computer and Information Science,
* SE-58183 Linköping, Sweden.
*
* All rights reserved.
*
* THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
* THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
* ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
* RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
* ACCORDING TO RECIPIENTS CHOICE.
*
* The OpenModelica software and the Open Source Modelica
* Consortium (OSMC) Public License (OSMC-PL) are obtained
* from OSMC, either from the above address,
* from the URLs: http:www.ida.liu.se/projects/OpenModelica or
* http:www.openmodelica.org, and in the OpenModelica distribution.
* GNU version 3 is obtained from: http:www.gnu.org/copyleft/gpl.html.
*
* This program is distributed WITHOUT ANY WARRANTY; without
* even the implied warranty of  MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
* IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
*
* See the full OSMC Public License conditions for more details.
*
*/ =#

"""
    ReferenceData

Holds reference trajectory data loaded from a CSV file.
- `time`: vector of time points
- `signals`: Dict mapping signal name (dot notation) to vector of values
"""
struct ReferenceData
    time::Vector{Float64}
    signals::Dict{String, Vector{Float64}}
end

"""
    load_reference_csv(path) -> ReferenceData

Load a reference CSV file (MAP-LIB format). The CSV has quoted column
headers on line 1 and numeric data rows. The first column is "time".
"""
function load_reference_csv(path::String)::ReferenceData
    lines = readlines(path)
    isempty(lines) && error("Empty reference file: $path")
    #= Quoted names may hold commas (MSL 4.1.0's `stack.cell[1, 1].cell.limIntegrator.y`):
       split outside quotes, or every later column was read under the wrong name. =#
    header = [strip(h, ['"', ' ']) for h in split_csv_header(lines[1])]
    ncols = length(header)
    nrows = length(lines) - 1
    data = zeros(Float64, nrows, ncols)
    for (i, line) in enumerate(lines[2:end])
        vals = split(line, ',')
        for (j, v) in enumerate(vals)
            data[i, j] = parse(Float64, strip(v, ['"', ' ', '\t', '\r']))
        end
    end
    time_vec = data[:, 1]
    signals = Dict{String, Vector{Float64}}()
    for j in 2:ncols
        signals[header[j]] = data[:, j]
    end
    return ReferenceData(time_vec, signals)
end

"""
    split_csv_header(line) -> Vector{String}

The fields of a CSV header line, split at the commas outside double quotes.
"""
function split_csv_header(line::AbstractString)::Vector{String}
    fields = String[]
    buf = IOBuffer()
    inquote = false
    for c in line
        if c == '"'
            inquote = !inquote
            print(buf, c)
        elseif c == ',' && !inquote
            push!(fields, String(take!(buf)))
        else
            print(buf, c)
        end
    end
    push!(fields, String(take!(buf)))
    return fields
end

#= The plotted samples of a signal (signals.json), evenly spaced over [0, stopTime]: 101 (a signal is
   compared at the reference's own times; until 2026-10-28 at these, and 21 put every sample of
   Blocks.Modulation's sine.y on a zero crossing). =#
const COMPARISON_POINTS = 101

#= Whether a stopTime lies within a reference that ends at `ref_end`, up to
   rounding (relative: some references span 1e-11 s). The MSL 4.1.0 references
   print 8 significant digits: 1e-8 ends at 9.9999999e-9 (DifferenceAmplifier),
   0.32 at 0.31999999 (SMPM_NoLoad). =#
stoptime_within_reference(stopTime::Real, ref_end::Real)::Bool =
    stopTime <= ref_end + 1e-7 * abs(ref_end)

"""
    load_comparison_signals(path) -> Vector{String}

Load comparison signal names from a signals file (one name per line).
Skips the "time" entry.
"""
function load_comparison_signals(path::String)::Vector{String}
    lines = strip.(readlines(path))
    #= `//` lines are comments (the MAP-LIB comparisonSignals of 16 MSL 4.1.0 models). =#
    filter(l -> !isempty(l) && l != "time" && !startswith(l, "//"), lines)
end

"""
    interpolate_reference(ref, t) -> Float64

Linear interpolation of a reference signal at time t.
Clamps to boundary values if t is outside the reference time range.
"""
function interpolate_reference(ref_time::Vector{Float64},
                                ref_values::Vector{Float64},
                                t::Float64)::Float64
    if t <= ref_time[1]
        return ref_values[1]
    end
    if t >= ref_time[end]
        return ref_values[end]
    end
    idx = searchsortedlast(ref_time, t)
    if idx >= length(ref_time)
        return ref_values[end]
    end
    t0, t1 = ref_time[idx], ref_time[idx + 1]
    v0, v1 = ref_values[idx], ref_values[idx + 1]
    frac = (t - t0) / (t1 - t0)
    return v0 + frac * (v1 - v0)
end

"""
    modelica_to_omjl_name(name) -> String

Convert Modelica dot-notation signal name to OM.jl underscore convention.
E.g., "revolute1.phi" -> "revolute1_phi", "C1.v" -> "C1_v"
"""
function modelica_to_omjl_name(name::String)::String
    #= OM.jl names a matrix element x[1][2] (scalarized): `x[1, 2]` from the reference. =#
    local n = replace(name, r"\[([^\]]*)\]" => m -> "[" * join(strip.(split(m[2:end-1], ',')), "][") * "]")
    return replace(n, "." => "_")
end

"""
    _resolve_mtk_variable(sol, sym) -> Symbol or MTK symbolic variable

Try to resolve a plain Symbol to an MTK symbolic variable that can be used
for solution indexing. First tries the plain symbol, then falls back to
looking up the variable in the ODESystem (handles observed/eliminated vars).
"""
function _resolve_mtk_variable(sol, sym::Symbol)
    # First check if plain symbol works
    try
        sol(0.0, idxs = sym)
        return sym
    catch
    end
    # Try to get the symbolic variable from the MTK system
    try
        sys = sol.prob.f.sys
        mtk_var = getproperty(sys, sym)
        # Verify it works
        sol(0.0, idxs = mtk_var)
        return mtk_var
    catch
    end
    # Return the original symbol as last resort
    return sym
end

"""
    compare_signal(sol, ref, signal_name, stopTime; startTime, npoints, signalMapping, refTime, refOffset) -> SignalComparison

Compare an OM.jl solution signal against its reference as OpenModelica's library testing does (omc's
`diffSimulationResults`, `tube_compare`): OM.jl's values at the reference's times up to `stopTime` must lie,
at each that is not a reference event, in a band around the reference 0.1 % of the time span wide in time
and 0.3 % of the value and of the signal's range high. So a switch or a steep edge may be off by up to
0.1 % of the span (10 s: 0.01 s), and a deviation between plotted samples is seen. omc interpolates its
result file onto the reference's times; OM.jl's values there come from the solution's interpolation.

A value that is not finite fails the signal (omc's band lets NaN pass: it compares as never outside it).
The result keeps the values and the band at `npoints` evenly spaced times for plotting.

The reference is compared over what OM.jl simulated, its rows in [startTime, stopTime] (`comparison_rows`):
omc extrapolates a result that ends before the reference, and a registry stopTime may stop early (MSL 4.1.0
HysteresisModelComparison: stopTime 1, reference to 14). `startTime` is the experiment's (ForceStrokeBehaviour:
-4).
`refTime` is those rows' times, the vector the band changes in place (`tube_compare`), and `refOffset` their
initial event rows counted before any change: `validate_against_reference` passes the same vector for all of
a model's signals, as omc's one call does.

`signalMapping` maps reference CSV signal names to OM.jl variable names.
If a signal is not in the mapping, dot-to-underscore conversion is used.
"""
function compare_signal(sol, ref::ReferenceData, signal_name::String,
                         stopTime::Float64;
                         startTime::Float64 = 0.0,
                         npoints::Int = 21,
                         signalMapping::Dict{String, String} = Dict{String, String}(),
                         refTime::Vector{Float64} = ref.time[comparison_rows(ref.time, startTime, stopTime)],
                         refOffset::Int = initial_event_rows(refTime))::SignalComparison
    if !haskey(ref.signals, signal_name)
        return SignalComparison(signal_name, false, NaN, NaN, NaN, NaN, NaN)
    end
    ref_values = ref.signals[signal_name]
    omjl_name = get(signalMapping, signal_name, modelica_to_omjl_name(signal_name))
    omjl_sym = Symbol(omjl_name)
    # Try to resolve the symbolic variable for MTK observed variable access
    resolved_sym = _resolve_mtk_variable(sol, omjl_sym)
    local sampleTimes::Vector{Float64} = collect(range(startTime, stopTime, length = npoints))
    local expectedValues::Vector{Float64} = [interpolate_reference(ref.time, ref_values, t) for t in sampleTimes]
    local actualValues::Vector{Float64} = fill(NaN, npoints)
    #= OM.jl's result: its values at the reference's times it simulated, as omc's result file is
       interpolated onto them. =#
    local rows::UnitRange{Int} = comparison_rows(ref.time, startTime, stopTime)
    local actualTime::Vector{Float64} = ref.time[rows]
    local m::Int = length(actualTime)
    local values::Vector = try
        _solution_values(sol, resolved_sym, vcat(actualTime, sampleTimes))
    catch e
        @warn "Signal $omjl_name not found in solution (eliminated by alias/simplification?)"
        #= Not in the solution: not compared (passed = false, NaN errors), which fails the
           validation (validate_against_reference). It passed, so a model validated on a
           subset of its signals; and a sample after a failed one discarded that failure. =#
        return SignalComparison(signal_name, false, NaN, NaN, sampleTimes[1], NaN, expectedValues[1],
                                sampleTimes, expectedValues, actualValues)
    end
    local finite(v)::Bool = v isa Real && isfinite(v)
    #= A non-finite value is a failure, at the first time it occurs; the plotted values up to it. =#
    local bad::Union{Nothing, Int} = findfirst(k -> !finite(values[k]), eachindex(values))
    local tBad::Float64 = Inf
    if bad !== nothing
        tBad = minimum(k -> k <= m ? actualTime[k] : sampleTimes[k - m], filter(k -> !finite(values[k]), eachindex(values)))
    end
    for i in 1:npoints
        local v = values[m + i]
        sampleTimes[i] <= tBad && v isa Real && (actualValues[i] = Float64(v))
    end
    if bad !== nothing
        local kBad::Int = something(findfirst(k -> !finite(values[k]) &&
                                              (k <= m ? actualTime[k] : sampleTimes[k - m]) == tBad, eachindex(values)), bad)
        local vBad = values[kBad]
        return SignalComparison(signal_name, false, Inf, Inf, tBad, vBad isa Real ? Float64(vBad) : NaN,
                                interpolate_reference(ref.time, ref_values, tBad), sampleTimes, expectedValues, actualValues)
    end
    local tube::TubeComparison = tube_compare(refTime, ref_values[rows], actualTime, Float64.(values[1:m]); refOffset)
    local n::Int = length(tube.time)
    max_abs = 0.0
    max_rel = 0.0
    local worst::Int = 0
    for i in 1:n
        isnan(tube.error[i]) && continue          # a reference event: not compared
        local d::Float64 = abs(tube.actual[i] - tube.reference[i])
        if d > max_abs
            max_abs = d
            max_rel = abs(tube.reference[i]) > 1e-15 ? d / abs(tube.reference[i]) : d
        end
        tube.error[i] > 0.0 && (worst == 0 || tube.error[i] > tube.error[worst]) && (worst = i)
    end
    #= The band at the plotted samples, on the reference's own times (the band moved an event's repeated
       times apart): at an event the value after it, as the plotted reference. =#
    local bandTime::Vector{Float64} = actualTime[1:n]
    local low::Vector{Float64} = [interpolate_reference(bandTime, tube.low, t) for t in sampleTimes]
    local high::Vector{Float64} = [interpolate_reference(bandTime, tube.high, t) for t in sampleTimes]
    return SignalComparison(signal_name, tube.passed, max_abs, max_rel,
                            worst == 0 ? NaN : tube.time[worst], worst == 0 ? NaN : tube.actual[worst],
                            worst == 0 ? NaN : tube.reference[worst],
                            sampleTimes, expectedValues, actualValues, low, high,
                            n, count(isnan, tube.error), count(>(0.0), tube.error))
end

"""
    comparison_rows(time, startTime, stopTime) -> UnitRange{Int}

The reference's rows a result simulated from `startTime` to `stopTime` is compared at: those in
[startTime, stopTime], all of them when fewer than two are (a reference too coarse for the interval).
"""
function comparison_rows(time::Vector{Float64}, startTime::Float64, stopTime::Float64)::UnitRange{Int}
    local rows::UnitRange{Int} = searchsortedfirst(time, startTime):searchsortedlast(time, stopTime)
    return length(rows) >= 2 ? rows : (1:length(time))
end

"""
    _solution_values(sol, sym, times) -> Vector

OM.jl's values of `sym` at `times`: the solution interpolated at all of them in one call (0.4 µs a time,
against 85-750 µs for a call per time: MSL 4.1.0 PolyphaseTwoLevel_RL, 2026-10-28), else
`_solution_value` at each. Throws when the solution has neither.
"""
function _solution_values(sol, sym, times::Vector{Float64})::Vector
    local all = try
        sol(times; idxs = sym)
    catch
        nothing
    end
    local values = all !== nothing && hasproperty(all, :u) ? all.u : all
    values isa AbstractVector && length(values) == length(times) && return collect(values)
    return [_solution_value(sol, sym, t) for t in times]
end

"""
    _solution_value(sol, sym, t) -> value

OM.jl's value of `sym` at `t`: the solution's interpolation, else (a variable it does not interpolate) its
saved values interpolated linearly. Throws when the solution has neither.
"""
function _solution_value(sol, sym, t::Float64)
    try
        return sol(t, idxs = sym)
    catch
        return interpolate_reference(sol.t, sol[sym], t)
    end
end

"""
    validate_against_reference(sol, spec, ref_dir) -> (passed, comparisons)

Validate an OM.jl solution against the MAP-LIB reference CSV for a model.
Returns (overall_passed, vector_of_SignalComparison).
"""
function validate_against_reference(sol, spec,
                                     ref_dir::String;
                                     terminatedAt::Union{Nothing, Float64} = nothing)::Tuple{Bool, Vector{SignalComparison}}
    ref_name = spec.referenceFile
    csv_path = joinpath(ref_dir, "csv", ref_name * ".csv")
    signals_path = joinpath(ref_dir, "signals", ref_name * ".txt")
    if !isfile(csv_path)
        error("Reference CSV not found: $csv_path")
    end
    ref = load_reference_csv(csv_path)
    #= The reference covers the experiment, [0, StopTime]: a sample past its
       end would be compared with its last value, frozen (interpolate_reference
       clamps). A registry stopTime past it is an error in the registry. =#
    #= A run that terminate()d before stopTime (MSL 4 RobotR3: the path planning ends it at
       1.498 s) is compared up to where its reference ends, which must be where it ended. =#
    local compareStop = spec.stopTime
    if terminatedAt !== nothing && terminatedAt < spec.stopTime
        abs(terminatedAt - ref.time[end]) <= 1e-6 * max(1.0, abs(ref.time[end])) ||
            error("terminated at $terminatedAt, the reference $ref_name ends at $(ref.time[end])")
        compareStop = min(terminatedAt, ref.time[end])
    end
    stoptime_within_reference(compareStop, ref.time[end]) ||
        error("stopTime $(compareStop) is past the end of reference $ref_name ($(ref.time[end]))")
    signal_names = if isfile(signals_path)
        load_comparison_signals(signals_path)
    else
        collect(keys(ref.signals))
    end
    #= A listed signal the reference does not have is an error of the reference data or of
       its reading (a header split inside a quoted name), not a pass. =#
    missing_ref = filter(n -> !haskey(ref.signals, n), signal_names)
    isempty(missing_ref) ||
        error("Reference $ref_name has no column for the listed signals: $(join(missing_ref, ", "))")
    comparisons = SignalComparison[]
    all_passed = true
    #= One reference time vector for all signals, in their order, as omc's diffSimulationResults reads the
       reference once per call (OpenModelica's library testing calls it with all of a model's signals): the
       band moves an event's repeated times apart in it, so a signal's verdict can depend on the ones before it
       (the 4.1.0 references with altered copies of themselves: up to 7 of 3979 signals, 2026-10-28). =#
    local sharedTime::Vector{Float64} = ref.time[comparison_rows(ref.time, spec.startTime, compareStop)]
    local refOffset::Int = initial_event_rows(sharedTime)
    n_skipped = 0
    for name in signal_names
        cmp = compare_signal(sol, ref, name, compareStop; startTime = spec.startTime,
                              npoints = COMPARISON_POINTS, signalMapping = spec.signalMapping,
                              refTime = sharedTime, refOffset = refOffset)
        push!(comparisons, cmp)
        isnan(cmp.max_abs_err) && (n_skipped += 1)
        cmp.passed || (all_passed = false)
    end
    #= Every listed signal is compared: one the solution lacks fails the validation (it was
       skipped, and a model validated on a subset: IdealGasH2O on 1 of 3 signals, MSL 4
       CCCV_Stack on 1 of 13). The harness keeps the reference signals observable
       (_reference_signal_filter). =#
    if n_skipped > 0
        @warn "Validation: $n_skipped/$(length(signal_names)) reference signals are not in the solution"
    end
    return (all_passed, comparisons)
end
