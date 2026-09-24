#=
Driver script: run the full MSL coverage and generate an HTML report whose
filename encodes a human-readable tag plus a yyyy-mm-dd_HHMM timestamp.

Invoked from a fresh tmux via:
    julia --project=. scripts/run_full_coverage.jl

Environment variables:
    OMJL_COVERAGE_TAG       Human-readable tag (default: "full_msl").
    OMJL_COVERAGE_MSL       MSL version (default: "MSL:3.2.3").
    OMJL_COVERAGE_TIMEOUT   Per-model timeout seconds (default: 1500).
    OMJL_COVERAGE_DOMAIN    Optional domain regex filter.
    OMJL_COVERAGE_MODEL     Optional single model name.
    OMJL_COVERAGE_FROMPHASE Optional from_phase (frontend|backend|simulate|validate).
    OMJL_COVERAGE_TOPHASE   Optional to_phase.
=#

using Dates
using Serialization

import OMLibraryTesting
using OMLibraryTesting: FRONTEND, BACKEND, SIMULATE, VALIDATE, phase_from_string

const TAG       = get(ENV, "OMJL_COVERAGE_TAG", "full_msl")
const MSL       = get(ENV, "OMJL_COVERAGE_MSL", "MSL:3.2.3")
const TIMEOUT   = parse(Float64, get(ENV, "OMJL_COVERAGE_TIMEOUT", "1500"))
const DOMAIN    = get(ENV, "OMJL_COVERAGE_DOMAIN", "")
const MODEL     = get(ENV, "OMJL_COVERAGE_MODEL",  "")
const FROMPHASE = phase_from_string(get(ENV, "OMJL_COVERAGE_FROMPHASE", "frontend"))
const TOPHASE   = phase_from_string(get(ENV, "OMJL_COVERAGE_TOPHASE",   "validate"))

const RUN_START    = Dates.now()
const RUN_TS       = Dates.format(RUN_START, "yyyy-mm-dd_HHMM")
const REPORT_DIR   = joinpath(@__DIR__, "..", "reports") |> abspath
const LOG_DIR      = joinpath(@__DIR__, "..", "logs")    |> abspath
const PARTIAL_PATH = joinpath(LOG_DIR, "partial_$(TAG)_$(RUN_TS).jls")

mkpath(REPORT_DIR)
mkpath(LOG_DIR)

@info "Coverage run starting" tag=TAG msl=MSL timeout=TIMEOUT ts=RUN_TS from=FROMPHASE to=TOPHASE
@info "Report directory: $REPORT_DIR"
@info "Partial-results snapshot: $PARTIAL_PATH"

t0 = time()
results = try
    OMLibraryTesting.run_coverage(;
        msl_version = MSL,
        timeout     = TIMEOUT,
        domain      = DOMAIN,
        model       = MODEL,
        from_phase  = FROMPHASE,
        to_phase    = TOPHASE)
catch e
    @error "run_coverage threw" exception=(e, catch_backtrace())
    OMLibraryTesting.ModelResult[]
end
total_time = time() - t0

try
    open(PARTIAL_PATH, "w") do io
        serialize(io, results)
    end
    @info "Partial results serialized" n=length(results) path=PARTIAL_PATH
catch e
    @warn "Could not serialize partial results" exception=e
end

if isempty(results)
    @warn "No results collected; skipping report generation."
else
    report_end_ts = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
    fname = "coverage_$(TAG)_start_$(RUN_TS)_end_$(report_end_ts).html"
    changelog = string(
        "Run tag: ", TAG, ". ",
        "MSL: ", MSL, ". ",
        "Start: ", Dates.format(RUN_START, "yyyy-mm-dd HH:MM:SS"), ". ",
        "End: ", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), ". ",
        "Timeout per model: ", Int(round(TIMEOUT)), "s. ",
        "Total wall-clock: ", string(floor(Int, total_time ÷ 60)), "m ",
        string(round(Int, total_time % 60)), "s.")
    @info "Generating HTML report" filename=fname
    path = OMLibraryTesting.generate_report(results;
        filename    = fname,
        dir         = REPORT_DIR,
        msl_version = replace(MSL, "MSL:" => ""),
        total_time  = total_time,
        changelog   = changelog)
    @info "Report generated" path=path
    md_fname = replace(fname, ".html" => ".md")
    md_path = OMLibraryTesting.generate_report(results;
        format      = :markdown,
        filename    = md_fname,
        dir         = REPORT_DIR,
        msl_version = replace(MSL, "MSL:" => ""),
        total_time  = total_time,
        changelog   = changelog)
    @info "Markdown report generated" path=md_path
end

@info "Coverage driver finished" elapsed_s=round(total_time, digits=1)
