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

using DifferentialEquations: ReturnCode

const PHASE_ORDER = [FRONTEND, BACKEND, SIMULATE, VALIDATE]

# ── Worker Manager ──────────────────────────────────────────────────────

"""
    WorkerManager

Manages a persistent Distributed.jl worker process for running model tests.
The worker is reused across models and only restarted if killed or crashed.
"""
mutable struct WorkerManager
    pid::Union{Nothing, Int}
    ready::Bool
    msl_version::String
    ref_dir::String
end

function WorkerManager(; msl_version::String = "MSL:3.2.3",
                         ref_dir::String = joinpath(@__DIR__, "..", "reference"))
    WorkerManager(nothing, false, msl_version, abspath(ref_dir))
end

"""
    ensure_worker!(mgr) -> pid

Ensure a live worker process exists with packages loaded. Spawns a new one
if needed. Returns the worker pid.
"""
function ensure_worker!(mgr::WorkerManager)::Int
    if mgr.pid !== nothing && mgr.pid in workers()
        return mgr.pid
    end
    @info "Spawning worker process..."
    t0 = time()
    pids = addprocs(1; exeflags = "--project=$(Base.active_project())")
    mgr.pid = pids[1]
    @info "Worker spawned (pid=$(mgr.pid)), loading packages..."
    Distributed.remotecall_eval(Main, [mgr.pid],
        :(using OMLibraryTesting, DifferentialEquations; import OM, OMFrontend))
    mgr.ready = true
    elapsed = round(time() - t0, digits = 1)
    @info "Worker ready ($(elapsed)s)"
    return mgr.pid
end

function kill_worker!(mgr::WorkerManager)
    if mgr.pid !== nothing && mgr.pid in workers()
        try
            rmprocs(mgr.pid; waitfor = 5.0)
        catch
        end
    end
    mgr.pid = nothing
    mgr.ready = false
end

function cleanup!(mgr::WorkerManager)
    kill_worker!(mgr)
end

# ── Worker-Side Function ────────────────────────────────────────────────

"""
    _run_model_phases(model_name, msl_version, stop_time, reference_file,
                      reference, atol, reltol, signal_mapping, ref_dir,
                      phase_ints) -> (results, highest)

Runs all phases for a single model. Intended to execute on a worker process.
Returns primitive types to avoid Distributed.jl type identity issues.

Each phase result is `(phase_int, success, time_s, error_or_nothing)`.
"""
function _run_model_phases(model_name::String,
                           msl_version::String,
                           stop_time::Float64,
                           reference_file::String,
                           reference::Dict{String, Float64},
                           atol::Float64,
                           reltol::Float64,
                           signal_mapping::Dict{String, String},
                           ref_dir::String,
                           phase_ints::Vector{Int},
                           check_sim_code::Bool = false)
    results = Tuple{Int, Bool, Float64, Union{Nothing, String}}[]
    highest = 0
    sol = nothing

    has_csv_ref = !isempty(reference_file)
    has_inline_ref = !isempty(reference)

    for phase_int in phase_ints
        if phase_int == Int(VALIDATE) && !has_csv_ref && !has_inline_ref
            break
        end

        # Clear compiler error buffer
        try; OMFrontend.Frontend.ErrorExt.clearMessages(); catch; end

        t0 = time()
        try
            if phase_int == Int(FRONTEND)
                OM.flatten(model_name; MSL_Version = msl_version)
            elseif phase_int == Int(BACKEND)
                OM.translate(model_name; MSL_Version = msl_version,
                             checkSimCode = check_sim_code)
            elseif phase_int == Int(SIMULATE)
                sol = OM.simulate(model_name; stopTime = stop_time)
                if sol.retcode != ReturnCode.Success
                    error("Simulation retcode: $(sol.retcode)")
                end
            elseif phase_int == Int(VALIDATE)
                if has_csv_ref
                    # Reconstruct a ModelSpec on the worker for validate_against_reference
                    temp_spec = ModelSpec(
                        model_name, "", "", stop_time, UNKNOWN,
                        reference, atol, reltol, reference_file, signal_mapping, "",
                        Set{Phase}())
                    (passed, comparisons) = validate_against_reference(sol, temp_spec, ref_dir)
                    if !passed
                        failed = filter(c -> !c.passed, comparisons)
                        names = join([c.name for c in failed], ", ")
                        error("Validation failed for signals: $names")
                    end
                else
                    for (var, expected) in reference
                        actual = last(sol[Symbol(var)])
                        if !isapprox(actual, expected; atol = atol)
                            error("$var: expected $expected, got $actual (atol=$atol)")
                        end
                    end
                end
            end

            elapsed = time() - t0
            push!(results, (phase_int, true, elapsed, nothing))
            highest = phase_int

        catch e
            elapsed = time() - t0
            compiler_msgs = try
                OMFrontend.Frontend.ErrorExt.printMessagesStr()
            catch
                ""
            end
            msg = sprint(showerror, e; context = :compact => true)
            if length(msg) > 500
                msg = msg[1:500] * "..."
            end
            if !isempty(compiler_msgs)
                msg = compiler_msgs * "\n---\n" * msg
                if length(msg) > 2000
                    msg = msg[1:2000] * "..."
                end
            end
            push!(results, (phase_int, false, elapsed, msg))
            break
        end
    end

    return (results, highest)
