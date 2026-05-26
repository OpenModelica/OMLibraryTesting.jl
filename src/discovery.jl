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
const _DISCOVERY_CACHE = Dict{Tuple{String, String}, Vector{ModelSpec}}()

"""
    clear_discovery_cache!()

Clear the cached discovery results, forcing the next `discover_experiments` call
to re-run omc.
"""
function clear_discovery_cache!()
    empty!(_DISCOVERY_CACHE)
    @info "Discovery cache cleared"
end

function discover_experiments(; library::String = "Modelica",
                                version::String = "3.2.3",
                                omc_path::String = "omc",
                                filter::Regex = r"",
                                cache::Bool = true)::Vector{ModelSpec}
    cache_key = (library, version)
    if cache && haskey(_DISCOVERY_CACHE, cache_key)
        cached = _DISCOVERY_CACHE[cache_key]
        specs = if !isempty(filter.pattern)
            Base.filter(s -> occursin(filter, s.name), cached)
        else
            copy(cached)
        end
        @info "Using cached discovery: $(length(specs)) experiment models in $library $version"
        return specs
    end
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
    @info "Discovery: querying omc for experiment models in $library $version..."
    script_path = tempname() * ".mos"
    write(script_path, script)
    t0 = time()
    output = try
        withenv("LD_LIBRARY_PATH" => "") do
            read(`$omc_path $script_path`, String)
        end
    finally
        rm(script_path, force = true)
    end
    @info "Discovery: omc query completed in $(round(time() - t0, digits=1))s"
    specs = ModelSpec[]
    for line in split(output, '\n')
        stripped = strip(line)
        isempty(stripped) && continue
        startswith(stripped, library * ".") || continue
        parts = split(stripped, '|')
        length(parts) >= 2 || continue
        name = String(parts[1])
        stopTime = parse(Float64, parts[2])
        domain = _extract_domain(name)
        key = _name_to_key(name)
        push!(specs, ModelSpec(name, key, domain, stopTime,
                               UNKNOWN, Dict{String, Float64}(),
                               0.01, 3e-3, "", Dict{String, String}(), "",
                               Set{Phase}(), ""))
    end
    sort!(specs, by = s -> (s.domain, s.name))
    if cache
        _DISCOVERY_CACHE[cache_key] = specs
    end
    @info "Discovered $(length(specs)) experiment models in $library $version"
    if !isempty(filter.pattern)
        specs = Base.filter(s -> occursin(filter, s.name), specs)
    end
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
    domain_overrides = get(data, "domain_overrides", Dict())
    # Build a lookup by model name
    override_by_name = Dict{String, Any}()
    for (key, entry) in overrides
        if haskey(entry, "name")
            override_by_name[entry["name"]] = entry
        end
    end
    merged = ModelSpec[]
    for spec in specs
        # Start with domain-level overrides, then per-model overrides take precedence
        domain_entry = get(domain_overrides, spec.domain, nothing)
        entry = get(override_by_name, spec.name, nothing)

        if entry === nothing && domain_entry === nothing
            push!(merged, spec)
            continue
        end

        # Merge: domain defaults, then model-specific overrides on top
        effective = Dict{String, Any}()
        if domain_entry !== nothing
            merge!(effective, domain_entry)
        end
        if entry !== nothing
            merge!(effective, entry)
        end

        expected = phase_from_string(get(effective, "expected", "unknown"))
        atol = Float64(get(effective, "atol", spec.atol))
        reltol = Float64(get(effective, "reltol", spec.reltol))
        referenceFile = get(effective, "referenceFile", "")::String
        issue = get(effective, "issue", "")::String
        stopTime = Float64(get(effective, "stopTime", spec.stopTime))
        sig_map = Dict{String, String}()
        if haskey(effective, "signalMapping")
            for (csv_name, omjl_name) in effective["signalMapping"]
                sig_map[csv_name] = omjl_name
            end
        end
        ref_dict = Dict{String, Float64}()
        if haskey(effective, "reference")
            for (var, val) in effective["reference"]
                ref_dict[var] = Float64(val)
            end
        end
        skip = Set{Phase}()
        if haskey(effective, "skipPhases")
            for s in effective["skipPhases"]
                push!(skip, phase_from_string(s))
            end
        end
        local solverName = haskey(effective, "solver") ? String(effective["solver"]) : ""
        local dtmaxVal = haskey(effective, "dtmax") ? Float64(effective["dtmax"]) : 0.0
        local initAlgName = haskey(effective, "initializealg") ? String(effective["initializealg"]) : ""
        local solverAtolVal   = haskey(effective, "solverAtol")   ? Float64(effective["solverAtol"])   : 0.0
        local solverReltolVal = haskey(effective, "solverReltol") ? Float64(effective["solverReltol"]) : 0.0
        push!(merged, ModelSpec(spec.name, spec.key, spec.domain,
                                stopTime, expected, ref_dict,
                                atol, reltol, referenceFile,
                                sig_map, issue, skip, solverName, dtmaxVal, initAlgName,
                                solverAtolVal, solverReltolVal))
    end
    n_broken = count(s -> s.expected == BROKEN, merged)
    n_skipped = count(s -> !isempty(s.skipPhases), merged)
    n_overridden = count(s -> haskey(override_by_name, s.name), merged)
    n_domain = length(domain_overrides)
    @info "Overrides applied: $(n_overridden) per-model, $(n_domain) domain rules, $(n_broken) broken, $(n_skipped) with phase skips"
    return merged
end

"""
    _model_name_to_ref_key(name) -> String

Convert a qualified Modelica name to the reference file key.
E.g. "Modelica.Blocks.Examples.BusUsage" -> "Blocks_Examples_BusUsage"
"""
function _model_name_to_ref_key(name::String)::String
    # Strip "Modelica." prefix, replace dots with underscores
    stripped = replace(name, r"^Modelica\." => "")
    return replace(stripped, "." => "_")
end

"""
    auto_detect_references!(specs, ref_dir) -> specs

For models without an explicit referenceFile, check if a matching CSV
exists in the reference directory using the naming convention.
"""
function auto_detect_references!(specs::Vector{ModelSpec},
                                  ref_dir::String)::Vector{ModelSpec}
    csv_dir = joinpath(ref_dir, "csv")
    if !isdir(csv_dir)
        return specs
    end
    n_detected = 0
    result = ModelSpec[]
    for spec in specs
        if !isempty(spec.referenceFile)
            push!(result, spec)
            continue
        end
        ref_key = _model_name_to_ref_key(spec.name)
        csv_path = joinpath(csv_dir, ref_key * ".csv")
        if isfile(csv_path)
            n_detected += 1
            push!(result, ModelSpec(spec.name, spec.key, spec.domain,
                                     spec.stopTime, spec.expected, spec.reference,
                                     spec.atol, spec.reltol, ref_key,
                                     spec.signalMapping, spec.issue, spec.skipPhases,
                                     spec.solver, spec.dtmax))
        else
            push!(result, spec)
        end
    end
    if n_detected > 0
        @info "Auto-detected $n_detected reference files"
    end
    return result
end
