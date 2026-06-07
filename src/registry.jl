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

function default_models_path()
    joinpath(@__DIR__, "..", "models", "models.toml")
end

"""
    load_registry_meta(path) -> Dict{String, Any}

Read the `[meta]` section from a models TOML file.
"""
function load_registry_meta(path::String = default_models_path())::Dict{String, Any}
    data = TOML.parsefile(path)
    return get(data, "meta", Dict{String, Any}())
end

function load_models(path::String = default_models_path())::Vector{ModelSpec}
    data = TOML.parsefile(path)
    models_section = get(data, "models", Dict())
    specs = ModelSpec[]
    for (key, entry) in models_section
        name = entry["name"]::String
        domain = get(entry, "domain", "")::String
        stopTime = Float64(get(entry, "stopTime", 1.0))
        expected = phase_from_string(get(entry, "expected", "unknown"))
        atol = Float64(get(entry, "atol", 0.01))
        reltol = Float64(get(entry, "reltol", 3e-3))
        referenceFile = get(entry, "referenceFile", "")::String
        sig_map = Dict{String, String}()
        if haskey(entry, "signalMapping")
            for (csv_name, omjl_name) in entry["signalMapping"]
                sig_map[csv_name] = omjl_name
            end
        end
        issue = get(entry, "issue", "")::String
        ref_dict = Dict{String, Float64}()
        if haskey(entry, "reference")
            for (var, val) in entry["reference"]
                ref_dict[var] = Float64(val)
            end
        end
        skip = Set{Phase}()
        if haskey(entry, "skipPhases")
            for s in entry["skipPhases"]
                push!(skip, phase_from_string(s))
            end
        end
        solverName = haskey(entry, "solver") ? String(entry["solver"]) : ""
        dtmaxVal = haskey(entry, "dtmax") ? Float64(entry["dtmax"]) : 0.0
        initAlgName = haskey(entry, "initializealg") ? String(entry["initializealg"]) : ""
        solverAtolVal = haskey(entry, "solverAtol") ? Float64(entry["solverAtol"]) : 0.0
        solverReltolVal = haskey(entry, "solverReltol") ? Float64(entry["solverReltol"]) : 0.0
        observedFilterVal = haskey(entry, "observedFilter") ?
            String[String(s) for s in entry["observedFilter"]] : String[]
        maxitersVal = haskey(entry, "maxiters") ? Float64(entry["maxiters"]) : 0.0
        push!(specs, ModelSpec(name, key, domain, stopTime, expected,
                               ref_dict, atol, reltol, referenceFile,
                               sig_map, issue, skip, solverName, dtmaxVal,
                               initAlgName, solverAtolVal, solverReltolVal, observedFilterVal,
                               maxitersVal))
    end
    sort!(specs, by = s -> (s.domain, s.name))
    return specs
end

function load_models_by_domain(domain::String, path::String = default_models_path())
    all = load_models(path)
    filter(s -> s.domain == domain, all)
end

function list_domains(path::String = default_models_path())
    all = load_models(path)
    sort(unique(s.domain for s in all))
end
