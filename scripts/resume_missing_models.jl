#=
Resume a coverage run for only the models that were NOT parsed from a prior driver log.
Saves per-model results to a JLS file and generates an HTML+MD report that merges:
  - PhaseResults parsed from the prior log (for the already-processed models)
  - PhaseResults from this new run (for the remaining ones)

Usage:
    julia --project=. scripts/resume_missing_models.jl <prior_log_path> [<name_tag>]

Env:
    OMJL_RESUME_MSL       default MSL:3.2.3
    OMJL_RESUME_TIMEOUT   default 1500 (seconds per model)
=#

using Dates
using Serialization

import OMLibraryTesting
using OMLibraryTesting: ModelSpec, ModelResult, PhaseResult, Phase
using OMLibraryTesting: FRONTEND, BACKEND, SIMULATE, VALIDATE, BROKEN, UNKNOWN
using OMLibraryTesting: PHASE_NAMES, phase_from_string
using OMLibraryTesting: discover_experiments, merge_overrides!, auto_detect_references!
using OMLibraryTesting: default_models_path, generate_report
using OMLibraryTesting: WorkerManager, run_model

length(ARGS) >= 1 || error("usage: julia scripts/resume_missing_models.jl <prior_log_path> [<name_tag>]")
const PRIOR_LOG = ARGS[1]
const NAME_TAG  = length(ARGS) >= 2 ? ARGS[2] : "full_msl_resumed"
const MSL       = get(ENV, "OMJL_RESUME_MSL", "MSL:3.2.3")
const TIMEOUT   = parse(Float64, get(ENV, "OMJL_RESUME_TIMEOUT", "1500"))

isfile(PRIOR_LOG) || error("prior log file not found: $PRIOR_LOG")
@info "Resume coverage" prior_log=PRIOR_LOG tag=NAME_TAG msl=MSL timeout=TIMEOUT

# ── Build spec list ─────────────────────────────────────────────────────
specs = discover_experiments(; library = "Modelica", version = "3.2.3")
specs = merge_overrides!(specs, default_models_path())
ref_dir = joinpath(default_models_path() |> dirname, "..", "reference") |> abspath
specs = auto_detect_references!(specs, ref_dir)
spec_by_name = Dict(s.name => s for s in specs)

# ── Parse prior log for PhaseResults per model ──────────────────────────
const MODEL_HEADER_RE = r"^\[ Info: \[(\d+)/(\d+)\] (.+)$"
const PHASE_PASS_RE   = r"^\[ Info:\s+(frontend|backend|simulate|validate): PASS \(([0-9.]+)s\)$"
const PHASE_FAIL_RE   = r"^(?:\[ Info:|┌ Info:|┌ Warning:)\s+(frontend|backend|simulate|validate): FAIL: (.+)$"

function parse_log(path::String)
    current_name = ""
    current_phases = PhaseResult[]
    parsed = Dict{String, Vector{PhaseResult}}()
    for line in eachline(path)
        if (m = match(MODEL_HEADER_RE, line)) !== nothing
            if !isempty(current_name)
                parsed[current_name] = copy(current_phases)
            end
            current_name = String(m.captures[3])
            empty!(current_phases)
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
    return parsed
end

prior_results = parse_log(PRIOR_LOG)
@info "Parsed prior log" n_models=length(prior_results)

# ── Identify missing models: non-broken specs whose name isn't in prior_results ─
missing_specs = ModelSpec[]
for s in specs
    s.expected == BROKEN && continue
    !haskey(prior_results, s.name) && push!(missing_specs, s)
end
@info "Missing models" count=length(missing_specs)

# ── Run the missing models ──────────────────────────────────────────────
mgr = WorkerManager(; msl_version = MSL)
new_results = Dict{String, Vector{PhaseResult}}()
run_start = time()
try
    for (i, spec) in enumerate(missing_specs)
        @info "[resume $i/$(length(missing_specs))] $(spec.name)"
        mr = run_model(spec, mgr; timeout = TIMEOUT)
        new_results[spec.name] = mr.phases
    end
catch e
    if e isa InterruptException
        @warn "Resume interrupted by user"
    else
        rethrow()
    end
finally
    OMLibraryTesting.cleanup!(mgr)
end
run_elapsed = time() - run_start
@info "Resume run finished" new_models=length(new_results) elapsed_s=round(run_elapsed, digits=1)

# ── Persist raw new_results as JLS ──────────────────────────────────────
jls_stamp = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
jls_path  = joinpath(dirname(PRIOR_LOG), "resume_$(NAME_TAG)_$(jls_stamp).jls")
try
    open(jls_path, "w") do io
        serialize(io, new_results)
    end
    @info "Serialized resume results" path=jls_path
catch e
    @warn "Serialization failed" exception=e
end

# ── Merge and build ModelResult list covering all specs ─────────────────
results = ModelResult[]
ts = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM")
for s in specs
    phases = if haskey(new_results, s.name)
        new_results[s.name]
    elseif haskey(prior_results, s.name)
        prior_results[s.name]
    else
        PhaseResult[]
    end
    highest = BROKEN
    for p in phases
        if p.success && Int(p.phase) > Int(highest)
            highest = p.phase
        end
    end
    push!(results, ModelResult(s, phases, highest, ts))
end

# ── Generate combined report ────────────────────────────────────────────
end_ts = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
m = match(r"full_coverage_([0-9-]+_[0-9]+)\.log$", PRIOR_LOG)
start_ts = m === nothing ? end_ts : m.captures[1]
fname = "coverage_$(NAME_TAG)_start_$(start_ts)_end_$(end_ts).html"
md_fname = replace(fname, ".html" => ".md")

changelog = string(
    "Combined report: prior log + resume run. ",
    "Prior log: ", PRIOR_LOG, ". ",
    "Run tag: ", NAME_TAG, ". ",
    "MSL: ", MSL, ". ",
    "Prior log start: ", start_ts, ". ",
    "Resume finished: ", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), ". ",
    "Models from prior log: ", length(prior_results), ". ",
    "Models from resume run: ", length(new_results), ". ",
    "Total specs: ", length(specs), ".")

path_html = generate_report(results;
    filename    = fname,
    msl_version = replace(MSL, "MSL:" => ""),
    total_time  = run_elapsed,
    changelog   = changelog)
@info "Wrote HTML report" path=path_html

path_md = generate_report(results;
    format      = :markdown,
    filename    = md_fname,
    msl_version = replace(MSL, "MSL:" => ""),
    total_time  = run_elapsed,
    changelog   = changelog)
@info "Wrote MD report" path=path_md

# ── Summary ─────────────────────────────────────────────────────────────
println()
println(repeat("=", 64))
println("Combined report summary")
println(repeat("=", 64))
println("Total specs:          ", length(results))
println("From prior log:       ", length(prior_results))
println("From resume run:      ", length(new_results))
fe = count(r -> r.highest >= FRONTEND, results)
be = count(r -> r.highest >= BACKEND,  results)
si = count(r -> r.highest >= SIMULATE, results)
va = count(r -> r.highest >= VALIDATE, results)
println("Frontend pass:        ", fe)
println("Backend pass:         ", be)
println("Simulate pass:        ", si)
println("Validate pass:        ", va)
println("HTML:                 ", path_html)
println("MD:                   ", path_md)
