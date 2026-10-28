#= OpenModelica's comparison of a result against a reference: omc's diffSimulationResults, which
   OpenModelica's library testing (OpenModelicaLibraryTesting, testmodel.py) runs with relTol 3e-3,
   relTolDiffMinMax 3e-3 and rangeDelta 1e-3 (shared.py). A port of OMCompiler/Compiler/runtime/
   SimulationResultsCmpTubes.c (calculateTubes, generateHighTube, generateLowTube, calibrateValues,
   addRelativeTolerance, validate, cmpDataTubes) and the per-variable preparation of
   SimulationResultsCmp.c (SimulationResultsCmp_compareResults), OpenModelica v1.27.1. The counters keep
   omc's 0-based values (an array element is `a[k + 1]`), so the code can be read against the C line by
   line. Where clang contracts `a*b + c` into a fused multiply-add (its default, -ffp-contract=on: the 51
   llvm.fmuladd of the file's LLVM IR) the port calls `_ma`, so it computes as omc built by clang does
   (`fused = true`) or as a build without them (`fused = false`, an x86-64 build without FMA), bit for bit. =#

"""
OpenModelica's library testing settings for `diffSimulationResults` (OpenModelicaLibraryTesting `shared.py`):
the relative tolerance, the absolute one as a fraction of the reference signal's range (max - min), and the
tube's width in time as a fraction of the reference's time span.
"""
const TUBE_RELTOL = 3e-3
const TUBE_RELTOL_DIFF_MIN_MAX = 3e-3
const TUBE_RANGE_DELTA = 1e-3

"""
Whether `tube_compare` computes as omc built by clang (macOS; arm64 fuses `a*b + c` into one rounding), the
omc its verdicts were checked against (OpenModelica 1.27.1, 2026-10-28), or as a build without fused
multiply-adds (`false`: an x86-64 build without FMA). Julia's `fma` rounds once on every machine, so the
verdicts are the same everywhere.
"""
const TUBE_FUSED = true

"""`a*b + c` as omc's code computes it: one fused multiply-add where clang contracts it (`fused`), else two roundings."""
_ma(fused::Bool, a::Float64, b::Float64, c::Float64)::Float64 = fused ? fma(a, b, c) : a * b + c

"""
    TubeState

omc's `privates` of SimulationResultsCmpTubes.c: the upper and lower tube under construction (their corner
points `xHigh`/`yHigh`, `xLow`/`yLow`, the slopes `mh`/`ml` and the reference rows `i0h`/`i1h`, `i0l`/`i1l`
of each segment, 0-based as in omc), the reference's extent and whether it computes fused (`TUBE_FUSED`).
"""
mutable struct TubeState
    mh::Vector{Float64}
    ml::Vector{Float64}
    xHigh::Vector{Float64}
    xLow::Vector{Float64}
    yHigh::Vector{Float64}
    yLow::Vector{Float64}
    i0h::Vector{Int}
    i1h::Vector{Int}
    i0l::Vector{Int}
    i1l::Vector{Int}
    tStart::Float64
    tStop::Float64
    x1::Float64
    y1::Float64
    x2::Float64
    y2::Float64
    currentSlope::Float64
    slopeDif::Float64
    delta::Float64
    S::Float64
    xRelEps::Float64
    xMinStep::Float64
    min::Float64
    max::Float64
    countLow::Int
    countHigh::Int
    length::Int
    fused::Bool
end

TubeState(n::Int, fused::Bool) = TubeState(zeros(n), zeros(n), zeros(n), zeros(n), zeros(n), zeros(n),
                                           zeros(Int, n), zeros(Int, n), zeros(Int, n), zeros(Int, n),
                                           0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0, 0, n, fused)

"""
    TubeComparison

One signal compared as omc's diffSimulationResults does (`tube_compare`): `passed` when no compared time
lies outside the tube; at the reference's times `time` (the first `n` of them: omc stops where the result
ends), the reference's values, the result's (`actual`, interpolated onto those times), the tube (`low`,
`high`, tolerances included) and `error`, how far outside it the result is (0 inside, NaN at a reference
event: not compared).
"""
struct TubeComparison
    passed::Bool
    time::Vector{Float64}
    reference::Vector{Float64}
    actual::Vector{Float64}
    low::Vector{Float64}
    high::Vector{Float64}
    error::Vector{Float64}
end

"""C's `fmax`: the other argument when one is NaN."""
_fmax(a::Float64, b::Float64)::Float64 = isnan(a) ? b : isnan(b) ? a : max(a, b)

"""C's `fmin`: the other argument when one is NaN."""
_fmin(a::Float64, b::Float64)::Float64 = isnan(a) ? b : isnan(b) ? a : min(a, b)

"""omc's `almostEqualRelativeAndAbs` (SimulationResultsCmp.c)."""
function _almost_equal(a::Float64, b::Float64, reltol::Float64, abstol::Float64)::Bool
    local diff::Float64 = abs(a - b)
    diff <= abstol && return true
    return diff <= _fmax(abs(a), abs(b)) * reltol
end

"""omc's `generateHighTube`: the upper tube's corner where the segment just added meets the one before."""
function _generate_high_tube!(p::TubeState, x::Vector{Float64}, y::Vector{Float64})::Nothing
    local index::Int = p.countHigh - 1
    local m1::Float64 = p.mh[index + 1]
    local m2::Float64 = p.mh[index]
    local S::Float64 = p.S
    local f::Bool = p.fused
    p.slopeDif = abs(m1 - m2)
    if (p.slopeDif == 0) || ((p.slopeDif < 2e-15 * _fmax(abs(m1), abs(m2))) && (p.i0h[p.countHigh] - p.i1h[p.countHigh - 1] < 100))
        p.i0h[index] = p.i0h[index + 1]
        p.countHigh -= 1
        local x3::Float64 = x[p.i0h[index] + 1]
        local y3::Float64 = y[p.i0h[index] + 1]
        local x4::Float64 = x[p.i1h[index] + 1]
        local y4::Float64 = y[p.i1h[index] + 1]
        p.mh[index] = (y3 - y4) / (x3 - x4)
    else
        p.xHigh[index + 1] = p.x2 - (p.delta * (m1 + m2) / (sqrt(_ma(f, m2, m2, S * S)) + sqrt(_ma(f, m1, m1, S * S))))
        if m1 * m2 < 0
            p.yHigh[index + 1] = p.y2 + (p.delta * _ma(f, m1, sqrt(_ma(f, m2, m2, S * S)), -(m2 * sqrt(_ma(f, m1, m1, S * S))))) / (m1 - m2)
        else
            p.yHigh[index + 1] = p.y2 + (S * S * p.delta * (m1 + m2) / _ma(f, m1, sqrt(_ma(f, m2, m2, S * S)), m2 * sqrt(_ma(f, m1, m1, S * S))))
        end
        if (p.xHigh[index + 1] == p.xHigh[index]) && (p.yHigh[index + 1] != p.yHigh[index])
            p.xHigh[index + 1] = p.xHigh[index] + p.xMinStep
            p.yHigh[index + 1] = _ma(f, p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m1, p.xHigh[index + 1] - p.x2, p.y2))
            p.mh[index] = (p.yHigh[index + 1] - p.yHigh[index]) / p.xMinStep
        end
        #= The juncture before the last saved one: merge the two segments. =#
        while index > 1 && p.xHigh[index + 1] <= p.xHigh[index]
            p.i0h[index] = p.i0h[index + 1]
            p.i1h[index] = p.i1h[index + 1]
            p.mh[index] = p.mh[index + 1]
            index -= 1
            p.countHigh -= 1
            if index == 0
                p.xHigh[index + 1] = x[1] - p.delta
                p.yHigh[index + 1] = _ma(f, p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m1, p.xHigh[index + 1] - p.x2, p.y2))
            else
                local x3::Float64 = p.xHigh[index]
                local y3::Float64 = p.yHigh[index]
                m2 = p.mh[index]
                p.xHigh[index + 1] = _ma(f, p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m2, x3, -(m1 * p.x2)) + p.y2 - y3) / (m2 - m1)
                p.yHigh[index + 1] = _ma(f, -m1, y3, _ma(f, m2 * m1, x3 - p.x2, m2 * _ma(f, p.delta, sqrt(_ma(f, m1, m1, S * S)), p.y2))) / (m2 - m1)
            end
        end
    end
    return nothing
