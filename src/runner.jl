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
    #= OS-level process id of the worker, captured at spawn while the worker is
       still responsive. Needed because a hung worker (pegged in compiled code)
       cannot answer `remotecall_fetch(getpid, …)` at kill time, and the
       Distributed worker id is not the OS pid. =#
    os_pid::Union{Nothing, Int}
    ready::Bool
    msl_version::String
    ref_dir::String
end

function WorkerManager(; msl_version::String = "MSL:3.2.3",
                         ref_dir::String = joinpath(@__DIR__, "..", "reference"))
    WorkerManager(nothing, nothing, false, msl_version, abspath(ref_dir))
end

#= Best-effort OS pid of a live, responsive Distributed worker. =#
function _capture_os_pid(worker_id::Int)::Union{Nothing, Int}
    try
        return Distributed.remotecall_fetch(getpid, worker_id)
    catch
        return nothing
    end
end

"""
Pids spawned by this module (via `ensure_worker!` or `ensure_pool!`).
Only these pids are reclaimed by `kill_worker!` / `cleanup!(::WorkerPool)`.
Pids adopted from pre-existing Distributed workers are NOT in this set
and are left alone at cleanup.
"""
const _SPAWNED_PIDS = Set{Int}()

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
    push!(_SPAWNED_PIDS, mgr.pid)
    @info "Worker spawned (pid=$(mgr.pid)), loading packages..."
    Distributed.remotecall_eval(Main, [mgr.pid],
        :(using OMLibraryTesting, DifferentialEquations; import OM, OMFrontend))
    mgr.os_pid = _capture_os_pid(mgr.pid)
    mgr.ready = true
    elapsed = round(time() - t0, digits = 1)
    @info "Worker ready ($(elapsed)s)"
    return mgr.pid
end

function kill_worker!(mgr::WorkerManager)
    if mgr.pid !== nothing && mgr.pid in _SPAWNED_PIDS
        #= Hard OS-level SIGKILL first. A worker pegged in compiled code
           (structural_simplify, RGF compilation, a tight simulate event loop)
           never services Distributed's graceful `rmprocs` request, so rmprocs
           alone leaves the OS process alive at 100% CPU. SIGKILL cannot be
           ignored and reclaims the core immediately. =#
        if mgr.os_pid !== nothing
            try
                run(pipeline(`kill -9 $(mgr.os_pid)`; stderr = devnull))
            catch
            end
        end
        #= Then clear Distributed's bookkeeping; the process is already dead, so
           rmprocs returns promptly. =#
        if mgr.pid in workers()
            try
                rmprocs(mgr.pid; waitfor = 5.0)
            catch
            end
        end
        delete!(_SPAWNED_PIDS, mgr.pid)
    end
    mgr.pid = nothing
    mgr.os_pid = nothing
    mgr.ready = false
end

function cleanup!(mgr::WorkerManager)
    kill_worker!(mgr)
end

# ── Worker Pool ─────────────────────────────────────────────────────────

"""
    WorkerPool(n; msl_version, ref_dir)

A pool of `n` WorkerManager instances for parallel model execution. Each
manager owns a Distributed.jl worker process with independent crash/restart
state. Up to `n` models run concurrently.
"""
mutable struct WorkerPool
    managers::Vector{WorkerManager}
end

function WorkerPool(n::Int; msl_version::String = "MSL:3.2.3",
                    ref_dir::String = joinpath(@__DIR__, "..", "reference"))
    n >= 1 || throw(ArgumentError("WorkerPool size must be >= 1, got $n"))
    managers = [WorkerManager(; msl_version = msl_version, ref_dir = ref_dir) for _ in 1:n]
    WorkerPool(managers)
end

