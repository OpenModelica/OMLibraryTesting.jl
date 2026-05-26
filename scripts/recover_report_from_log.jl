#=
Rebuild a coverage HTML/MD report from a driver log when the driver
crashed before serializing results. Requires nothing from the old worker
process; everything is reconstructed by:

  1. Running discover_experiments + merge_overrides + auto_detect_references
     (same pipeline the driver uses) to get the full ModelSpec list.
  2. Scanning the log for per-model [N/TOTAL], "frontend/backend/simulate/validate: PASS|FAIL"
     lines to build PhaseResult values.
  3. Matching model-name -> ModelSpec and emitting ModelResult.

Usage:
    julia --project=. scripts/recover_report_from_log.jl <log_path> [<name_tag>]

Optional environment variables:
    OMJL_RECOVER_MSL   (default "MSL:3.2.3")
=#

using Dates
using Serialization

import OMLibraryTesting
using OMLibraryTesting: ModelSpec, ModelResult, PhaseResult, Phase
using OMLibraryTesting: FRONTEND, BACKEND, SIMULATE, VALIDATE, BROKEN, UNKNOWN
using OMLibraryTesting: PHASE_NAMES, phase_from_string
using OMLibraryTesting: discover_experiments, merge_overrides!, auto_detect_references!
using OMLibraryTesting: default_models_path, generate_report

length(ARGS) >= 1 || error("usage: julia scripts/recover_report_from_log.jl <log_path> [<name_tag>]")
const LOG_PATH = ARGS[1]
const NAME_TAG = length(ARGS) >= 2 ? ARGS[2] : "recovered_full_msl"
const MSL      = get(ENV, "OMJL_RECOVER_MSL", "MSL:3.2.3")

isfile(LOG_PATH) || error("log file not found: $LOG_PATH")
@info "Recovering report" log=LOG_PATH tag=NAME_TAG msl=MSL

# ── Build spec list via discovery pipeline (same as driver) ────────────
specs = discover_experiments(; library = "Modelica", version = "3.2.3")
specs = merge_overrides!(specs, default_models_path())
ref_dir = joinpath(default_models_path() |> dirname, "..", "reference") |> abspath
specs = auto_detect_references!(specs, ref_dir)
spec_by_name = Dict(s.name => s for s in specs)
@info "Discovered $(length(specs)) specs; $(length(spec_by_name)) by-name map"

# ── Parse log for per-model phase results ──────────────────────────────
const MODEL_HEADER_RE = r"^\[ Info: \[(\d+)/(\d+)\] (.+)$"
const PHASE_PASS_RE   = r"^\[ Info:\s+(frontend|backend|simulate|validate): PASS \(([0-9.]+)s\)$"
# FAIL lines may be prefixed with either "[ Info:" or "┌ Info:" / "┌ Warning:" depending on severity.
const PHASE_FAIL_RE   = r"^(?:\[ Info:|┌ Info:|┌ Warning:)\s+(frontend|backend|simulate|validate): FAIL: (.+)$"
const SKIP_BROKEN_RE  = r"^\[ Info: Skipping known-broken model: (.+?)(?: issue=| \|)"
const SKIP_ALLSKIP_RE = r"^\[ Info: Skipping model \(all requested phases skipped\): (.+)$"
const TIMEOUT_RE      = r"^┌ Warning:\s+TIMEOUT: Timeout after ([0-9.]+)s"

# One entry per-model in the log: store (spec_idx_total, spec_name, Vector{PhaseResult})
function parse_log(path::String)
    current_name = ""
    current_phases = PhaseResult[]
    parsed = Dict{String, Vector{PhaseResult}}()
    broken_or_skipped = Set{String}()

    for line in eachline(path)
        if (m = match(MODEL_HEADER_RE, line)) !== nothing
            if !isempty(current_name)
                parsed[current_name] = copy(current_phases)
            end
            current_name = String(m.captures[3])
            empty!(current_phases)
        elseif (m = match(SKIP_BROKEN_RE, line)) !== nothing
            push!(broken_or_skipped, String(m.captures[1]))
        elseif (m = match(SKIP_ALLSKIP_RE, line)) !== nothing
            push!(broken_or_skipped, String(m.captures[1]))
        elseif (m = match(PHASE_PASS_RE, line)) !== nothing
            isempty(current_name) && continue
            ph = phase_from_string(String(m.captures[1]))
            t  = parse(Float64, m.captures[2])
            push!(current_phases, PhaseResult(ph, true, t, nothing))
        elseif (m = match(PHASE_FAIL_RE, line)) !== nothing
            isempty(current_name) && continue
            ph = phase_from_string(String(m.captures[1]))
            err = String(m.captures[2])
            push!(current_phases, PhaseResult(ph, false, 0.0, err))
        end
    end
    if !isempty(current_name)
        parsed[current_name] = copy(current_phases)
    end
    return parsed, broken_or_skipped
end

parsed, broken_or_skipped = parse_log(LOG_PATH)

@info "Parsed $(length(parsed)) model rows from log; $(length(broken_or_skipped)) skipped/broken"

# ── Build ModelResult list covering ALL specs (missing ones marked BROKEN with empty phases) ─
results = ModelResult[]
ts = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
for spec in specs
    local phases = get(parsed, spec.name, PhaseResult[])
    highest = BROKEN
    for p in phases
        if p.success && Int(p.phase) > Int(highest)
            highest = p.phase
        end
    end
    push!(results, ModelResult(spec, phases, highest, ts))
end
@info "Built $(length(results)) ModelResults"

# ── Generate reports ────────────────────────────────────────────────────
report_end_ts = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
m = match(r"full_coverage_([0-9-]+_[0-9]+)\.log$", LOG_PATH)
start_ts = m === nothing ? report_end_ts : m.captures[1]

fname = "coverage_$(NAME_TAG)_start_$(start_ts)_end_$(report_end_ts).html"
md_fname = replace(fname, ".html" => ".md")

changelog = string(
    "Recovered from driver log: ", LOG_PATH, ". ",
    "Run tag: ", NAME_TAG, ". ",
    "MSL: ", MSL, ". ",
    "Driver start: ", start_ts, ". ",
    "Recovery run at: ", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), ". ",
    "Models parsed from log: ", length(parsed), "; total specs: ", length(specs), ". ",
    "(Driver crashed mid-run; missing specs are marked BROKEN with empty phases.)")

path_html = generate_report(results;
    filename    = fname,
    msl_version = replace(MSL, "MSL:" => ""),
    changelog   = changelog)
@info "Wrote HTML report" path=path_html

path_md = generate_report(results;
    format      = :markdown,
    filename    = md_fname,
    msl_version = replace(MSL, "MSL:" => ""),
    changelog   = changelog)
@info "Wrote MD report" path=path_md

# Quick summary to stdout
println()
println(repeat("=", 64))
println("Recovery report summary")
println(repeat("=", 64))
fe = count(r -> r.highest >= FRONTEND, results)
be = count(r -> r.highest >= BACKEND,  results)
si = count(r -> r.highest >= SIMULATE, results)
va = count(r -> r.highest >= VALIDATE, results)
println("Total:     $(length(results))")
println("Parsed:    $(length(parsed))")
println("Frontend:  $fe")
println("Backend:   $be")
println("Simulate:  $si")
println("Validate:  $va")
println("HTML:      $path_html")
println("MD:        $path_md")