end

# ── Worker Execution with Timeout ───────────────────────────────────────

const GRACE_PERIOD = 15.0

"""
    run_on_worker(mgr, spec, phases_to_run; timeout, grace_period) -> ModelResult

Run all phases for a model on the worker process with an escalating timeout:
1. After `timeout` seconds: send SIGINT via `interrupt(pid)`
2. After `timeout + grace_period` seconds: kill the worker via `rmprocs`
"""
function run_on_worker(mgr::WorkerManager, spec::ModelSpec,
                       phases_to_run::Vector{Phase};
                       timeout::Float64 = 1500.0,
                       grace_period::Float64 = GRACE_PERIOD,
                       check_sim_code::Bool = false)::ModelResult
    pid = ensure_worker!(mgr)
    phase_ints = [Int(p) for p in phases_to_run]

    future = remotecall(OMLibraryTesting._run_model_phases, pid,
        spec.name, mgr.msl_version, spec.stopTime,
        spec.referenceFile, spec.reference, spec.atol, spec.reltol,
        spec.signalMapping, mgr.ref_dir, phase_ints, check_sim_code)

    t0 = time()
    interrupted = Ref(false)
    killed = Ref(false)

    # Use try-catch around isready: for Distributed.Future, isready() communicates
    # with the remote worker and throws if the worker is dead or unreachable.
    # When the worker is dead (ProcessExitedException), return false to break the
    # polling loop and let fetch() throw the proper exception for the catch handler.
    _future_pending() = try
        !isready(future)
    catch e
        if e isa ProcessExitedException
            false
        else
            true
        end
    end

    timer_interrupt = Timer(timeout) do _t
        if _future_pending()
            interrupted[] = true
            @warn "  TIMEOUT after $(round(timeout, digits=0))s, sending interrupt to worker..."
            try; interrupt(pid); catch; end
        end
    end

    timer_kill = Timer(timeout + grace_period) do _t
        if _future_pending() && interrupted[]
            killed[] = true
            @warn "  Worker did not respond to interrupt, killing..."
            try; kill_worker!(mgr); catch; end
        end
    end

    try
        # Poll instead of blocking on fetch so Ctrl-C can be delivered between iterations.
        # Also break when killed[] is true: after the worker is force-killed, isready(future)
        # throws (dead socket), which _future_pending() catches as "still pending". Without
        # the killed[] check the loop would spin forever.
        while _future_pending() && !killed[]
            sleep(0.5)
        end
        raw = fetch(future)
        elapsed = time() - t0

        phase_results = PhaseResult[
            PhaseResult(Phase(pr[1]), pr[2], pr[3], pr[4])
            for pr in raw[1]
        ]
        highest = Phase(raw[2])

        # Log phase results
        for pr in phase_results
            if pr.success
                @info "    $(PHASE_NAMES[pr.phase]): PASS ($(round(pr.time_s, digits=1))s)"
            else
                @info "    $(PHASE_NAMES[pr.phase]): FAIL: $(pr.error)"
            end
        end

        return ModelResult(spec, phase_results, highest,
                          Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
    catch e
        elapsed = time() - t0

        if interrupted[] || killed[]
            msg = "Timeout after $(round(elapsed, digits=1))s (limit: $(round(timeout, digits=0))s)"
            if killed[]
                msg *= " [worker killed]"
                mgr.pid = nothing
                mgr.ready = false
            end
            @warn "    TIMEOUT: $msg"
            phase = isempty(phases_to_run) ? BROKEN : phases_to_run[1]
            phases = PhaseResult[PhaseResult(phase, false, elapsed, msg)]
            return ModelResult(spec, phases, BROKEN,
                              Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
        elseif e isa ProcessExitedException ||
               (e isa RemoteException && e.captured.ex isa ProcessExitedException)
            msg = "Worker process crashed: $(sprint(showerror, e))"
            if length(msg) > 500
                msg = msg[1:500] * "..."
            end
            @warn "    CRASH: $msg"
            mgr.pid = nothing
            mgr.ready = false
            phase = isempty(phases_to_run) ? BROKEN : phases_to_run[1]
            phases = PhaseResult[PhaseResult(phase, false, elapsed, msg)]
            return ModelResult(spec, phases, BROKEN,
                              Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
        elseif e isa InterruptException
            @warn "    INTERRUPTED by user"
            kill_worker!(mgr)
            rethrow()
        elseif e isa RemoteException
            # Worker threw a normal exception that escaped _run_model_phases
            msg = sprint(showerror, e; context = :compact => true)
            if length(msg) > 500
                msg = msg[1:500] * "..."
            end
            @info "    FAIL: $msg"
            phase = isempty(phases_to_run) ? BROKEN : phases_to_run[1]
            phases = PhaseResult[PhaseResult(phase, false, elapsed, msg)]
            return ModelResult(spec, phases, BROKEN,
                              Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
        else
            rethrow()
        end
    finally
        close(timer_interrupt)
        close(timer_kill)
    end
end

# ── Public API ──────────────────────────────────────────────────────────

"""
    run_model(spec, mgr; timeout, phases_to_run) -> ModelResult

Run all applicable phases for a single model on the worker process.
Each model has a wall-clock timeout (default 25 minutes).
"""
function run_model(spec::ModelSpec, mgr::WorkerManager;
                    timeout::Float64 = 1500.0,
                    phases_to_run::Vector{Phase} = PHASE_ORDER,
                    check_sim_code::Bool = false)::ModelResult
    if spec.expected == BROKEN
        @info "Skipping known-broken model: $(spec.name)" issue=spec.issue
        return ModelResult(spec, PhaseResult[], BROKEN,
                          Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
    end
    effective_phases = filter(p -> p ∉ spec.skipPhases, phases_to_run)
    if isempty(effective_phases)
        @info "Skipping model (all requested phases skipped): $(spec.name)"
        return ModelResult(spec, PhaseResult[], BROKEN,
                          Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
    end
    return run_on_worker(mgr, spec, effective_phases; timeout = timeout,
                         check_sim_code = check_sim_code)
end

"""
    run_coverage(; library, version, domain, model, filter, overrides, timeout,
                   phases, from_phase, to_phase) -> Vector{ModelResult}

Run the full MSL coverage suite. Models are discovered automatically via omc.
TOML overrides (reference files, known broken, signal mappings) are merged in.
Each model runs on an isolated worker process with an enforced timeout.

Optionally filter by `domain` regex, single `model` name, or general `filter` regex.

Use `from_phase` and `to_phase` to restrict which phases are run. For example,
`from_phase=BACKEND` skips the frontend phase (useful when frontend is 100% pass).
`to_phase=BACKEND` stops after backend without attempting simulate or validate.

Set `check_sim_code=true` to run SimulationCode.SimCodeCheck on the optimized
SimCode before MTK codegen during the BACKEND phase. Violations are printed
to the worker's stderr and do not alter pass/fail of the phase itself.
"""
function run_coverage(; library::String = "Modelica",
                        version::String = "3.2.3",
                        msl_version::String = "MSL:3.2.3",
                        domain::String = "",
                        model::String = "",
                        filter::Regex = r"",
                        overrides::String = default_models_path(),
                        timeout::Float64 = 1500.0,
                        phases::Vector{Phase} = PHASE_ORDER,
                        from_phase::Phase = FRONTEND,
                        to_phase::Phase = VALIDATE,
                        check_sim_code::Bool = false)::Vector{ModelResult}
    t_start = time()
    phases = Base.filter(p -> Int(from_phase) <= Int(p) <= Int(to_phase), phases)
    phase_names = join([PHASE_NAMES[p] for p in phases], ", ")
    @info "Starting coverage run (phases: $phase_names)"
    specs = discover_experiments(; library = library, version = version, filter = filter)
    specs = merge_overrides!(specs, overrides)
    ref_dir = joinpath(dirname(overrides), "..", "reference") |> abspath
    specs = auto_detect_references!(specs, ref_dir)
    if !isempty(model)
        specs = Base.filter(s -> s.name == model, specs)
        if isempty(specs)
            error("Model not found: $model")
        end
    elseif !isempty(domain)
        domain_re = Regex(domain)
        specs = Base.filter(s -> occursin(domain_re, s.domain), specs)
        if isempty(specs)
            error("No models found matching domain: $domain")
        end
    end
    n_broken = count(s -> s.expected == BROKEN, specs)
    n_active = length(specs) - n_broken
    @info "Running $n_active models ($n_broken known broken, $(length(specs)) total), timeout=$(round(Int, timeout))s"
    mgr = WorkerManager(; msl_version = msl_version)
    results = ModelResult[]
    try
        for (i, spec) in enumerate(specs)
            @info "[$i/$(length(specs))] $(spec.name)"
            result = run_model(spec, mgr; timeout = timeout, phases_to_run = phases,
                               check_sim_code = check_sim_code)
            push!(results, result)
        end
    catch e
        if e isa InterruptException
            @warn "Run interrupted by user after $(length(results))/$(length(specs)) models"
        else
            rethrow()
        end
    finally
        cleanup!(mgr)
    end
    total_time = time() - t_start
    print_summary(results; total_time = total_time)
    return results
end

function print_summary(results::Vector{ModelResult}; total_time::Float64 = 0.0)
    total = length(results)
    broken = count(r -> r.spec.expected == BROKEN, results)
    tested = total - broken
    frontend_pass = count(r -> r.highest >= FRONTEND, results)
    backend_pass = count(r -> r.highest >= BACKEND, results)
    simulate_pass = count(r -> r.highest >= SIMULATE, results)
    validate_pass = count(r -> r.highest >= VALIDATE, results)
    println()
    println("=" ^ 70)
    println("MSL Coverage Summary")
    println("=" ^ 70)
    println("Total models:  $total ($broken known broken, $tested tested)")
    println()
    println("  Stage       Passed   Total    Rate")
    println("  " * "-" ^ 40)
    if tested > 0
        println("  Frontend    $(lpad(frontend_pass, 5))   $(lpad(tested, 5))   $(lpad(round(100*frontend_pass/tested, digits=1), 5))%")
        println("  Backend     $(lpad(backend_pass, 5))   $(lpad(tested, 5))   $(lpad(round(100*backend_pass/tested, digits=1), 5))%")
        println("  Simulate    $(lpad(simulate_pass, 5))   $(lpad(tested, 5))   $(lpad(round(100*simulate_pass/tested, digits=1), 5))%")
        has_ref = count(r -> !isempty(r.spec.referenceFile) || !isempty(r.spec.reference), results)
        if has_ref > 0
            println("  Validate    $(lpad(validate_pass, 5))   $(lpad(has_ref, 5))   $(lpad(round(100*validate_pass/has_ref, digits=1), 5))%")
        end
    end
    if total_time > 0
        mins = floor(Int, total_time / 60)
        secs = round(Int, total_time % 60)
        println()
        println("  Total time: $(mins)m $(secs)s")
    end
    println("=" ^ 70)
    println()
end
