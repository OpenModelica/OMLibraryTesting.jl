#=
Merge the results of a coverage run's shards (scripts/run_full_coverage.jl with OMJL_COVERAGE_SHARD
"k/n") into one run, written as an unsharded run writes it: the serialized results and the HTML and
Markdown reports.

    julia --project=. scripts/merge_coverage.jl <shard results.jls>...

Writes logs/partial_<tag>_<timestamp>.jls, with the earliest shard's timestamp so the run keeps its
start date, and reports/coverage_<tag>_start_<timestamp>_end_<now>.{html,md}. Every experiment model
of the version must be in exactly one shard, unless OMJL_COVERAGE_DOMAIN or OMJL_COVERAGE_MODEL
restricted the run. Environment as scripts/run_full_coverage.jl: OMJL_COVERAGE_TAG (default
"full_msl"), OMJL_COVERAGE_MSL (default "MSL:3.2.3").
=#

using Dates
using Serialization

import OMLibraryTesting
const OLT = OMLibraryTesting

isempty(ARGS) && error("usage: merge_coverage.jl <shard results.jls>...")
const TAG = get(ENV, "OMJL_COVERAGE_TAG", "full_msl")
const MSL = get(ENV, "OMJL_COVERAGE_MSL", "MSL:3.2.3")
const LIBRARY_VERSION = OLT.msl_library_version(MSL)
const RESTRICTED = !isempty(get(ENV, "OMJL_COVERAGE_DOMAIN", "")) || !isempty(get(ENV, "OMJL_COVERAGE_MODEL", ""))
const ROOT = joinpath(@__DIR__, "..") |> abspath

const RESULTS = OLT.merge_shards([deserialize(p)::Vector{OLT.ModelResult} for p in ARGS])
RESTRICTED || let listed = Set(String(first(split(l, '|')))
                               for l in eachline(OLT.recorded_experiments_path("Modelica", LIBRARY_VERSION)) if !isempty(l))
    absent = sort!(collect(setdiff(listed, Set(r.spec.name for r in RESULTS))))
    isempty(absent) ||
        error("$(length(absent)) of the $(length(listed)) models are in no shard: $(join(first(absent, 10), ", "))")
end

const STAMPS = [m[1] for m in (match(r"_(\d{4}-\d{2}-\d{2}_\d{4})\.jls$", p) for p in ARGS) if m !== nothing]
const START = isempty(STAMPS) ? Dates.format(Dates.now(), "yyyy-mm-dd_HHMM") : minimum(STAMPS)
const OUT = joinpath(ROOT, "logs", "partial_$(TAG)_$(START).jls")
mkpath(dirname(OUT))
abspath(OUT) in abspath.(ARGS) && error("$OUT is one of the shards' results")
open(io -> serialize(io, RESULTS), OUT, "w")
@info "Merged" shards = length(ARGS) models = length(RESULTS) path = OUT

const NAME = "coverage_$(TAG)_start_$(START)_end_$(Dates.format(Dates.now(), "yyyy-mm-dd_HHMM"))"
const CHANGELOG = "Run tag: $TAG. MSL: $MSL. Merged from $(length(ARGS)) shards."
for format in (:html, :markdown)
    path = OLT.generate_report(RESULTS; format, filename = NAME * (format === :html ? ".html" : ".md"),
                               dir = joinpath(ROOT, "reports"), msl_version = LIBRARY_VERSION,
                               changelog = CHANGELOG)
    @info "Report generated" path
end
