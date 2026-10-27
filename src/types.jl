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

@enum Phase begin
    BROKEN = 0
    FRONTEND = 1
    BACKEND = 2
    SIMULATE = 3
    VALIDATE = 4
    UNKNOWN = 5
end

const PHASE_NAMES = Dict(
    BROKEN => "broken",
    FRONTEND => "frontend",
    BACKEND => "backend",
    SIMULATE => "simulate",
    VALIDATE => "validate",
    UNKNOWN => "unknown"
)

const PHASE_FROM_STRING = Dict(v => k for (k, v) in PHASE_NAMES)

function phase_from_string(s::AbstractString)::Phase
    get(PHASE_FROM_STRING, lowercase(s), UNKNOWN)
end

struct PhaseResult
    phase::Phase
    success::Bool
    time_s::Float64
    error::Union{Nothing, String}
end

struct ModelSpec
    name::String
    key::String
    domain::String
    stopTime::Float64
    expected::Phase
    reference::Dict{String, Float64}
    atol::Float64
    reltol::Float64
    referenceFile::String
    signalMapping::Dict{String, String}
    issue::String
    skipPhases::Set{Phase}
    solver::String  # empty = use default; otherwise constructor name like "IDA" or "Rodas5"
    dtmax::Float64  # 0.0 = no upper bound; otherwise hard cap on integrator step size
    initAlg::String # empty = use solver default; otherwise name like "ShampineCollocationInit"
    # Solver tolerances passed to OM.simulate. Distinct from atol/reltol above which are
    # validation tolerances for trajectory comparison. 0.0 = use SciML default.
    solverAtol::Float64
    solverReltol::Float64
    # OMBackend observedFilter regex patterns. Non-empty: passed to OM.translate and OM.simulate
    # (the translation's observed equations and alias observations: those the patterns match and
    # what they, the system and the events read). Empty = no filter.
    observedFilter::Vector{String}
    # Hard cap on integrator iterations, passed to OM.simulate as `maxiters`. 0.0 = use
    # the SciML default (1e5). A bounded value (e.g. 50000) lets a stiff / chattering
    # model bail with a clean MaxIters in a few minutes instead of grinding all the way
    # to the wall-clock watchdog SIGKILL.
    maxiters::Float64
    # The experiment's StartTime: simulated and compared from there (MSL ForceStrokeBehaviour: -4).
    startTime::Float64
end

# Convenience: shorter-arg constructors with empty/default trailing fields. Lets older callsites
# keep working without long argument lists.
ModelSpec(name::AbstractString, key::AbstractString, domain::AbstractString,
          stopTime::Float64, expected::Phase, reference::Dict{String, Float64},
          atol::Float64, reltol::Float64, referenceFile::AbstractString,
          signalMapping::Dict{String, String}, issue::AbstractString,
          skipPhases::Set{Phase}) =
    ModelSpec(String(name), String(key), String(domain), stopTime, expected,
              reference, atol, reltol, String(referenceFile), signalMapping,
              String(issue), skipPhases, "", 0.0, "", 0.0, 0.0)
ModelSpec(name::AbstractString, key::AbstractString, domain::AbstractString,
          stopTime::Float64, expected::Phase, reference::Dict{String, Float64},
          atol::Float64, reltol::Float64, referenceFile::AbstractString,
          signalMapping::Dict{String, String}, issue::AbstractString,
          skipPhases::Set{Phase}, solver::AbstractString) =
    ModelSpec(String(name), String(key), String(domain), stopTime, expected,
              reference, atol, reltol, String(referenceFile), signalMapping,
              String(issue), skipPhases, String(solver), 0.0, "", 0.0, 0.0)
ModelSpec(name::AbstractString, key::AbstractString, domain::AbstractString,
          stopTime::Float64, expected::Phase, reference::Dict{String, Float64},
          atol::Float64, reltol::Float64, referenceFile::AbstractString,
          signalMapping::Dict{String, String}, issue::AbstractString,
          skipPhases::Set{Phase}, solver::AbstractString, dtmax::Float64) =
    ModelSpec(String(name), String(key), String(domain), stopTime, expected,
              reference, atol, reltol, String(referenceFile), signalMapping,
              String(issue), skipPhases, String(solver), dtmax, "", 0.0, 0.0)
ModelSpec(name::AbstractString, key::AbstractString, domain::AbstractString,
          stopTime::Float64, expected::Phase, reference::Dict{String, Float64},
          atol::Float64, reltol::Float64, referenceFile::AbstractString,
          signalMapping::Dict{String, String}, issue::AbstractString,
          skipPhases::Set{Phase}, solver::AbstractString, dtmax::Float64,
          initAlg::AbstractString) =
    ModelSpec(String(name), String(key), String(domain), stopTime, expected,
              reference, atol, reltol, String(referenceFile), signalMapping,
              String(issue), skipPhases, String(solver), dtmax, String(initAlg),
              0.0, 0.0)
