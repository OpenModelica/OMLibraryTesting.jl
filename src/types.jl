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

struct ModelResult
    spec::ModelSpec
    phases::Vector{PhaseResult}
    highest::Phase
    timestamp::String
end

function status_symbol(result::ModelResult)
    if result.spec.expected == BROKEN
        return "yellow"
    elseif result.highest >= result.spec.expected && result.spec.expected != UNKNOWN
        return "green"
    else
        return "red"
    end
end
