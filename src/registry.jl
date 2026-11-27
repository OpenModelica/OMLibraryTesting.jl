#=
* This file is part of OpenModelica.
*
* Copyright (c) 1998-CurrentYear, Open Source Modelica Consortium (OSMC),
* c/o Linköpings universitet, Department of Computer and Information Science,
* SE-58183 Linköping, Sweden.
*
* All rights reserved.
*
* THIS PROGRAM IS PROVIDED UNDER THE TERMS OF AGPL VERSION 3 LICENSE OR
* THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.8.
* ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
* RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GNU AGPL
* VERSION 3, ACCORDING TO RECIPIENTS CHOICE.
*
* The OpenModelica software and the OSMC (Open Source Modelica Consortium)
* Public License (OSMC-PL) are obtained from OSMC, either from the above
* address, from the URLs:
* http://www.openmodelica.org or
* https://github.com/OpenModelica/ or
* http://www.ida.liu.se/projects/OpenModelica,
* and in the OpenModelica distribution.
*
* GNU AGPL version 3 is obtained from:
* https://www.gnu.org/licenses/licenses.html#GPL
*
* This program is distributed WITHOUT ANY WARRANTY; without
* even the implied warranty of MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
* IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
*
* See the full OSMC Public License conditions for more details.
*
*/ =#

function default_models_path()
    joinpath(@__DIR__, "..", "models", "models.toml")
end

#= MSL 3.2.3, the version covered first, has the top-level registry and reference data
   (models/models.toml, reference/csv, reference/signals); another version has its own
   (models/models_<version>.toml, reference/<version>/csv, reference/<version>/signals). =#
const TOP_LEVEL_MSL_VERSION = "3.2.3"

"""
    default_models_path(version) -> String

The registry of MSL `version`: `models/models.toml` for 3.2.3, else `models/models_<version>.toml`.
"""
function default_models_path(version::String)::String
    version == TOP_LEVEL_MSL_VERSION && return default_models_path()
    return joinpath(@__DIR__, "..", "models", "models_$(version).toml")
end

"""
    reference_dir(models_path, version; library = "Modelica") -> String

The reference data for the registry at `models_path`: `reference/` beside the registry's folder. MSL
`version`: that folder for 3.2.3, its subfolder `version` for another version. Another `library`: its
subfolder `<library>_<version>` (`reference/download_refs.sh --library`).
"""
function reference_dir(models_path::String, version::String; library::String = "Modelica")::String
    local dir::String = joinpath(dirname(models_path), "..", "reference")
    if library != "Modelica"
        dir = joinpath(dir, "$(library)_$(version)")
    elseif version != TOP_LEVEL_MSL_VERSION
        dir = joinpath(dir, version)
    end
    return abspath(dir)
end

"""
    REFERENCE_LIBRARIES

The libraries other than the MSL with reference results (`reference_source`): ModelicaTest (MAP-LIB),
ScalableTestSuite, PowerSystems, PowerGrids (their reference repositories) and Buildings (the results it ships).
"""
const REFERENCE_LIBRARIES = ("ModelicaTest", "ScalableTestSuite", "PowerSystems", "PowerGrids", "Buildings")

"""
    msl_library_version(msl_version) -> String

The library version of an `MSL_Version` string: `"MSL:4.1.0"` -> `"4.1.0"`.
"""
msl_library_version(msl_version::String)::String = replace(msl_version, "MSL:" => "")

"""
    CoverageTarget

What a coverage run measures: the experiment models of the MSL in one version, or of another installed library.

- `library`, `version`: the library and its version (`"Modelica"`, `"4.1.0"`; `"Buildings"`, `"13.0.0"`).
- `msl_version`: how `run_coverage` loads it (`"MSL:4.1.0"`; `"LIB:Buildings@13.0.0"`, the libraries it uses
  loaded from its `uses` annotation).
- `registry`: its registry of overrides (it need not exist: no overrides).
- `label`: its name on reports and the site (`"MSL 4.1.0"`, `"Buildings 13.0.0"`).
- `folder`: its folder of the coverage site (`site_folder`, `library_site_folder`).
- `references`: whether reference results exist for it (the MSL, `REFERENCE_LIBRARIES`), so that its models
  can reach validate.
"""
struct CoverageTarget
    library::String
    version::String
    msl_version::String
    registry::String
    label::String
    folder::String
    references::Bool
end

"""
    coverage_target(; msl = "MSL:3.2.3", library = "") -> CoverageTarget

The target of a coverage run: `library` as `"Name@version"`, an installed library other than the MSL (as
OpenModelica's package manager installs it), else the MSL of `msl`.

```julia
coverage_target(; msl = "MSL:4.1.0").folder                 # "msl-4.1.0"
coverage_target(; library = "Buildings@13.0.0").msl_version  # "LIB:Buildings@13.0.0"
```
"""
function coverage_target(; msl::String = "MSL:3.2.3", library::String = "")::CoverageTarget
    if isempty(library)
        local mslVersion::String = msl_library_version(msl)
        return CoverageTarget("Modelica", mslVersion, msl, default_models_path(mslVersion), "MSL $mslVersion",
                              site_folder(mslVersion), true)
    end
    local parts::Vector{SubString{String}} = split(library, '@')
    (length(parts) == 2 && all(!isempty, parts) && parts[1] != "Modelica") ||
        throw(ArgumentError("a library other than the MSL as Name@version, got $(repr(library))"))
    local name::String = String(parts[1])
    local version::String = String(parts[2])
    local registry::String = joinpath(@__DIR__, "..", "models", "models_$(name)_$(version).toml") |> abspath
    return CoverageTarget(name, version, "LIB:$name@$version", registry, "$name $version",
                          library_site_folder(name, version), name in REFERENCE_LIBRARIES)
end

"""
    coverage_target_from_env() -> CoverageTarget

The scripts' `coverage_target`: `OMJL_COVERAGE_LIBRARY` (default none) and `OMJL_COVERAGE_MSL` (default `"MSL:3.2.3"`).
"""
coverage_target_from_env()::CoverageTarget =
    coverage_target(; msl = get(ENV, "OMJL_COVERAGE_MSL", "MSL:3.2.3"), library = get(ENV, "OMJL_COVERAGE_LIBRARY", ""))

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
