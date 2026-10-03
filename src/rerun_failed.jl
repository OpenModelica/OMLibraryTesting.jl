#=
  Rerun-failed mode: parse a previous coverage report, extract the set of
  failing models, and rerun only those through the full coverage pipeline.

  Useful when iterating on a fix that targets a known cluster of failures —
  avoids the cost of re-simulating the ~70 % of MSL models that already pass.
=#

"""
    failing_names_from_report(parsed::Vector{ParsedModel};
                              from_phase::Phase = BACKEND,
                              include_broken::Bool = false) -> Vector{String}

Extract the model names that failed at any phase `>= from_phase` in `parsed`.
Default `from_phase = BACKEND` captures every model that did not reach a clean
validate (excluding pure frontend regressions, which are usually OMFrontend
bugs that would not benefit from rerunning the backend pipeline).

Models that are marked broken in the report are skipped unless `include_broken
= true`.
"""
function failing_names_from_report(parsed::Vector{ParsedModel};
                                   from_phase::Phase = BACKEND,
                                   include_broken::Bool = false)::Vector{String}
    names = String[]
    for pm in parsed
        if pm.is_broken && !include_broken
            continue
        end
        is_failing = false
        for (ph, status) in pm.phases
            if status == :fail && Int(ph) >= Int(from_phase)
                is_failing = true
                break
            end
        end
        is_failing && push!(names, pm.name)
    end
    sort!(unique!(names))
    return names
end

"""
    latest_html_report(dir::String = DEFAULT_REPORTS_DIR) -> String

Return the path of the most-recently-modified `.html` file under `dir`.
"""
function latest_html_report(dir::String = DEFAULT_REPORTS_DIR)::String
    if !isdir(dir)
        error("Reports directory does not exist: $dir")
    end
    files = filter(f -> endswith(f, ".html"), readdir(dir; join = true))
    if isempty(files)
        error("No HTML reports found in $dir")
    end
    return sort(files, by = mtime, rev = true)[1]
end

"""
    run_failed_from_report(; report_path = latest_html_report(),
                             from_phase = BACKEND,
                             include_broken = false,
                             library = "Modelica",
                             version = "3.2.3",
                             msl_version = "MSL:3.2.3",
                             overrides = default_models_path(),
                             timeout = 1000.0,
                             phases = PHASE_ORDER,
                             run_from_phase = FRONTEND,
                             to_phase = VALIDATE,
                             check_sim_code = false,
                             n_workers = max(1, nprocs() - 1))
        -> Vector{ModelResult}

Rerun only the models that failed in a previous coverage HTML report.

`from_phase` selects which failures count as "to rerun": default `BACKEND`
means rerun any model that did not pass all phases from backend onward (i.e.
backend, simulate, or validate failed). Set `from_phase = FRONTEND` to also
rerun frontend failures, or `from_phase = VALIDATE` to rerun only validate
failures.

`run_from_phase` and `to_phase` select which phases the rerun itself executes
(same semantics as in `run_coverage`).

`include_broken = true` also reruns models the report tagged as broken; the
default skips them so the rerun reflects real progress rather than re-testing
known dead clusters.

Returns the same `Vector{ModelResult}` shape as `run_coverage`, so it can be
piped into `generate_report` to produce a fresh HTML/MD diff against the
input report.
"""
function run_failed_from_report(; report_path::String = "",
                                  from_phase::Phase = BACKEND,
                                  include_broken::Bool = false,
                                  library::String = "Modelica",
                                  version::String = "3.2.3",
                                  msl_version::String = "MSL:3.2.3",
                                  overrides::String = default_models_path(),
                                  timeout::Float64 = 1000.0,
                                  phases::Vector{Phase} = PHASE_ORDER,
                                  run_from_phase::Phase = FRONTEND,
                                  to_phase::Phase = VALIDATE,
                                  check_sim_code::Bool = false,
                                  n_workers::Int = max(1, nprocs() - 1))::Vector{ModelResult}
    actual_path = isempty(report_path) ? latest_html_report() : report_path
    isfile(actual_path) || error("Report file not found: $actual_path")
    @info "Parsing previous report: $actual_path"
    parsed = parse_report(actual_path)
    failed_names = failing_names_from_report(parsed;
                                             from_phase = from_phase,
                                             include_broken = include_broken)
    if isempty(failed_names)
        @info "No failing models in $actual_path matching from_phase=$from_phase — nothing to rerun"
        return ModelResult[]
    end
    @info "Rerunning $(length(failed_names)) failing models from previous report" first_n = first(failed_names, min(10, length(failed_names)))

    # Discover the full MSL set, apply toml overrides + reference auto-detect,
    # then keep only the entries whose name is in the failed set.
    specs = discover_experiments(; library = library, version = version, filter = r"")
    specs = merge_overrides!(specs, overrides)
    ref_dir = joinpath(dirname(overrides), "..", "reference") |> abspath
    specs = auto_detect_references!(specs, ref_dir)

    fail_set = Set{String}(failed_names)
    rerun_specs = Base.filter(s -> s.name in fail_set, specs)
    if isempty(rerun_specs)
        @warn "Failing names parsed from report do not match any discovered model — toml or omc state may have shifted" report = actual_path n_failed = length(failed_names)
        return ModelResult[]
    end
    missing_names = Base.filter(n -> !any(s -> s.name == n, rerun_specs), failed_names)
    if !isempty(missing_names)
        @warn "Some failing-report names did not match a discovered model" n_missing = length(missing_names) first_missing = first(missing_names, min(5, length(missing_names)))
    end

    return _run_specs(rerun_specs;
                      msl_version = msl_version,
                      timeout = timeout,
                      phases = phases,
                      from_phase = run_from_phase,
                      to_phase = to_phase,
                      check_sim_code = check_sim_code,
                      n_workers = n_workers)
