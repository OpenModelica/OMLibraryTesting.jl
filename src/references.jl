#=
Author: John Tinnerholm
Reference results from MAP-LIB_ReferenceResults (the Modelica Association's results of the MSL and of
ModelicaTest), fetched into a reference directory as `reference/download_refs.sh` lays it out:
`csv/<key>.csv` and `signals/<key>.txt` (`_model_name_to_ref_key`).
=#

"""
    MAPLIB_URL

The raw files of modelica/MAP-LIB_ReferenceResults; a branch per MSL version (`v4.1.0`).
"""
const MAPLIB_URL = "https://raw.githubusercontent.com/modelica/MAP-LIB_ReferenceResults"

"""
    maplib_branch(version) -> String

The MAP-LIB branch of a library version: `"v"` and the version without its `+` part
(`"4.1.0+maint.om"` -> `"v4.1.0"`), the MSL version that ModelicaTest tests.
"""
maplib_branch(version::String)::String = "v" * String(first(split(version, '+')))

"""
    maplib_reference_path(model) -> String

A model's result in MAP-LIB, without the extension: its name as folders, then its last part again
(`"ModelicaTest.Blocks.Limiters"` -> `"ModelicaTest/Blocks/Limiters/Limiters"`). The folder also holds
`comparisonSignals.txt`.
"""
function maplib_reference_path(model::String)::String
    local parts::Vector{SubString{String}} = split(model, '.')
    return join(parts, '/') * "/" * parts[end]
end

"""
    _fetch_file(url, dest) -> Bool

`url` to `dest` (through `dest.part`, so a broken download leaves no file), up to 3 tries; an existing
`dest` is kept. False when the file could not be fetched (not in MAP-LIB: 404).
"""
function _fetch_file(url::String, dest::String)::Bool
    isfile(dest) && return true
    mkpath(dirname(dest))
    local part::String = dest * ".part"
    for attempt in 1:3
        try
            Downloads.download(url, part)
            mv(part, dest; force = true)
            return true
        catch e
            rm(part; force = true)
            local notFound::Bool = e isa Downloads.RequestError && e.response.status == 404
            (notFound || attempt == 3) && return false
            sleep(2.0 * attempt)
        end
    end
    return false
end

"""
    download_reference(model, ref_dir; branch) -> Bool

The MAP-LIB result of `model` on `branch` into `ref_dir/csv/<key>.csv`, and its comparison signals into
`ref_dir/signals/<key>.txt` (without them a comparison uses every signal). Files already there are kept.
True when the result is there.

```julia
download_reference("ModelicaTest.Blocks.Limiters", "reference/ModelicaTest_4.1.0+maint.om"; branch = "v4.1.0")
```
"""
function download_reference(model::String, ref_dir::String; branch::String)::Bool
    local key::String = _model_name_to_ref_key(model)
    local base::String = "$MAPLIB_URL/$branch/$(maplib_reference_path(model))"
    _fetch_file(base * ".csv", joinpath(ref_dir, "csv", key * ".csv")) || return false
    _fetch_file(dirname(base) * "/comparisonSignals.txt", joinpath(ref_dir, "signals", key * ".txt"))
    return true
end

"""
    download_references(models, ref_dir; branch, ntasks = 16) -> Int

`download_reference` for each of `models`, `ntasks` at a time. Returns how many results are there
(already or now); the others are not in MAP-LIB or could not be fetched (logged).
"""
function download_references(models::Vector{String}, ref_dir::String;
                             branch::String, ntasks::Int = 16)::Int
    local t0::Float64 = time()
    local found::Vector{Bool} = asyncmap(m -> download_reference(m, ref_dir; branch = branch), models; ntasks = ntasks)
    local missing::Vector{String} = models[.!found]
    @info "Reference results: $(count(found)) of $(length(models)) in $ref_dir ($(round(time() - t0; digits = 1)) s)" branch missing = first(missing, 10)
    return count(found)
end

"""
    download_references(target; models = its experiment models, ntasks = 16) -> Int

The reference results of a coverage target (`coverage_target`) with references: the MSL or one of
`REFERENCE_LIBRARIES`, from the MAP-LIB branch of its version, into its `reference_dir`.

```julia
download_references(coverage_target(; library = "ModelicaTest@4.1.0+maint.om"))   # 608 models, about 1 GB
```
"""
function download_references(target::CoverageTarget;
                             models::Vector{String} = String[s.name for s in
                                 discover_experiments(; library = target.library, version = target.version)],
                             ntasks::Int = 16)::Int
    target.references || throw(ArgumentError("no reference results for $(target.label)"))
    local ref_dir::String = reference_dir(target.registry, target.version; library = target.library)
    return download_references(models, ref_dir; branch = maplib_branch(target.version), ntasks = ntasks)
end
