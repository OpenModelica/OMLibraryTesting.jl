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
    discover_experiments(; library, version, omc_path, filter) -> Vector{ModelSpec}

Use omc to enumerate all experiment models in a Modelica library.
Returns a ModelSpec for each model with stopTime from the experiment annotation.
"""
function discover_experiments(; library::String = "Modelica",
                                version::String = "3.2.3",
                                omc_path::String = "omc",
                                filter::Regex = r"")::Vector{ModelSpec}
    script = """
    loadModel($library, {"$version"});
    names := getClassNames($library, recursive=true, qualified=true);
    for n in names loop
      if isExperiment(n) then
        (startTime, stopTime, tolerance, numberOfIntervals, interval) := getSimulationOptions(n);
        print(typeNameString(n) + "|" + String(stopTime) + "|" + String(tolerance) + "\\n");
      end if;
    end for;
    """
    script_path = tempname() * ".mos"
    write(script_path, script)
    output = try
        read(`$omc_path $script_path`, String)
    finally
        rm(script_path, force = true)
    end
    specs = ModelSpec[]
    for line in split(output, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, library * ".") || continue
        parts = split(stripped, '|')
        length(parts) >= 2 || continue
        name = String(parts[1])
        if !isempty(filter.pattern) && !occursin(filter, name)
            continue
        end
        stopTime = parse(Float64, parts[2])
        domain = _extract_domain(name)
        key = _name_to_key(name)
        push!(specs, ModelSpec(name, key, domain, stopTime,
                               UNKNOWN, Dict{String, Float64}(),
                               0.01, 3e-3, "", Dict{String, String}(), ""))
    end
    sort!(specs, by = s -> (s.domain, s.name))
    @info "Discovered $(length(specs)) experiment models in $library $version"
    return specs
end

"""
Extract domain from fully qualified name.
E.g., "Modelica.Mechanics.MultiBody.Examples.Elementary.Pendulum" -> "Mechanics.MultiBody"
"""
function _extract_domain(name::String)::String
    parts = split(name, '.')
    length(parts) < 3 && return ""
    # Skip "Modelica." prefix, take up to "Examples"
    domain_parts = String[]
    for i in 2:length(parts)
        parts[i] == "Examples" && break
        push!(domain_parts, parts[i])
    end
    return join(domain_parts, ".")
end

"""
Convert fully qualified name to a short key.
E.g., "Modelica.Mechanics.MultiBody.Examples.Elementary.Pendulum" -> "MultiBody_Elementary_Pendulum"
"""
function _name_to_key(name::String)::String
    parts = split(name, '.')
    # Find "Examples" and take everything after it, prefixed by the domain leaf
    examples_idx = findfirst(==("Examples"), parts)
    if isnothing(examples_idx) || examples_idx >= length(parts)
        return replace(name, "." => "_")
    end
    domain_leaf = examples_idx >= 3 ? parts[examples_idx - 1] : ""
    after = parts[examples_idx + 1:end]
    key_parts = isempty(domain_leaf) ? after : vcat([domain_leaf], after)
    return join(key_parts, "_")
end

"""
    merge_overrides!(specs, overrides_path) -> specs

Merge TOML overrides (expected phase, reference files, signal mappings,
known broken status) into discovered model specs.
"""
function merge_overrides!(specs::Vector{ModelSpec},
                           overrides_path::String)::Vector{ModelSpec}
    if !isfile(overrides_path)
        return specs
    end
    data = TOML.parsefile(overrides_path)
    overrides = get(data, "models", Dict())
    # Build a lookup by model name
    override_by_name = Dict{String, Any}()
    for (key, entry) in overrides
        if haskey(entry, "name")
            override_by_name[entry["name"]] = entry
        end
    end
    merged = ModelSpec[]
    for spec in specs
        if haskey(override_by_name, spec.name)
            entry = override_by_name[spec.name]
            expected = phase_from_string(get(entry, "expected", "unknown"))
            atol = Float64(get(entry, "atol", spec.atol))
            reltol = Float64(get(entry, "reltol", spec.reltol))
            referenceFile = get(entry, "referenceFile", "")::String
            issue = get(entry, "issue", "")::String
            stopTime = Float64(get(entry, "stopTime", spec.stopTime))
            sig_map = Dict{String, String}()
            if haskey(entry, "signalMapping")
                for (csv_name, omjl_name) in entry["signalMapping"]
                    sig_map[csv_name] = omjl_name
                end
            end
            ref_dict = Dict{String, Float64}()
            if haskey(entry, "reference")
                for (var, val) in entry["reference"]
                    ref_dict[var] = Float64(val)
                end
            end
            push!(merged, ModelSpec(spec.name, spec.key, spec.domain,
                                    stopTime, expected, ref_dict,
                                    atol, reltol, referenceFile,
                                    sig_map, issue))
        else
            push!(merged, spec)
        end
    end
    return merged
end