end

"""omc's `generateLowTube`: `_generate_high_tube!` for the lower tube."""
function _generate_low_tube!(p::TubeState, x::Vector{Float64}, y::Vector{Float64})::Nothing
    local index::Int = p.countLow - 1
    local m1::Float64 = p.ml[index + 1]
    local m2::Float64 = p.ml[index]
    local S::Float64 = p.S
    local f::Bool = p.fused
    p.slopeDif = abs(m1 - m2)
    if (p.slopeDif == 0) || ((p.slopeDif < 2e-15 * _fmax(abs(m1), abs(m2))) && (p.i0l[p.countLow] - p.i1l[p.countLow - 1] < 100))
        p.i0l[index] = p.i0l[index + 1]
        p.countLow -= 1
        local x3::Float64 = x[p.i0l[index] + 1]
        local y3::Float64 = y[p.i0l[index] + 1]
        local x4::Float64 = x[p.i1l[index] + 1]
        local y4::Float64 = y[p.i1l[index] + 1]
        p.ml[index] = (y3 - y4) / (x3 - x4)
    else
        p.xLow[index + 1] = p.x2 + (p.delta * (m1 + m2) / (sqrt(_ma(f, m2, m2, S * S)) + sqrt(_ma(f, m1, m1, S * S))))
        if m1 * m2 < 0
            p.yLow[index + 1] = p.y2 - (p.delta * _ma(f, m1, sqrt(_ma(f, m2, m2, S * S)), -(m2 * sqrt(_ma(f, m1, m1, S * S))))) / (m1 - m2)
        else
            p.yLow[index + 1] = p.y2 - (S * S * p.delta * (m1 + m2) / _ma(f, m1, sqrt(_ma(f, m2, m2, S * S)), m2 * sqrt(_ma(f, m1, m1, S * S))))
        end
        if (p.xLow[index + 1] == p.xLow[index]) && (p.yLow[index + 1] != p.yLow[index])
            p.xLow[index + 1] = p.xLow[index] + p.xMinStep
            p.yLow[index + 1] = _ma(f, -p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m1, p.xLow[index + 1] - p.x2, p.y2))
            p.ml[index] = (p.yLow[index + 1] - p.yLow[index]) / p.xMinStep
        end
        while index > 1 && p.xLow[index + 1] <= p.xLow[index]
            p.i0l[index] = p.i0l[index + 1]
            p.i1l[index] = p.i1l[index + 1]
            p.ml[index] = p.ml[index + 1]
            index -= 1
            p.countLow -= 1
            if index == 0
                p.xLow[index + 1] = x[1] - p.delta
                p.yLow[index + 1] = _ma(f, -p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m1, p.xLow[index + 1] - p.x2, p.y2))
            else
                local x3::Float64 = p.xLow[index]
                local y3::Float64 = p.yLow[index]
                m2 = p.ml[index]
                p.xLow[index + 1] = _ma(f, -p.delta, sqrt(_ma(f, m1, m1, S * S)), _ma(f, m2, x3, -(m1 * p.x2)) + p.y2 - y3) / (m2 - m1)
                p.yLow[index + 1] = _ma(f, -m1, y3, _ma(f, m2 * m1, x3 - p.x2, m2 * _ma(f, -p.delta, sqrt(_ma(f, m1, m1, S * S)), p.y2))) / (m2 - m1)
            end
        end
    end
    return nothing