"""
    ensure_pool!(pool) -> Vector{Int}

Adopt any pre-added Distributed workers first, then spawn the rest in a
single `addprocs` call. Adopted workers are not killed at cleanup; only
workers spawned by this pool (or by per-manager restart) are reclaimed.
Packages are loaded on every worker (idempotent for adopted ones).
Returns the pids of all live workers.
"""
function ensure_pool!(pool::WorkerPool)::Vector{Int}
    assigned_pids = Set{Int}(mgr.pid for mgr in pool.managers if mgr.pid !== nothing)
    available_existing = Int[w for w in workers() if w != myid() && !(w in assigned_pids)]

    n_adopted = 0
    for mgr in pool.managers
        if mgr.pid === nothing && !isempty(available_existing)
            mgr.pid = popfirst!(available_existing)
            n_adopted += 1
        end
    end

    needs_spawn = WorkerManager[]
    for mgr in pool.managers
        if mgr.pid === nothing || !(mgr.pid in workers())
            mgr.pid = nothing
            push!(needs_spawn, mgr)
        end
    end

    new_pids = Int[]
    if !isempty(needs_spawn)
        n = length(needs_spawn)
        @info "Spawning $n worker process(es)..."
        t0 = time()
        new_pids = addprocs(n; exeflags = "--project=$(Base.active_project())")
        for (mgr, pid) in zip(needs_spawn, new_pids)
            mgr.pid = pid
            push!(_SPAWNED_PIDS, pid)
        end
        @info "Workers spawned (pids=$new_pids)"
        elapsed = round(time() - t0, digits = 1)
        @info "Spawn took $(elapsed)s"
    end

    all_pids = Int[mgr.pid for mgr in pool.managers if mgr.pid !== nothing]
    if !isempty(all_pids)
        @info "Pool: $(length(all_pids)) workers ($n_adopted adopted, $(length(new_pids)) spawned), loading packages..."
        t0 = time()
        Distributed.remotecall_eval(Main, all_pids,
            :(using OMLibraryTesting, DifferentialEquations; import OM, OMFrontend))
        for mgr in pool.managers
            if mgr.pid !== nothing
                mgr.os_pid = _capture_os_pid(mgr.pid)
                mgr.ready = true
            end
        end
        elapsed = round(time() - t0, digits = 1)
        @info "Workers ready ($(elapsed)s)"
    end
    return all_pids
end

function cleanup!(pool::WorkerPool)
    for mgr in pool.managers
        kill_worker!(mgr)
    end
end

# ── Worker-Side Function ────────────────────────────────────────────────

"""
    _resolve_init_alg(name::String) -> NamedTuple

Map an initializealg name from the toml to the corresponding init-algorithm
constructor. Empty name returns the empty tuple (solver default applies).
Supported: BrownFullBasicInit, ShampineCollocationInit, OverrideInit,
CheckInit, NoInit, BrownBasicInit.
"""
function _resolve_init_alg(name::String)
    isempty(name) && return NamedTuple()
    local _try = (path) -> try Base.eval(Main, path) catch; nothing end
    for sym in (:BrownFullBasicInit, :ShampineCollocationInit, :OverrideInit,
                :CheckInit, :NoInit, :BrownBasicInit)
        if name == String(sym)
            local ctor = _try(Expr(:call, sym))
            ctor !== nothing && return (; initializealg = ctor)
        end
    end
    @warn "Unknown / unavailable initializealg name in spec, ignoring" initializealg=name
    return NamedTuple()
end

