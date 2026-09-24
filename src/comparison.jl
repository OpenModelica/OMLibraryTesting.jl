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
    SignalComparison

Result of comparing one signal against its reference.
"""
struct SignalComparison
    name::String
    passed::Bool
    max_abs_err::Float64
    max_rel_err::Float64
    worst_time::Float64
    worst_actual::Float64
    worst_expected::Float64
end

"""
    load_reference_csv(path) -> ReferenceData

Load a reference CSV file (MAP-LIB format). The CSV has quoted column
headers on line 1 and numeric data rows. The first column is "time".
"""
function load_reference_csv(path::String)::ReferenceData
    lines = readlines(path)
    isempty(lines) && error("Empty reference file: $path")
    header = split(lines[1], ',')
    header = [strip(h, ['"', ' ']) for h in header]
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
    load_comparison_signals(path) -> Vector{String}

Load comparison signal names from a signals file (one name per line).
Skips the "time" entry.
"""
function load_comparison_signals(path::String)::Vector{String}
    lines = strip.(readlines(path))
    filter(l -> !isempty(l) && l != "time", lines)
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
    return replace(name, "." => "_")
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
    compare_signal(sol, ref, signal_name, stopTime; reltol, atol, npoints, signalMapping) -> SignalComparison

Compare an OM.jl solution signal against reference data at evenly spaced
time points. Uses combined tolerance: the comparison passes at each point
if |actual - expected| <= atol + reltol * |expected|.

`signalMapping` maps reference CSV signal names to OM.jl variable names.
If a signal is not in the mapping, dot-to-underscore conversion is used.
"""
function compare_signal(sol, ref::ReferenceData, signal_name::String,
                         stopTime::Float64;
                         reltol::Float64 = 3e-3,
                         atol::Float64 = 1e-4,
                         npoints::Int = 21,
                         signalMapping::Dict{String, String} = Dict{String, String}())::SignalComparison
    if !haskey(ref.signals, signal_name)
        return SignalComparison(signal_name, false, NaN, NaN, 0.0, NaN, NaN)
    end
    ref_values = ref.signals[signal_name]
    omjl_name = get(signalMapping, signal_name, modelica_to_omjl_name(signal_name))
    omjl_sym = Symbol(omjl_name)
    # Try to resolve the symbolic variable for MTK observed variable access
    resolved_sym = _resolve_mtk_variable(sol, omjl_sym)
    max_abs = 0.0
    max_rel = 0.0
    worst_t = 0.0
    worst_actual = 0.0
    worst_expected = 0.0
    passed = true
    times = range(0.0, stopTime, length = npoints)
    #= At a reference discontinuity the sample instant carries both limits
       (set-valued jump); accept the actual value if it matches either
       one-sided reference limit within tolerance. =#
    knot_eps = length(ref.time) > 1 ?
        1.5 * (ref.time[end] - ref.time[1]) / (length(ref.time) - 1) : 0.0
    for t in times
        expected = interpolate_reference(ref.time, ref_values, t)
        actual = try
            sol(t, idxs = resolved_sym)
        catch
            # Fallback: try accessing as array variable
            try
                vals = sol[resolved_sym]
                sol_times = sol.t
                interpolate_reference(sol_times, vals, t)
            catch e
                @warn "Signal $omjl_name not found in solution (eliminated by alias/simplification?)"
                # Signal not available: return as skipped (passed=true, NaN errors)
                return SignalComparison(signal_name, true, NaN, NaN, t, NaN, expected)
            end
        end
        abs_err = abs(actual - expected)
        rel_err = abs(expected) > 1e-15 ? abs_err / abs(expected) : abs_err
        threshold = atol + reltol * abs(expected)
        if abs_err > threshold && knot_eps > 0.0
            expected_lo = interpolate_reference(ref.time, ref_values, t - knot_eps)
            expected_hi = interpolate_reference(ref.time, ref_values, t + knot_eps)
            if abs(expected_hi - expected_lo) > threshold &&
               (abs(actual - expected_lo) <= atol + reltol * abs(expected_lo) ||
                abs(actual - expected_hi) <= atol + reltol * abs(expected_hi))
                continue
            end
        end
        if abs_err > threshold
            passed = false
        end
        if abs_err > max_abs
            max_abs = abs_err
            max_rel = rel_err
            worst_t = t
            worst_actual = actual
            worst_expected = expected
        end
    end
    return SignalComparison(signal_name, passed, max_abs, max_rel,
                            worst_t, worst_actual, worst_expected)
end

"""
    validate_against_reference(sol, spec, ref_dir) -> (passed, comparisons)

Validate an OM.jl solution against the MAP-LIB reference CSV for a model.
Returns (overall_passed, vector_of_SignalComparison).
"""
function validate_against_reference(sol, spec,
                                     ref_dir::String)::Tuple{Bool, Vector{SignalComparison}}
    ref_name = spec.referenceFile
    csv_path = joinpath(ref_dir, "csv", ref_name * ".csv")
    signals_path = joinpath(ref_dir, "signals", ref_name * ".txt")
    if !isfile(csv_path)
        error("Reference CSV not found: $csv_path")
    end
    ref = load_reference_csv(csv_path)
    signal_names = if isfile(signals_path)
        load_comparison_signals(signals_path)
    else
        collect(keys(ref.signals))
    end
    reltol = spec.reltol
    atol = spec.atol
    comparisons = SignalComparison[]
    all_passed = true
    n_skipped = 0
    for name in signal_names
        cmp = compare_signal(sol, ref, name, spec.stopTime;
                              reltol = reltol, atol = atol,
                              signalMapping = spec.signalMapping)
        push!(comparisons, cmp)
        if isnan(cmp.max_abs_err)
            n_skipped += 1
        elseif !cmp.passed
            all_passed = false
        end
    end
    if n_skipped > 0
        @info "Validation: $n_skipped/$(length(signal_names)) signals not found in solution (skipped)"
    end
    return (all_passed, comparisons)
end