end

"""
    _calculate_tubes!(x, y, r, fused) -> TubeState

omc's `calculateTubes`: the tubes around the reference `y` at the times `x`, `r` of its time span wide in
time, at least 4 r of its range high. Like omc it moves an event's repeated times apart in `x` by
`xMinStep` (1e-15 of the span), which the rest of the comparison sees.
"""
function _calculate_tubes!(x::Vector{Float64}, y::Vector{Float64}, r::Float64, fused::Bool = TUBE_FUSED)::TubeState
    local n::Int = length(x)
    n >= 2 || throw(ArgumentError("a tube needs at least two reference rows, got $n"))
    local p::TubeState = TubeState(n, fused)
    local f::Bool = fused
    p.tStart = x[1]
    p.tStop = x[n]
    p.xRelEps = 1e-15
    p.xMinStep = ((p.tStop - p.tStart) + abs(p.tStart)) * p.xRelEps
    p.delta = r * (p.tStop - p.tStart)
    p.max = y[1]
    p.min = y[1]
    for i in 1:(n - 1)
        p.max = _fmax(y[i + 1], p.max)
        p.min = _fmin(y[i + 1], p.min)
    end
    p.S = abs(4 * (p.max - p.min) / (abs(p.tStop - p.tStart)))
    if p.S < 0.0004 / abs(p.tStop - p.tStart)
        p.S = 0.0004 / abs(p.tStop - p.tStart)
    end
    local S::Float64 = p.S
    for i in 1:(n - 1)
        p.x1 = x[i + 1]
        p.y1 = y[i + 1]
        p.x2 = x[i]
        p.y2 = y[i]
        #= An event's repeated time. =#
        if (p.x1 <= p.x2) && (p.y1 == p.y2) && (p.countHigh == 0)
            continue
        end
        if (p.x1 <= p.x2) && (p.y1 == p.y2)
            p.x1 = _fmax(p.x1, x[p.i1l[p.countLow] + 1] + p.xMinStep)
            p.x1 = _fmax(p.x1, x[p.i1h[p.countHigh] + 1] + p.xMinStep)
            x[i + 1] = p.x1
            p.currentSlope = p.mh[p.countHigh]
        else
            if p.x1 <= p.x2
                p.x1 = p.x2 + p.xMinStep
                x[i + 1] = p.x1
            end
            p.currentSlope = (p.y1 - p.y2) / (p.x1 - p.x2)
        end
        p.i0h[p.countHigh + 1] = i
        p.i1h[p.countHigh + 1] = i - 1
        p.mh[p.countHigh + 1] = p.currentSlope
        p.i0l[p.countLow + 1] = i
        p.i1l[p.countLow + 1] = i - 1
        if (p.x1 <= p.x2) && (p.y1 == p.y2)
            p.currentSlope = p.ml[p.countLow]
        end
        p.ml[p.countLow + 1] = p.currentSlope
        if p.countHigh == 0
            p.xHigh[p.countHigh + 1] = p.x2 - p.delta
            p.yHigh[p.countHigh + 1] = _ma(f, p.delta, sqrt(_ma(f, p.currentSlope, p.currentSlope, S * S)), _ma(f, -p.currentSlope, p.delta, p.y2))
            p.xLow[p.countLow + 1] = p.x2 - p.delta
            p.yLow[p.countLow + 1] = _ma(f, -p.delta, sqrt(_ma(f, p.currentSlope, p.currentSlope, S * S)), _ma(f, -p.currentSlope, p.delta, p.y2))
            p.countHigh += 1
            p.countLow += 1
        else
            p.xHigh[p.countHigh + 1] = 1
            p.yHigh[p.countHigh + 1] = 1
            p.xLow[p.countLow + 1] = 1
            p.yLow[p.countLow + 1] = 1
            p.countHigh += 1
            p.countLow += 1
            _generate_high_tube!(p, x, y)
            _generate_low_tube!(p, x, y)
        end
    end
    #= The terminal values, delta past the end. =#
    p.x1 = p.xHigh[p.countHigh]
    p.y1 = p.yHigh[p.countHigh]
    p.x2 = p.tStop
    p.currentSlope = p.mh[p.countHigh]
    p.xHigh[p.countHigh + 1] = p.x2 + p.delta
    p.yHigh[p.countHigh + 1] = _ma(f, p.currentSlope, p.x2 + p.delta - p.x1, p.y1)
    p.countHigh += 1
    p.x1 = p.xLow[p.countLow]
    p.y1 = p.yLow[p.countLow]
    p.x2 = p.tStop
    p.currentSlope = p.ml[p.countLow]
    p.xLow[p.countLow + 1] = p.x2 + p.delta
    p.yLow[p.countLow + 1] = _ma(f, p.currentSlope, p.x2 + p.delta - p.x1, p.y1)
    p.countLow += 1
    return p