# Full positional through solverReltol (no observedFilter) -> defaults to empty.
ModelSpec(name::AbstractString, key::AbstractString, domain::AbstractString,
          stopTime::Float64, expected::Phase, reference::Dict{String, Float64},
          atol::Float64, reltol::Float64, referenceFile::AbstractString,
          signalMapping::Dict{String, String}, issue::AbstractString,
          skipPhases::Set{Phase}, solver::AbstractString, dtmax::Float64,
          initAlg::AbstractString, solverAtol::Float64, solverReltol::Float64) =
    ModelSpec(String(name), String(key), String(domain), stopTime, expected,
              reference, atol, reltol, String(referenceFile), signalMapping,
              String(issue), skipPhases, String(solver), dtmax, String(initAlg),
              solverAtol, solverReltol, String[], 0.0, 0.0)
# Full positional through maxiters (no startTime) -> starts at 0.
ModelSpec(name::String, key::String, domain::String, stopTime::Float64, expected::Phase,
          reference::Dict{String, Float64}, atol::Float64, reltol::Float64, referenceFile::String,
          signalMapping::Dict{String, String}, issue::String, skipPhases::Set{Phase}, solver::String,
          dtmax::Float64, initAlg::String, solverAtol::Float64, solverReltol::Float64,
          observedFilter::Vector{String}, maxiters::Float64) =
    ModelSpec(name, key, domain, stopTime, expected, reference, atol, reltol, referenceFile, signalMapping,
              issue, skipPhases, solver, dtmax, initAlg, solverAtol, solverReltol, observedFilter, maxiters, 0.0)

"""
    SignalComparison

Result of comparing one signal against its reference as OpenModelica's library testing does
(`compare_signal`, `tube_compare`): at `n_compared` times of the reference, `n_events` of them at its events
(not compared), OM.jl's value must lie in a band around the reference; `n_outside` do not. `worst_time`,
`worst_actual` and `worst_expected` are where OM.jl is furthest outside it and the two values there (NaN when
inside everywhere); `max_abs_err` and `max_rel_err` the largest difference from the reference at the
compared times.

For plotting, the values at the evenly spaced `times`: `expected` (the reference), `actual` (OM.jl's; NaN
after a time where the comparison stopped: the signal is not in the solution, or a value is not finite) and
the band, `low` and `high` (empty when the comparison stopped before it).
"""
struct SignalComparison
    name::String
    passed::Bool
    max_abs_err::Float64
    max_rel_err::Float64
    worst_time::Float64
    worst_actual::Float64
    worst_expected::Float64
    times::Vector{Float64}
    expected::Vector{Float64}
    actual::Vector{Float64}
    low::Vector{Float64}
    high::Vector{Float64}
    n_compared::Int
    n_events::Int
    n_outside::Int
end

SignalComparison(name::String, passed::Bool, max_abs_err::Float64, max_rel_err::Float64,
                 worst_time::Float64, worst_actual::Float64, worst_expected::Float64) =
    SignalComparison(name, passed, max_abs_err, max_rel_err, worst_time, worst_actual, worst_expected,
                     Float64[], Float64[], Float64[])

SignalComparison(name::String, passed::Bool, max_abs_err::Float64, max_rel_err::Float64,
                 worst_time::Float64, worst_actual::Float64, worst_expected::Float64,
                 times::Vector{Float64}, expected::Vector{Float64}, actual::Vector{Float64}) =
    SignalComparison(name, passed, max_abs_err, max_rel_err, worst_time, worst_actual, worst_expected,
                     times, expected, actual, Float64[], Float64[], 0, 0, 0)

"""
    ModelResult

A model's run: its phases' results, the highest phase it passed, when, and the signals its validation
compared (`signals`, empty when it did not get to comparing them).
"""
struct ModelResult
    spec::ModelSpec
    phases::Vector{PhaseResult}
    highest::Phase
    timestamp::String
    signals::Vector{SignalComparison}
end

ModelResult(spec::ModelSpec, phases::Vector{PhaseResult}, highest::Phase, timestamp::String) =
    ModelResult(spec, phases, highest, timestamp, SignalComparison[])

function status_symbol(result::ModelResult)
    if result.spec.expected == BROKEN
        return "yellow"
    elseif result.highest >= result.spec.expected && result.spec.expected != UNKNOWN
        return "green"
    else
        return "red"
    end
end