end

"""
    run_failed_and_report(; report_path = "", kwargs...) -> Vector{ModelResult}

Convenience: `run_failed_from_report` + write a fresh HTML + Markdown report
with the rerun results. Keyword arguments are passed through to
`run_failed_from_report`; the report-writing kwargs (`dir`, `changelog`,
`filename`, `name_tag`) match `run_coverage_and_report`.

The fresh report is suffixed `_rerun` in the default filename if `name_tag` is
empty so it does not collide with the source report.
"""
function run_failed_and_report(; report_path::String = "",
                                 from_phase::Phase = BACKEND,
                                 include_broken::Bool = false,
                                 library::String = "Modelica",
                                 version::String = "3.2.3",
                                 msl_version::String = "MSL:3.2.3",
                                 overrides::String = default_models_path(),
                                 timeout::Float64 = 1000.0,
                                 phases::Vector{Phase} = PHASE_ORDER,
                                 run_from_phase::Phase = FRONTEND,
                                 to_phase::Phase = VALIDATE,
                                 check_sim_code::Bool = false,
                                 n_workers::Int = max(1, nprocs() - 1),
                                 dir::String = DEFAULT_REPORTS_DIR,
                                 changelog::String = "",
                                 filename::String = "",
                                 name_tag::String = "rerun")::Vector{ModelResult}
    t_start = time()
    results = run_failed_from_report(; report_path = report_path,
                                       from_phase = from_phase,
                                       include_broken = include_broken,
                                       library = library, version = version,
                                       msl_version = msl_version,
                                       overrides = overrides,
                                       timeout = timeout,
                                       phases = phases,
                                       run_from_phase = run_from_phase,
                                       to_phase = to_phase,
                                       check_sim_code = check_sim_code,
                                       n_workers = n_workers)
    total_time = time() - t_start
    if isempty(results)
        @info "Nothing to report"
        return results
    end
    html_path = generate_report(results; format = :html, dir = dir,
                                changelog = changelog, msl_version = msl_version,
                                total_time = total_time, filename = filename,
                                name_tag = name_tag)
    md_path   = generate_report(results; format = :markdown, dir = dir,
                                changelog = changelog, msl_version = msl_version,
                                total_time = total_time, filename = filename,
                                name_tag = name_tag)
    @info "Rerun reports saved" html = html_path markdown = md_path
    return results
end

"""
    _run_specs(specs::Vector{ModelSpec}; kwargs...) -> Vector{ModelResult}

Internal: execute `run_coverage`-style pool execution against a pre-filtered
list of specs. Extracted so `run_failed_from_report` and any future helper that
needs to drive an explicit subset can share the worker-pool wiring.
"""
function _run_specs(specs::Vector{ModelSpec};
                    msl_version::String = "MSL:3.2.3",
                    timeout::Float64 = 1000.0,
                    phases::Vector{Phase} = PHASE_ORDER,
                    from_phase::Phase = FRONTEND,
                    to_phase::Phase = VALIDATE,
                    check_sim_code::Bool = false,
                    n_workers::Int = max(1, nprocs() - 1))::Vector{ModelResult}
    t_start = time()
    n_workers >= 1 || throw(ArgumentError("n_workers must be >= 1, got $n_workers"))
    phases = Base.filter(p -> Int(from_phase) <= Int(p) <= Int(to_phase), phases)
    phase_names = join([PHASE_NAMES[p] for p in phases], ", ")

    n_broken = count(s -> s.expected == BROKEN, specs)
    total_models = length(specs)
    n_active = total_models - n_broken
    @info "Rerunning $n_active models ($n_broken known broken, $total_models total) phases=[$phase_names] n_workers=$n_workers timeout=$(round(Int, timeout))s"

    effective_workers = min(n_workers, total_models)
    pool = WorkerPool(effective_workers; msl_version = msl_version)
    ensure_pool!(pool)

    indexed_results = Vector{Union{Nothing, ModelResult}}(nothing, total_models)
    work_chan = Channel{Tuple{Int, ModelSpec}}(total_models)
    for (i, spec) in enumerate(specs)
        put!(work_chan, (i, spec))
    end
    close(work_chan)

    log_lock = ReentrantLock()
    started = Threads.Atomic{Int}(0)

    try
        @sync for (worker_idx, mgr) in enumerate(pool.managers)
            @async begin
                for (i, spec) in work_chan
                    n = Threads.atomic_add!(started, 1) + 1
                    lock(log_lock) do
                        @info "[$n/$total_models] (W$worker_idx) $(spec.name)"
                    end
                    result = run_model(spec, mgr; timeout = timeout,
                                       phases_to_run = phases,
                                       check_sim_code = check_sim_code)
                    indexed_results[i] = result
                end
            end
        end
    catch e
        is_interrupt = e isa InterruptException ||
                       (e isa CompositeException &&
                        any(ex -> ex isa InterruptException, e.exceptions))
        if is_interrupt
            n_done = count(!isnothing, indexed_results)
            @warn "Rerun interrupted by user after $n_done/$total_models models"
        else
            rethrow()
        end
    finally
        cleanup!(pool)
    end

    results = ModelResult[r for r in indexed_results if r !== nothing]
    total_time = time() - t_start
    print_summary(results; total_time = total_time)
    return results
end
