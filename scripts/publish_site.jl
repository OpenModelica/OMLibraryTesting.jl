#=
Add a coverage run to the coverage site (GitHub Pages, gh-pages branch): runs/<date>/ with the
analysis and the per-model report, the index over all runs and the badges (src/site.jl).

    julia --project=. scripts/publish_site.jl <site dir> <results.jls> [report.html] [COVERAGE.md] [commits.txt] [note]

<results.jls> is a serialized Vector{ModelResult} (the partial_*.jls of scripts/run_full_coverage.jl);
the date is the one in its name (partial_<tag>_<yyyy-mm-dd>_<HHMM>.jls), else its modification date.
[report.html] is the run's generate_report output, [COVERAGE.md] the analysis of
scripts/publish_coverage.jl, [commits.txt] "<repository> <commit>" lines, [note] one line on how
the run was made. An empty argument skips that part. OMJL_SITE_URL (optional) is the site's address,
shown in the badge snippet. OMJL_COVERAGE_MSL (default "MSL:3.2.3", as scripts/run_full_coverage.jl)
is the run's MSL version: its runs go to its folder of the site (site_folder).
=#

using Dates
using Serialization

import OMLibraryTesting
const OLT = OMLibraryTesting

length(ARGS) >= 2 || error("usage: publish_site.jl <site dir> <results.jls> [report.html] [COVERAGE.md] [commits.txt] [note]")
arg(i) = length(ARGS) >= i ? ARGS[i] : ""
const RESULTS_PATH = ARGS[2]
const RESULTS = deserialize(RESULTS_PATH)::Vector{OLT.ModelResult}
const NAMED = match(r"_(\d{4}-\d{2}-\d{2})_\d{4}\.jls$", RESULTS_PATH)
const DATE = NAMED === nothing ? Date(Dates.unix2datetime(mtime(RESULTS_PATH))) : Date(NAMED[1])
const VERSION_MSL = OLT.msl_library_version(get(ENV, "OMJL_COVERAGE_MSL", "MSL:3.2.3"))
const COMMITS = isfile(arg(5)) ?
    [String(strip(l)) for l in eachline(arg(5)) if occursin(r"^\S+\.jl \S+$", strip(l))] : String[]

dir = OLT.publish_site(ARGS[1], RESULTS; version = VERSION_MSL, date = DATE, report = arg(3), analysis = arg(4),
                       commits = COMMITS, note = arg(6), url = get(ENV, "OMJL_SITE_URL", ""))
@info "Coverage site updated" run = dir funnel = OLT.coverage_funnel(RESULTS)