"""
    _resolve_solver(name) -> NamedTuple

Map a solver name string from the toml to the OM.simulate kwargs.
For IDA we also pin BrownFullBasicInit since the residual-form DAE rejects
MTK's default CheckInit. Empty/unknown -> empty NamedTuple (default solver).
"""
function _resolve_solver(name::String)
    isempty(name) && return NamedTuple()
    # Look up solvers and init algorithms via the worker's loaded packages.
    # The simulate worker has `using OM` which transitively loads OrdinaryDiffEq*, Sundials, DiffEqBase.
    local _try = (path) -> try Base.eval(Main, path) catch; nothing end
    if name == "IDA"
        # Sundials.IDA + Brown's IC algorithm — closest to OMC/Dymola's DASSL behavior
        local IDA = _try(:(Sundials.IDA))
        local Brown = _try(:(BrownFullBasicInit))
        IDA !== nothing && Brown !== nothing &&
            return (; solver = IDA(), initializealg = Brown())
    elseif name == "QNDF"
        local s = _try(:(QNDF));     s !== nothing && return (; solver = s(), dense = false)
    elseif name == "FBDF"
        local s = _try(:(FBDF));     s !== nothing && return (; solver = s(), dense = false)
    elseif name == "TRBDF2"
        local s = _try(:(TRBDF2));   s !== nothing && return (; solver = s(), dense = false)
    elseif name == "RadauIIA5"
        local s = _try(:(RadauIIA5)); s !== nothing && return (; solver = s(), dense = false)
    elseif name == "Rodas5P"
        local s = _try(:(Rodas5P));  s !== nothing && return (; solver = s())
    elseif name == "Rodas5"
        local s = _try(:(Rodas5));   s !== nothing && return (; solver = s())
    elseif name == "Rosenbrock23"
        local s = _try(:(Rosenbrock23)); s !== nothing && return (; solver = s())
    end
    @warn "Unknown / unavailable solver name in spec, falling back to default" solver=name
    return NamedTuple()
end

# Escape regex metacharacters so signal names containing `.`, `[`, `]`, etc.
# match literally inside OMBackend's `occursin(Regex(p), name)` filter.
_escape_regex(s::AbstractString) =
    replace(s, r"[\\.\[\]\(\)\+\*\?\^\$\|]" => sm -> "\\" * sm)

# Read the reference CSV header and return regex patterns (anchored,
# underscore-form) for every non-`time` column so OMBackend's observedFilter
# preserves the alias-map entries the validate phase will look up.
function _reference_signal_filter(ref_dir::String,
                                   reference_file::String,
                                   signal_mapping::Dict{String, String})::Vector{String}
    isempty(reference_file) && return String[]
    local csv_path = joinpath(ref_dir, "csv", reference_file * ".csv")
    isfile(csv_path) || return String[]
    local header_line = ""
    try
        open(csv_path) do io; header_line = readline(io); end
    catch
        return String[]
    end
    local patterns = String[]
    local seen = Set{String}()
    for col in split(header_line, ',')
        local raw = strip(col, ['"', ' ', '\t', '\r', '\n'])
        (isempty(raw) || raw == "time") && continue
        local mapped = get(signal_mapping, String(raw), String(raw))
        local under = replace(mapped, "." => "_")
        if !(under in seen)
            push!(seen, under)
            push!(patterns, string("^", _escape_regex(under), "\$"))
        end
    end
    return patterns
end

#= Cap the cost of `showerror`. Some exceptions (notably MTK's
   UnsolvableCallbackError / ExtraEquationsSystemException) render the entire
   equation / callback system — O(system size) — which can take many minutes to
   format for a large model. Since the harness truncates the message anyway,
   stop the render after `cap` bytes through a size-bounded IO. Verified ~0.08s
   vs 10+ minutes unbounded, with a useful message prefix preserved. =#
struct _ShowErrorCapped <: Exception end
mutable struct _CappedIO <: IO
    n::Int
    cap::Int
    buf::IOBuffer
end
function Base.write(io::_CappedIO, b::UInt8)
    io.n >= io.cap && throw(_ShowErrorCapped())
    io.n += 1
    return write(io.buf, b)
end
function _bounded_showerror(@nospecialize(e), cap::Int = 500)::String
    local cio = _CappedIO(0, cap, IOBuffer())
    local capped = false
    try
        showerror(IOContext(cio, :compact => true, :limit => true), e)
    catch ex
        ex isa _ShowErrorCapped || rethrow()
        capped = true
    end
    local s = String(take!(cio.buf))
    return capped ? s * "..." : s