end

"""omc's `linearInterpolation`: the value at `x` between (x0, y0) and (x1, y1), times within `xabstol` equal."""
function _linear_interpolation(x::Float64, x0::Float64, x1::Float64, y0::Float64, y1::Float64, xabstol::Float64,
                               fused::Bool)::Float64
    if _almost_equal(x0, x, 0.0, xabstol)
        return y0
    elseif _almost_equal(x1, x, 0.0, xabstol)
        return y1
    elseif _almost_equal(x1, x0, 0.0, xabstol)
        return y0
    else
        return _ma(fused, (y1 - y0) / (x1 - x0), x - x0, y0)
    end
end

"""
    _calibrate_values(source, targetTime, targetValues, nsource, ntarget, xabstol, fused) -> (values, nsource)

omc's `calibrateValues`: the target's values interpolated onto the first `nsource` source times; at a
target event, after its left limit, the right one. Where the target ends before the source, the
sequence is cut: the second result is how many source times have a value.
"""
function _calibrate_values(source::Vector{Float64}, targetTime::Vector{Float64}, targetValues::Vector{Float64},
                           nsource::Int, ntarget::Int, xabstol::Float64, fused::Bool)::Tuple{Vector{Float64}, Int}
    local n::Int = nsource
    local values::Vector{Float64} = zeros(n)
    local nout::Int = n
    local j::Int = 1
    local x0::Float64 = NaN
    local x1::Float64 = NaN
    local y0::Float64 = NaN
    local y1::Float64 = NaN
    for i in 0:(n - 1)
        local x::Float64 = source[i + 1]
        #= Avoid extrapolation by cutting the sequence. =#
        if targetTime[j + 1] > source[n] && targetTime[j] > source[n]
            values[i + 1] = _linear_interpolation(x, x0, x1, y0, y1, xabstol, fused)
            nout = i + 1
            break
        end
        x1 = targetTime[j + 1]
        y1 = targetValues[j + 1]
        while (x1 <= x) && ((j + 1) < ntarget)
            j += 1
            x1 = targetTime[j + 1]
            y1 = targetValues[j + 1]
            _almost_equal(x1, x, 0.0, xabstol) && break
        end
        x0 = targetTime[j]
        y0 = targetValues[j]
        if i > 0 && _almost_equal(source[i], x0, 0.0, xabstol) && _almost_equal(x0, x1, 0.0, xabstol)
            values[i + 1] = y1          # the previous value was the event's left limit: the right one
        else
            values[i + 1] = _linear_interpolation(x, x0, x1, y0, y1, xabstol, fused)
        end
    end
    return (values, nout)
