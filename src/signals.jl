#= The signals a run's validations compared, OM.jl's values and the reference's, as JSON: next to a
   run's HTML report (generate_report) and on the coverage site (publish_site), for looking at how a
   model behaved. =#

"""
The number of a site version's latest runs that keep their `signals.json` (publish_site removes it
from the older ones).
"""
const SIGNAL_RUNS_KEPT = 5

"""
    signals_json(results) -> String

The signals the validations of `results` compared, as JSON, by model name:

```
{"models": {"<model>": {"validated": true, "atol": 1e-4, "reltol": 3e-3, "time": [t0, t1, n],
                        "signals": [{"name": "J1.w", "passed": true, "max_abs_err": ..., "max_rel_err": ...,
                                     "worst_time": ..., "worst_omjl": ..., "worst_reference": ...,
                                     "compared": 5051, "events": 20, "outside": 0,
                                     "reference": [...], "omjl": [...], "low": [...], "high": [...]}]}}}
```

`time` is the comparison's `n` evenly spaced times from `t0` to `t1` (a signal compared at other times
has its own `time`); `reference` and `omjl` are the values there, 6 significant digits, `null` where
there is none (OM.jl's after the comparison stopped: the signal is not in the solution, or a value is
not finite); `low` and `high` the band OM.jl's values must lie in there (left out when the comparison
stopped before it). The signal was compared as OpenModelica's library testing does (`compare_signal`) at
`compared` times of the reference, `events` of them at its events (not compared), `outside` outside the
band: `worst_time` is where OM.jl is furthest outside it (`null` when inside everywhere), `worst_omjl` and
`worst_reference` the values there (left out without one). Models without compared signals are left out.
"""
function signals_json(results::Vector{ModelResult})::String
    local io = IOBuffer()
    print(io, "{\"models\":{")
    local first = true
    for r in sort(results; by = r -> r.spec.name)
        isempty(r.signals) && continue
        first || print(io, ",")
        first = false
        _model_signals_json(io, r)
    end
    print(io, "}}")
    return String(take!(io))
end

"""
    write_signals(path, results) -> Bool

Write `signals_json(results)` to `path` when a validation of `results` compared signals; whether it did.
"""
function write_signals(path::AbstractString, results::Vector{ModelResult})::Bool
    any(r -> !isempty(r.signals), results) || return false
    write(path, signals_json(results))
    return true
end

function _model_signals_json(io::IO, r::ModelResult)::Nothing
    local withTimes::Union{Nothing, Int} = findfirst(s -> !isempty(s.times), r.signals)
    local times::Vector{Float64} = withTimes === nothing ? Float64[] : r.signals[withTimes].times
    _json_string(io, r.spec.name)
    print(io, ":{\"validated\":", r.highest >= VALIDATE, ",\"atol\":")
    _json_number(io, r.spec.atol)
    print(io, ",\"reltol\":")
    _json_number(io, r.spec.reltol)
    print(io, ",\"time\":")
    _json_times(io, times)
    print(io, ",\"signals\":[")
    for (i, s) in enumerate(r.signals)
        i > 1 && print(io, ",")
        print(io, "{\"name\":")
        _json_string(io, s.name)
        print(io, ",\"passed\":", s.passed, ",\"max_abs_err\":")
        _json_number(io, s.max_abs_err)
        print(io, ",\"max_rel_err\":")
        _json_number(io, s.max_rel_err)
        print(io, ",\"worst_time\":")
        _json_number(io, s.worst_time)
        if isfinite(s.worst_time)
            print(io, ",\"worst_omjl\":")
            _json_number(io, s.worst_actual)
            print(io, ",\"worst_reference\":")
            _json_number(io, s.worst_expected)
        end
        print(io, ",\"compared\":", s.n_compared, ",\"events\":", s.n_events, ",\"outside\":", s.n_outside)
        if !isempty(s.times) && s.times != times
            print(io, ",\"time\":")
            _json_times(io, s.times)
        end
        print(io, ",\"reference\":")
        _json_numbers(io, s.expected)
        print(io, ",\"omjl\":")
        _json_numbers(io, s.actual)
        if !isempty(s.low)
            print(io, ",\"low\":")
            _json_numbers(io, s.low)
            print(io, ",\"high\":")
            _json_numbers(io, s.high)
        end
        print(io, "}")
    end
    print(io, "]}")
    return nothing
end

#= Evenly spaced times (compare_signal's range) as [first, last, count]. =#
function _json_times(io::IO, times::Vector{Float64})::Nothing
    if isempty(times)
        print(io, "[]")
    else
        print(io, "[")
        _json_number(io, times[1])
        print(io, ",")
        _json_number(io, times[end])
        print(io, ",", length(times), "]")
    end
    return nothing
end

function _json_numbers(io::IO, xs::Vector{Float64})::Nothing
    print(io, "[")
    for (i, x) in enumerate(xs)
        i > 1 && print(io, ",")
        _json_number(io, x)
    end
    print(io, "]")
    return nothing
end

function _json_number(io::IO, x::Float64)::Nothing
    print(io, isfinite(x) ? string(round(x; sigdigits = 6)) : "null")
    return nothing
end

function _json_string(io::IO, s::AbstractString)::Nothing
    print(io, '"')
    for c in s
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '<'
            print(io, "\\u003c")    # safe inside an HTML <script> too
        elseif c < ' '
            print(io, "\\u", string(UInt16(c); base = 16, pad = 4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end