end

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
                           check_sim_code::Bool = false,
                           solver_name::String = "",
                           dtmax::Float64 = 0.0,
                           init_alg::String = "",
                           solver_atol::Float64 = 0.0,
                           solver_reltol::Float64 = 0.0,
                           observed_filter::Vector{String} = String[],
                           maxiters::Float64 = 0.0)
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
                # Build kwargs: solver + dtmax (if non-zero) + initializealg (if specified).
                # Per-model initializealg overrides any default from the solver mapping.
                local _sa = isempty(solver_name) ? NamedTuple() : _resolve_solver(solver_name)
                local _extra = dtmax > 0.0 ? (; dtmax = dtmax) : NamedTuple()
                local _ia = isempty(init_alg) ? NamedTuple() : _resolve_init_alg(init_alg)
                local _of = isempty(observed_filter) ? NamedTuple() : (; observedFilter = observed_filter)
                local _mi = (; maxiters = maxiters > 0.0 ? round(Int, maxiters) : DEFAULT_MAXITERS)
                local _tol = NamedTuple()
                if solver_reltol > 0.0
                    _tol = (; _tol..., reltol = solver_reltol)
                end
                if solver_atol > 0.0
                    _tol = (; _tol..., abstol = solver_atol)
                end
                sol = OM.simulate(model_name; stopTime = stop_time, _sa..., _extra..., _ia..., _of..., _mi..., _tol...)
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
            msg = _bounded_showerror(e, 500)
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

#= Default solver iteration cap applied to every model's simulate unless the
   model overrides `maxiters` in the toml. Bounds runaway / chattering solves
   so they bail with a clean MaxIters quickly instead of grinding toward the
   SciML default of 1e5. A model that legitimately needs more steps can raise
   this via a per-model `maxiters` entry. =#
const DEFAULT_MAXITERS = 20000

"""
    _write_started_marker(model_name) -> String

Write an empty marker file `test_<name>_<yyyy-mm-dd>_<HH-MM-SS>_started` into
`tempdir()` so an external observer can see which models are currently in
flight. Returns the path so the caller can remove it on completion. Errors
during the write are swallowed so a marker failure cannot break the run.
"""
function _write_started_marker(model_name::String)::String
    path = ""
    try
        ts = Dates.now()
        date = Dates.format(ts, "yyyy-mm-dd")
        clock = Dates.format(ts, "HH-MM-SS")
        path = joinpath(tempdir(), "test_$(model_name)_$(date)_$(clock)_started")
        touch(path)
    catch
    end
    return path
end

function _remove_started_marker(path::String)
    isempty(path) && return
    try
        isfile(path) && rm(path; force = true)
    catch
    end
    return nothing
end

"""
    run_on_worker(mgr, spec, phases_to_run; timeout, grace_period) -> ModelResult

Run all phases for a model on the worker process with an escalating timeout:
1. After `timeout` seconds: send SIGINT via `interrupt(pid)`
2. After `timeout + grace_period` seconds: kill the worker via `rmprocs`
"""
function run_on_worker(mgr::WorkerManager, spec::ModelSpec,
                       phases_to_run::Vector{Phase};
                       timeout::Float64 = 1000.0,
                       grace_period::Float64 = GRACE_PERIOD,
                       check_sim_code::Bool = false)::ModelResult
    marker_path = _write_started_marker(spec.name)
    pid = ensure_worker!(mgr)
    phase_ints = [Int(p) for p in phases_to_run]

    future = remotecall(OMLibraryTesting._run_model_phases, pid,
        spec.name, mgr.msl_version, spec.stopTime,
        spec.referenceFile, spec.reference, spec.atol, spec.reltol,
        spec.signalMapping, mgr.ref_dir, phase_ints, check_sim_code,
        spec.solver, spec.dtmax, spec.initAlg,
        spec.solverAtol, spec.solverReltol, spec.observedFilter, spec.maxiters)

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
            msg = "Worker process crashed: $(_bounded_showerror(e, 500))"
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
            msg = _bounded_showerror(e, 500)
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
        _remove_started_marker(marker_path)
    end