end

"""omc's `addRelativeTolerance`: widen the tube (`direction` +1 upper, -1 lower) to the reference +- the tolerance."""
function _add_relative_tolerance!(target::Vector{Float64}, source::Vector{Float64}, n::Int, reltol::Float64,
                                  abstol::Float64, direction::Int)::Nothing
    if direction > 0
        for i in 1:n
            target[i] = _fmax(source[i] + _fmax(abs(source[i] * reltol), abstol), target[i])
        end
    else
        for i in 1:n
            target[i] = _fmin(source[i] - _fmax(abs(source[i] * reltol), abstol), target[i])
        end
    end
    return nothing
end

"""
    _validate!(n, refTime, refValues, low, high, actual, reltol, abstol, xabstol) -> Union{Nothing, Vector{Float64}}

omc's `validate`: how far outside the tube the result is at each time, `nothing` when it is inside at all of
them. A reference event (a time repeated) is not compared (NaN); the tube there becomes a band 10 times the
tolerance around the reference, or around both values when the step before it was inside.
"""
function _validate!(n::Int, refTime::Vector{Float64}, refValues::Vector{Float64}, low::Vector{Float64},
                    high::Vector{Float64}, actual::Vector{Float64}, reltol::Float64, abstol::Float64,
                    xabstol::Float64)::Union{Nothing, Vector{Float64}}
    local error::Vector{Float64} = zeros(n)
    local isdifferent::Int = 0
    local lastStepError::Bool = true
    for i in 0:(n - 1)
        local thisStepError::Bool = false
        local isEvent::Bool = (i > 0 && _almost_equal(refTime[i + 1], refTime[i], 0.0, xabstol)) ||
                              (i + 1 < n && _almost_equal(refTime[i + 1], refTime[i + 2], 0.0, xabstol))
        if isEvent
            local refv::Float64 = refValues[i + 1]
            local val::Float64 = actual[i + 1]
            local tol::Float64 = _fmax(abstol * 10, _fmax(abs(refv), abs(val)) * reltol * 10)
            high[i + 1] = (lastStepError ? refv : _fmax(refv, val)) + tol
            low[i + 1] = (lastStepError ? refv : _fmin(refv, val)) - tol
            error[i + 1] = NaN
        else
            error[i + 1] = 0.0
            thisStepError = lastStepError
            if actual[i + 1] < low[i + 1]
                error[i + 1] = low[i + 1] - actual[i + 1]
                isdifferent += 1
                thisStepError = true
            elseif actual[i + 1] > high[i + 1]
                error[i + 1] = actual[i + 1] - high[i + 1]
                isdifferent += 1
                thisStepError = true
            end
        end
        lastStepError = thisStepError
    end
    return isdifferent > 0 ? error : nothing
