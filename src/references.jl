#=
Author: John Tinnerholm
Reference results of the libraries, from where OpenModelica's library testing takes them (its configs/conf.json):
MAP-LIB_ReferenceResults for the MSL and ModelicaTest, the reference repositories of ScalableTestSuite, PowerSystems
and PowerGrids, and the files Buildings ships. They go into a reference directory as `reference/download_refs.sh`
lays it out, one file per model under its key (`_model_name_to_ref_key`): `csv/<key>.csv` and
`signals/<key>.txt`, `mat/<key>.mat` or `txt/<key>.txt` (REFERENCE_FORMATS, `reference_path`).
=#

"""
    MAPLIB_URL

The raw files of modelica/MAP-LIB_ReferenceResults; a branch per MSL version (`v4.1.0`).
"""
const MAPLIB_URL = "https://raw.githubusercontent.com/modelica/MAP-LIB_ReferenceResults"

"""
    ReferenceLayout

How a source names a model's result file: `MAPLIB_LAYOUT` the name as folders and the last part again
(`maplib_reference_path`, with `comparisonSignals.txt` beside it), `MODEL_FILE` the model's name and the
source's suffix, `KEY_FILE` its key and the suffix.
"""
@enum ReferenceLayout MAPLIB_LAYOUT MODEL_FILE KEY_FILE

"""
    ReferenceSource

Where a library's reference results are: `url` (an https URL or a local directory), `layout` and the
`suffix` after the model's name or key (`"_res.mat"`, `".mat.xz"`, `".txt"`; unused for MAP-LIB).
"""
struct ReferenceSource
    url::String
    layout::ReferenceLayout
    suffix::String
end

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
    installed_library_dir(name, version) -> String

The directory of an installed library, `<name> <version>` in OMFrontend's library directories
(`~/OMJL/libraries`, `~/.openmodelica/libraries`).
"""
function installed_library_dir(name::String, version::String)::String
    for dir in OMFrontend.libraryDirectories()
        local path::String = joinpath(dir, "$name $version")
        isdir(path) && return path
    end
    error("$name $version is not installed in $(join(OMFrontend.libraryDirectories(), ", "))")
end

"""
    reference_source(library, version) -> ReferenceSource

The reference results of a library version, as OpenModelica's library testing takes them:
- Modelica, ModelicaTest: MAP-LIB_ReferenceResults, the branch of the version (`maplib_branch`), CSV.
- ScalableTestSuite: casella/ScalableTestSuite-ref, PowerGrids: PowerGrids/PowerGrids-ref (`<model>_res.mat`),
  PowerSystems: rfranke/PowerSystems_ReferenceResults (`<model>.mat.xz`); their master, made for the libraries'
  development versions.
- Buildings: the Dymola results it ships, Resources/ReferenceResults/Dymola/`<key>.txt` (BuildingsPy format)
  of the installed library.
"""
function reference_source(library::String, version::String)::ReferenceSource
    local github::String = "https://raw.githubusercontent.com"
    library in ("Modelica", "ModelicaTest") &&
        return ReferenceSource("$MAPLIB_URL/$(maplib_branch(version))", MAPLIB_LAYOUT, "")
    library == "ScalableTestSuite" &&
        return ReferenceSource("$github/casella/ScalableTestSuite-ref/master", MODEL_FILE, "_res.mat")
    library == "PowerGrids" &&
        return ReferenceSource("$github/PowerGrids/PowerGrids-ref/master", MODEL_FILE, "_res.mat")
    library == "PowerSystems" &&
        return ReferenceSource("$github/rfranke/PowerSystems_ReferenceResults/master", MODEL_FILE, ".mat.xz")
    library == "Buildings" &&
        return ReferenceSource(joinpath(installed_library_dir(library, version), "Resources", "ReferenceResults", "Dymola"),
                               KEY_FILE, ".txt")
    throw(ArgumentError("no reference results known for $library $version"))
end

"""
    _fetch_file(src, dest) -> Bool