end

# ── Public API ──────────────────────────────────────────────────────────

"""
    run_model(spec, mgr; timeout, phases_to_run) -> ModelResult

Run all applicable phases for a single model on the worker process.
Each model has a wall-clock timeout (default 1000 seconds ≈ 16.7 minutes).
"""
function run_model(spec::ModelSpec, mgr::WorkerManager;
                    timeout::Float64 = 1000.0,
                    phases_to_run::Vector{Phase} = PHASE_ORDER,
                    check_sim_code::Bool = false)::ModelResult
    effective_phases = filter(p -> p ∉ spec.skipPhases, phases_to_run)
    if spec.expected == BROKEN
        effective_phases = filter(p -> p == FRONTEND, effective_phases)
        if isempty(effective_phases)
            @info "Skipping known-broken model (frontend not requested): $(spec.name)" issue=spec.issue
            return ModelResult(spec, PhaseResult[], BROKEN,
                              Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))
        end
        @info "Running known-broken model in frontend only: $(spec.name)" issue=spec.issue
    end
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
                   phases, from_phase, to_phase, n_workers) -> Vector{ModelResult}

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

Set `n_workers > 1` to run models in parallel. Each worker is a separate
Distributed.jl process. Memory cost is roughly 1 GB per worker; pick a number
that fits available RAM. The default is `max(1, nprocs() - 1)`: if you have
pre-added workers via `addprocs(N)`, the pool adopts them; otherwise the pool
spawns a single worker and runs serially.
"""
function run_coverage(; library::String = "Modelica",
                        version::String = "3.2.3",
                        msl_version::String = "MSL:3.2.3",
                        domain::String = "",
                        model::String = "",
                        filter::Regex = r"",
                        overrides::String = default_models_path(),
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
    @info "Starting coverage run (phases: $phase_names, n_workers: $n_workers)"
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
    total_models = length(specs)
    @info "Running $n_active models ($n_broken known broken, $total_models total), timeout=$(round(Int, timeout))s"

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
            @warn "Run interrupted by user after $n_done/$total_models models"
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

function print_summary(results::Vector{ModelResult}; total_time::Float64 = 0.0)
    total = length(results)
    broken = count(r -> r.spec.expected == BROKEN, results)
    tested = total - broken
    #= Coverage funnel: the base is the total number of discovered models. Every
       stage rate is a fraction of this constant base, so each row reads "of all
       discovered models, what fraction reached stage X". =#
    frontend_pass = count(r -> r.highest >= FRONTEND, results)
    backend_pass = count(r -> r.highest >= BACKEND, results)
    simulate_pass = count(r -> r.highest >= SIMULATE, results)
    validate_pass = count(r -> r.highest >= VALIDATE, results)
    base = total
    println()
    println("=" ^ 70)
    println("MSL Coverage Summary")
    println("=" ^ 70)
    println("Total models:  $total ($broken known broken, $tested tested)")
    println()
    println("  Stage       Passed   Total    Rate")
    println("  " * "-" ^ 40)
    if base > 0
        println("  Frontend    $(lpad(frontend_pass, 5))   $(lpad(base, 5))   $(lpad(round(100*frontend_pass/base, digits=1), 5))%")
        println("  Backend     $(lpad(backend_pass, 5))   $(lpad(base, 5))   $(lpad(round(100*backend_pass/base, digits=1), 5))%")
        println("  Simulate    $(lpad(simulate_pass, 5))   $(lpad(base, 5))   $(lpad(round(100*simulate_pass/base, digits=1), 5))%")
        println("  Validate    $(lpad(validate_pass, 5))   $(lpad(base, 5))   $(lpad(round(100*validate_pass/base, digits=1), 5))%")
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