end

"""
    initial_event_rows(time) -> Int

How many rows at the start share their time with the next (the initial event): omc's `offset` in
SimulationResultsCmp_compareResults, counted once per file before any comparison.
"""
function initial_event_rows(time::Vector{Float64})::Int
    local offset::Int = 0
    while offset < length(time) - 1 && time[offset + 1] == time[offset + 2]
        offset += 1
    end
    return offset
end

"""
    _first_values_after_initial_events!(values, offset)

omc's preparation of a variable ("adjust initial data points"): the first `offset` rows (the initial event's,
`initial_event_rows`) take the value of the row after them.
"""
function _first_values_after_initial_events!(values::Vector{Float64}, offset::Int)::Nothing
    for j in offset:-1:1
        values[j] = values[j + 1]
    end
    return nothing
end

"""
    tube_compare(refTime, refValues, actualTime, actualValues; reltol, reltolDiffMinMax, rangeDelta) -> TubeComparison

Compare one signal's result against its reference as omc's `diffSimulationResults` does (cmpDataTubes with
the variable's preparation): the result is interpolated onto the reference's times and must lie, at each of
them that is not a reference event, within a tube around the reference that is `rangeDelta` of the time
span wide in time (at least `4 rangeDelta` of the signal's range high), widened by `reltol` of the value and
`reltolDiffMinMax` of the signal's range. The defaults are OpenModelica's library testing settings; `fused`
whether to compute as omc built by clang (`TUBE_FUSED`).

`refTime` is changed in place as omc does (an event's repeated times moved apart by 1e-15 of the span). omc
reads the reference's times once per file, so in one `diffSimulationResults` call each signal after the first
sees the times the ones before it moved; to get omc's verdicts exactly, pass the same vector for the signals
of one reference, in its order, with `refOffset`/`actualOffset` counted before the first
(`initial_event_rows`).
"""
function tube_compare(refTime::Vector{Float64}, refValues::Vector{Float64}, actualTime::Vector{Float64},
                      actualValues::Vector{Float64};
                      reltol::Float64 = TUBE_RELTOL, reltolDiffMinMax::Float64 = TUBE_RELTOL_DIFF_MIN_MAX,
                      rangeDelta::Float64 = TUBE_RANGE_DELTA,
                      fused::Bool = TUBE_FUSED,
                      refOffset::Int = initial_event_rows(refTime),
                      actualOffset::Int = initial_event_rows(actualTime))::TubeComparison
    rangeDelta > 0.0 || throw(ArgumentError("rangeDelta must be positive (omc compares without tubes at 0)"))
    local ref::Vector{Float64} = copy(refValues)
    local act::Vector{Float64} = copy(actualValues)
    _first_values_after_initial_events!(act, actualOffset)
    _first_values_after_initial_events!(ref, refOffset)
    local xabstol::Float64 = (refTime[end] - refTime[1]) * 1e-3 / _fmax(Float64(length(actualTime)), Float64(length(refTime)))
    #= All the reference's rows at one time (a model with StopTime 0, MSL 4.1.0's
       SolveOneNonlinearEquation.Inverse_sine): each is an event, none is compared, the signal passes
       whatever its value. omc reads before its slope array building that tube (undefined); its verdict
       is always "passed" all the same (checked with omc 1.27.1, 2026-10-28). =#
    if refTime[end] == refTime[1]
        return TubeComparison(true, copy(refTime), ref, [i <= length(act) ? act[i] : NaN for i in eachindex(ref)],
                              copy(ref), copy(ref), fill(NaN, length(ref)))
    end
    local p::TubeState = _calculate_tubes!(refTime, ref, rangeDelta, fused)
    local (actual, n) = _calibrate_values(refTime, actualTime, act, length(refTime), length(actualTime), xabstol, fused)
    local (high, nh) = _calibrate_values(refTime, p.xHigh, p.yHigh, n, p.countHigh, xabstol, fused)
    local (low, nl) = _calibrate_values(refTime, p.xLow, p.yLow, nh, p.countLow, xabstol, fused)
    n = nl
    local abstol::Float64 = (p.max - p.min == 0 && p.max < reltolDiffMinMax * reltolDiffMinMax) ?
        reltolDiffMinMax * reltolDiffMinMax : abs((p.max - p.min) * reltolDiffMinMax)
    _add_relative_tolerance!(high, ref, n, reltol, abstol, 1)
    _add_relative_tolerance!(low, ref, n, reltol, abstol, -1)
    local error::Union{Nothing, Vector{Float64}} = _validate!(n, refTime, ref, low, high, actual, reltol, abstol, xabstol)
    return TubeComparison(error === nothing, refTime[1:n], ref[1:n], actual[1:n], low[1:n], high[1:n],
                          error === nothing ? [_almost_event(refTime, i, n, xabstol) ? NaN : 0.0 for i in 1:n] : error)
end

"""Whether the reference's `i`-th of `n` times is an event (a time repeated, within `xabstol`), as `_validate!` tells."""
_almost_event(t::Vector{Float64}, i::Int, n::Int, xabstol::Float64)::Bool =
    (i > 1 && _almost_equal(t[i], t[i - 1], 0.0, xabstol)) || (i < n && _almost_equal(t[i], t[i + 1], 0.0, xabstol))