`src` (an https URL, else a local file) to `dest`, through `dest.part` so a broken download leaves no file; up
to 3 tries. A `.xz` source is decompressed (7-Zip, p7zip_jll). An existing `dest` is kept. False when the file
is not there (404, no local file).
"""
function _fetch_file(src::String, dest::String)::Bool
    isfile(dest) && return true
    local remote::Bool = startswith(src, "https://")
    remote || isfile(src) || return false
    mkpath(dirname(dest))
    local part::String = dest * ".part"
    local raw::String = endswith(src, ".xz") ? part * ".xz" : part
    for attempt in 1:3
        try
            remote ? Downloads.download(src, raw) : cp(src, raw; force = true)
            if raw != part
                open(part, "w") do io::IOStream
                    run(pipeline(`$(p7zip_jll.p7zip()) e -so $raw`; stdout = io, stderr = devnull))
                end
                rm(raw)
            end
            mv(part, dest; force = true)
            return true
        catch e
            rm(part; force = true)
            rm(raw; force = true)
            local notFound::Bool = e isa Downloads.RequestError && e.response.status == 404
            (notFound || attempt == 3) && return false
            sleep(2.0 * attempt)
        end
    end
    return false
end

"""
    _reference_folder(suffix) -> Tuple{String, String}

The folder and extension (REFERENCE_FORMATS) of a source's result files: `".mat.xz"`, `"_res.mat"` ->
`("mat", ".mat")`.
"""
function _reference_folder(suffix::String)::Tuple{String, String}
    local plain::String = endswith(suffix, ".xz") ? suffix[1:end-3] : suffix
    for (folder, extension) in REFERENCE_FORMATS
        endswith(plain, extension) && return (folder, extension)
    end
    throw(ArgumentError("no reference format for $suffix"))
end

"""
    download_reference(model, ref_dir, source) -> Bool

The reference result of `model` from `source` into `ref_dir`: `<folder>/<key><extension>` (REFERENCE_FORMATS;
MAP-LIB: `csv/<key>.csv` and its comparison signals, `signals/<key>.txt`, without which a comparison uses
`default_comparison_signals`). Files already there are kept. True when the result is there.

```julia
download_reference("ModelicaTest.Blocks.Limiters", "reference/ModelicaTest_4.1.0+maint.om",
                   reference_source("ModelicaTest", "4.1.0+maint.om"))
```
"""
function download_reference(model::String, ref_dir::String, source::ReferenceSource)::Bool
    local key::String = _model_name_to_ref_key(model)
    if source.layout == MAPLIB_LAYOUT
        local base::String = "$(source.url)/$(maplib_reference_path(model))"
        _fetch_file(base * ".csv", joinpath(ref_dir, "csv", key * ".csv")) || return false
        _fetch_file(dirname(base) * "/comparisonSignals.txt", joinpath(ref_dir, "signals", key * ".txt"))
        return true
    end
    local (folder, extension) = _reference_folder(source.suffix)
    local name::String = (source.layout == MODEL_FILE ? model : key) * source.suffix
    local src::String = startswith(source.url, "https://") ? "$(source.url)/$name" : joinpath(source.url, name)
    return _fetch_file(src, joinpath(ref_dir, folder, key * extension))
end

"""
    download_references(models, ref_dir, source; ntasks = 16) -> Int

`download_reference` for each of `models`, `ntasks` at a time. Returns how many results are there (already or
now); the others are not in the source or could not be fetched (logged).
"""
function download_references(models::Vector{String}, ref_dir::String, source::ReferenceSource;
                             ntasks::Int = 16)::Int
    local t0::Float64 = time()
    local found::Vector{Bool} = asyncmap(m -> download_reference(m, ref_dir, source), models; ntasks = ntasks)
    local missing::Vector{String} = models[.!found]
    @info "Reference results: $(count(found)) of $(length(models)) in $ref_dir ($(round(time() - t0; digits = 1)) s)" source.url missing = first(missing, 10)
    return count(found)
end

"""
    download_references(target; models = its experiment models, ntasks = 16) -> Int

The reference results of a coverage target (`coverage_target`) with references (the MSL, `REFERENCE_LIBRARIES`)
from its `reference_source`, into its `reference_dir`.

```julia
download_references(coverage_target(; library = "ModelicaTest@4.1.0+maint.om"))   # 608 models, about 700 MB
```
"""
function download_references(target::CoverageTarget;
                             models::Vector{String} = String[s.name for s in
                                 discover_experiments(; library = target.library, version = target.version)],
                             ntasks::Int = 16)::Int
    target.references || throw(ArgumentError("no reference results for $(target.label)"))
    local ref_dir::String = reference_dir(target.registry, target.version; library = target.library)
    return download_references(models, ref_dir, reference_source(target.library, target.version); ntasks = ntasks)
end
