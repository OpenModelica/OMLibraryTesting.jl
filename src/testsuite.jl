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

# Integration of the upstream OpenModelica `testsuite/` regression suite into the
# OMLibraryTesting harness. Two run modes share one fetch + discovery front-end:
#
#   :rtest  drives the upstream Perl `rtest` harness against the system `omc`
#           (tests the C compiler, parses pass/fail per .mos)
#   :omjl   extracts each .mos test's model target and runs it through the OM.jl
#           FRONTEND -> BACKEND -> SIMULATE pipeline (tests OM.jl), reusing
#           run_model / WorkerManager.

const TESTSUITE_REPO = "https://github.com/OpenModelica/OpenModelica.git"

# Directories materialised by the sparse checkout. `testsuite` carries the .mos
# tests, rtest, ReferenceFiles and difftool; the rest are needed only when the
# rtest harness has to build omc-diff itself.
const TESTSUITE_SPARSE_PATHS = ["testsuite"]

default_testsuite_cache() = abspath(joinpath(@__DIR__, "..", ".testsuite_cache"))

"""
    TestsuiteCase

One upstream `.mos` regression test, parsed from its header and body.
`targets` are the model classes the script acts on (simulate/checkModel/...).
"""
struct TestsuiteCase
    file::String                 # path relative to the testsuite root
    name::String                 # `// name:` header (or basename)
    status::String               # `// status:` header (correct / erroneous / ...)
    library::String              # first loadModel(<lib>, ...) library, or ""
    version::String              # first loadModel version string, or ""
    targets::Vector{String}      # simulate/checkModel/instantiateModel class names
end

"""
    RtestResult

Outcome of running one `TestsuiteCase` through the upstream `rtest` harness.
"""
struct RtestResult
    case::TestsuiteCase
    passed::Bool
    failed_count::Int
    total_count::Int
    output::String
    time_s::Float64
end

# ---------------------------------------------------------------------------
# Fetch: sparse clone of the relevant testsuite directories
# ---------------------------------------------------------------------------

"""
    fetch_testsuite(; dest, ref, sparse_paths, update, scaffold, omc_path) -> String

Sparse-clone only the requested directories of the OpenModelica repository (by
default `testsuite/`) at `ref` (default "master") into `dest`. Returns the path
to the materialised testsuite root (`<dest>/testsuite`).

A partial clone (`--filter=tree:0`) plus cone-mode sparse-checkout downloads only
the trees/blobs actually checked out, so the working tree stays small. On a
second call with `update=true` the existing clone is fetched and hard-reset to
`origin/<ref>` for just the sparse paths.

When `scaffold=true` an OPENMODELICAHOME layout is created next to the checkout so
the `rtest` harness can locate `omc` and `omc-diff` (see `scaffold_rtest_home!`).
"""
function fetch_testsuite(; dest::String = default_testsuite_cache(),
                            ref::String = "master",
                            sparse_paths::Vector{String} = TESTSUITE_SPARSE_PATHS,
                            update::Bool = true,
                            scaffold::Bool = true,
                            omc_path::String = "omc")::String
    repo = joinpath(dest, "OpenModelica")
    mkpath(dest)
    git(args...) = run(Cmd(`git $(collect(args))`; dir = repo))

    if !isdir(joinpath(repo, ".git"))
        @info "Sparse-cloning $(join(sparse_paths, ", ")) from OpenModelica @ $ref into $repo"
        run(`git clone --no-checkout --filter=tree:0 --depth 1 --branch $ref $TESTSUITE_REPO $repo`)
        git("sparse-checkout", "init", "--cone")
        git("sparse-checkout", "set", sparse_paths...)
        git("checkout", ref)
    elseif update
        @info "Updating existing testsuite checkout in $repo to origin/$ref"
        git("sparse-checkout", "set", sparse_paths...)
        run(Cmd(`git fetch --depth 1 origin $ref`; dir = repo))
        run(Cmd(`git reset --hard FETCH_HEAD`; dir = repo))
    else
        @info "Reusing existing testsuite checkout in $repo (update=false)"
    end

    testsuite_root = joinpath(repo, "testsuite")
    isdir(testsuite_root) || error("testsuite directory missing after fetch: $testsuite_root")
    if scaffold
        scaffold_rtest_home!(repo; omc_path = omc_path)
    end
    return testsuite_root
end

"""
    scaffold_rtest_home!(repo; omc_path) -> String

Build the OPENMODELICAHOME directory layout the upstream `rtest` script expects to
find relative to the testsuite checkout: `<repo>/build_cmake/install_cmake/bin`
containing `omc` and `omc-diff`, plus a `<repo>/libraries/.openmodelica/libraries`
link to the installed Modelica libraries.

`omc` is symlinked to the resolved `omc_path` (it locates its own runtime home from
its real install location). `omc-diff` is built from `testsuite/difftool` if it is
not already available; building requires `flex` and a C compiler.
Returns the OPENMODELICAHOME path.
"""
function scaffold_rtest_home!(repo::String; omc_path::String = "omc")::String
    omhome = joinpath(repo, "build_cmake", "install_cmake")
    bindir = joinpath(omhome, "bin")
    mkpath(bindir)

    omc_resolved = Sys.which(omc_path)
    omc_resolved === nothing && error("omc not found on PATH ($omc_path); rtest mode needs a built omc")
    _force_symlink(omc_resolved, joinpath(bindir, "omc"))

    diff_dst = joinpath(bindir, "omc-diff")
    if !isfile(diff_dst)
        built = _build_omc_diff(joinpath(repo, "testsuite", "difftool"))
        if built === nothing
            @warn "omc-diff is not available and could not be built (needs `flex`). " *
                  "rtest mode will not run until omc-diff exists at $diff_dst. " *
                  "Install flex (e.g. `sudo apt-get install flex`) and re-run fetch_testsuite, " *
                  "or copy an existing omc-diff there."
        else
            cp(built, diff_dst; force = true)
            chmod(diff_dst, 0o755)
        end
    end

    libs_link = joinpath(repo, "libraries", ".openmodelica", "libraries")
    installed = joinpath(homedir(), ".openmodelica", "libraries")
    if isdir(installed) && !ispath(libs_link)
        mkpath(dirname(libs_link))
        _force_symlink(installed, libs_link)
    end
    return omhome
end

function _force_symlink(target::String, link::String)
    (islink(link) || ispath(link)) && rm(link; force = true)
    symlink(target, link)
end

# Build omc-diff from its flex source; returns the binary path or nothing on failure.
function _build_omc_diff(difftool_dir::String)::Union{Nothing, String}
    isdir(difftool_dir) || return nothing
    Sys.which("flex") === nothing && return nothing
    cc = Sys.which("cc")
    cc === nothing && (cc = Sys.which("gcc"))
    cc === nothing && return nothing
    out = joinpath(difftool_dir, "omc-diff")
    isfile(out) && return out
    lexc = joinpath(difftool_dir, "lex.yy.c")
    try
        run(Cmd(`flex omc-diff.l`; dir = difftool_dir))
        run(Cmd(`$cc -o omc-diff lex.yy.c`; dir = difftool_dir))
    catch e
        @warn "Building omc-diff failed" exception = (e, catch_backtrace())
        return nothing
    finally
        rm(lexc; force = true)
    end
    return isfile(out) ? out : nothing
end

# ---------------------------------------------------------------------------
# Discovery: parse .mos files into TestsuiteCase records
# ---------------------------------------------------------------------------

const _RE_NAME    = r"^//\s*name:\s*(.+?)\s*$"m
const _RE_STATUS  = r"^//\s*status:\s*([A-Za-z]+)"m
const _RE_LOAD    = r"loadModel\(\s*([A-Za-z_][\w]*)\s*,\s*\{?\s*\"([^\"]+)\""
const _RE_TARGET  = r"(?:simulate|simulateModel|instantiateModel|checkModel|checkAllModelsRecursive|translateModel|buildModel|flattenAll)\(\s*([A-Za-z_][\w\.]*)"

"""
    parse_mos_file(path, root) -> TestsuiteCase

Parse one `.mos` test file into a `TestsuiteCase`. `root` is the testsuite root so
the stored path is repo-relative.
"""
function parse_mos_file(path::String, root::String)::TestsuiteCase
    text = read(path, String)
    nm = match(_RE_NAME, text)
    st = match(_RE_STATUS, text)
    ld = match(_RE_LOAD, text)
    targets = String[]
    for m in eachmatch(_RE_TARGET, text)
        t = m.captures[1]
        # ignore obvious non-class arguments
        (isempty(t) || t in ("All",)) && continue
        t in targets || push!(targets, t)
    end
    rel = relpath(path, root)
    name = nm === nothing ? basename(path) : String(nm.captures[1])
    status = st === nothing ? "unknown" : lowercase(String(st.captures[1]))
    library = ld === nothing ? "" : String(ld.captures[1])
    version = ld === nothing ? "" : String(ld.captures[2])
    return TestsuiteCase(rel, name, status, library, version, targets)
end

"""
    discover_testsuite_cases(testsuite_root; subdir, filter, status) -> Vector{TestsuiteCase}

Walk `testsuite_root` (optionally restricted to `subdir`) collecting every `.mos`
test, parsed into `TestsuiteCase`s. `filter` matches the repo-relative path;
`status` (default "correct") filters on the `// status:` header ("" = keep all).
"""
function discover_testsuite_cases(testsuite_root::String;
                                   subdir::String = "",
                                   filter::Regex = r"",
                                   status::String = "correct")::Vector{TestsuiteCase}
    base = isempty(subdir) ? testsuite_root : joinpath(testsuite_root, subdir)
    isdir(base) || error("testsuite path not found: $base")
    cases = TestsuiteCase[]
    for (dir, _, files) in walkdir(base)
        for f in files
            endswith(f, ".mos") || continue
            path = joinpath(dir, f)
            case = parse_mos_file(path, testsuite_root)
            isempty(filter.pattern) || occursin(filter, case.file) || continue
            isempty(status) || case.status == status || continue
            push!(cases, case)
        end
    end
    sort!(cases, by = c -> c.file)
    @info "Discovered $(length(cases)) testsuite .mos cases" base status
    return cases
end

# ---------------------------------------------------------------------------
# Mode :rtest  — drive the upstream Perl harness
# ---------------------------------------------------------------------------

"""
    run_rtest(cases, testsuite_root; omcflags, alarm, verbose) -> Vector{RtestResult}

Run each `TestsuiteCase` through the upstream `rtest` harness against the system
`omc`. Each test runs from the directory containing its `.mos`, which is how the
Makefile invokes rtest and how it resolves OPENMODELICAHOME. Parses the
`== N out of M tests failed` summary line into pass/fail.

Requires a working `omc-diff` in the scaffolded OPENMODELICAHOME (see
`fetch_testsuite`); raises if it is missing.
"""
function run_rtest(cases::Vector{TestsuiteCase}, testsuite_root::String;
                    omcflags::String = "",
                    verbose::Bool = false)::Vector{RtestResult}
    rtest = joinpath(testsuite_root, "rtest")
    isfile(rtest) || error("rtest harness not found at $rtest; run fetch_testsuite first")
    repo = dirname(testsuite_root)
    diff = joinpath(repo, "build_cmake", "install_cmake", "bin", "omc-diff")
    isfile(diff) || error("omc-diff missing at $diff. rtest cannot run without it. " *
                          "Install flex and re-run fetch_testsuite (scaffold builds omc-diff).")
    results = RtestResult[]
    for (i, case) in enumerate(cases)
        mos = joinpath(testsuite_root, case.file)
        rundir = dirname(mos)
        # rtest's only positional args are `+flag` (appended to omc flags) or test
        # files. General omc flags go through the RTEST_OMCFLAGS env below, never as
        # a bare positional (which rtest would treat as a missing test file).
        argv = String["perl", rtest, "--return-with-error-code"]
        verbose && push!(argv, "-v")
        push!(argv, basename(mos))
        @info "[$i/$(length(cases))] rtest $(case.file)"
        t0 = time()
        out = IOBuffer()
        ok = try
            # Clear LD_LIBRARY_PATH so the spawned omc loads its own runtime
            # libraries instead of OM.jl's bundled ones (mirrors discovery.jl);
            # a polluted path makes omc fail with a shared-library symbol lookup error.
            withenv("RTEST_OMCFLAGS" => isempty(omcflags) ? nothing : omcflags,
                    "LD_LIBRARY_PATH" => "") do
                success(pipeline(Cmd(Cmd(argv); dir = rundir); stdout = out, stderr = out))
            end
        catch e
            print(out, sprint(showerror, e))
            false
        end
        dt = time() - t0
        text = String(take!(out))
        failed, total = _parse_rtest_summary(text)
        # exit-code success and a clean summary must agree; trust the summary when present.
        passed = total > 0 ? failed == 0 : ok
        push!(results, RtestResult(case, passed, failed, total, text, dt))
    end
    return results
end

function _parse_rtest_summary(text::AbstractString)::Tuple{Int, Int}
    m = match(r"==\s*(\d+)\s+out of\s+(\d+)\s+tests failed", text)
    m === nothing && return (0, 0)
    return (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
end

# ---------------------------------------------------------------------------
# Mode :omjl  — run testsuite model targets through the OM.jl pipeline
# ---------------------------------------------------------------------------

# Map an upstream loadModel version to the bundled MSL_Version the OM.jl
# by-name pipeline understands. Only 3.2.x and 4.0.0 are bundled.
function _bundled_msl_version(version::String)::Union{Nothing, String}
    isempty(version) && return nothing
    startswith(version, "3.2") && return "MSL:3.2.3"
    startswith(version, "4.0") && return "MSL:4.0.0"
    return nothing
end

"""
    testsuite_specs(cases; stopTime) -> Tuple{Vector{ModelSpec}, Vector{Tuple{TestsuiteCase,String}}}

Turn discovered cases into runnable `ModelSpec`s for the OM.jl pipeline. A case is
runnable when it loads a bundled MSL version and targets a `Modelica.*` class.
Returns the specs plus a list of (case, reason) pairs that were skipped.
"""
function testsuite_specs(cases::Vector{TestsuiteCase};
                          stopTime::Float64 = 1.0)
    specs = ModelSpec[]
    skipped = Tuple{TestsuiteCase, String}[]
    seen = Set{String}()
    for case in cases
        msl = _bundled_msl_version(case.version)
        if msl === nothing
            push!(skipped, (case, "unbundled or missing MSL version '$(case.version)'"))
            continue
        end
        modelica_targets = Base.filter(t -> startswith(t, "Modelica."), case.targets)
        if isempty(modelica_targets)
            push!(skipped, (case, "no Modelica.* target in script"))
            continue
        end
        for name in modelica_targets
            name in seen && continue
            push!(seen, name)
            key = _name_to_key(name)
            domain = _extract_domain(name)
            push!(specs, ModelSpec(name, key, domain, stopTime,
                                   UNKNOWN, Dict{String, Float64}(),
                                   0.01, 3e-3, "", Dict{String, String}(), "",
                                   Set{Phase}(), ""))
        end
    end
    return specs, skipped
end

"""
    run_testsuite_omjl(cases; msl_version, stopTime, from_phase, to_phase,
                       timeout, n_workers, check_sim_code) -> Vector{ModelResult}

Run the runnable model targets from `cases` through the OM.jl pipeline, reusing
the standard worker pool and `run_model`. Defaults stop at SIMULATE because the
upstream testsuite carries no validation CSVs in this harness.
"""
function run_testsuite_omjl(cases::Vector{TestsuiteCase};
                             msl_version::String = "MSL:3.2.3",
                             stopTime::Float64 = 1.0,
                             from_phase::Phase = FRONTEND,
                             to_phase::Phase = SIMULATE,
                             timeout::Float64 = 1000.0,
                             n_workers::Int = max(1, nprocs() - 1),
                             check_sim_code::Bool = false)::Vector{ModelResult}
    specs, skipped = testsuite_specs(cases; stopTime = stopTime)
    @info "OM.jl pipeline: $(length(specs)) runnable model targets, $(length(skipped)) cases skipped"
    isempty(specs) && return ModelResult[]
    phases = Base.filter(p -> Int(from_phase) <= Int(p) <= Int(to_phase), PHASE_ORDER)

    effective_workers = min(n_workers, length(specs))
    pool = WorkerPool(effective_workers; msl_version = msl_version)
    ensure_pool!(pool)
    indexed = Vector{Union{Nothing, ModelResult}}(nothing, length(specs))
    work = Channel{Tuple{Int, ModelSpec}}(length(specs))
    for (i, s) in enumerate(specs)
        put!(work, (i, s))
    end
    close(work)
    log_lock = ReentrantLock()
    started = Threads.Atomic{Int}(0)
    try
        @sync for (wi, mgr) in enumerate(pool.managers)
            @async for (i, spec) in work
                n = Threads.atomic_add!(started, 1) + 1
                lock(log_lock) do
                    @info "[$n/$(length(specs))] (W$wi) $(spec.name)"
                end
                indexed[i] = run_model(spec, mgr; timeout = timeout,
                                       phases_to_run = phases,
                                       check_sim_code = check_sim_code)
            end
        end
    finally
        cleanup!(pool)
    end
    return ModelResult[r for r in indexed if r !== nothing]
end

# ---------------------------------------------------------------------------
# Top-level entry
# ---------------------------------------------------------------------------

"""
    run_testsuite(; mode, fetch, ref, dest, subdir, filter, status, ...)

Main entry for the upstream OpenModelica `testsuite/` regression suite.

Steps: optionally `fetch` the sparse testsuite checkout, discover `.mos` cases
(restricted by `subdir`, `filter`, `status`), then run them in one of two modes:

  `mode = :omjl`  (default) run each test's model target through the OM.jl
                  FRONTEND -> BACKEND -> SIMULATE pipeline. Returns
                  `Vector{ModelResult}` (feed to `print_summary` / `generate_report`).
  `mode = :rtest` drive the upstream Perl `rtest` harness against the system
                  `omc`. Returns `Vector{RtestResult}`.

Keyword arguments:
  `fetch`      (true) sparse-clone / update the testsuite before running.
  `ref`        ("master") git ref to fetch.
  `dest`       cache directory for the checkout.
  `subdir`     restrict discovery to a testsuite subdirectory (e.g. "simulation").
  `filter`     regex over the repo-relative .mos path.
  `status`     ("correct") `// status:` header filter ("" keeps all).
  `limit`      cap the number of cases run (0 = no cap), applied after sorting.
Mode-specific kwargs are forwarded: `:omjl` accepts `msl_version, stopTime,
from_phase, to_phase, timeout, n_workers, check_sim_code`; `:rtest` accepts
`omcflags, verbose`.
"""
function run_testsuite(; mode::Symbol = :omjl,
                         fetch::Bool = true,
                         ref::String = "master",
                         dest::String = default_testsuite_cache(),
                         subdir::String = "",
                         filter::Regex = r"",
                         status::String = "correct",
                         limit::Int = 0,
                         kwargs...)
    mode in (:omjl, :rtest) || throw(ArgumentError("mode must be :omjl or :rtest, got :$mode"))
    testsuite_root = if fetch
        fetch_testsuite(; dest = dest, ref = ref, scaffold = mode == :rtest)
    else
        root = joinpath(dest, "OpenModelica", "testsuite")
        isdir(root) || error("No cached testsuite at $root; call with fetch=true first")
        root
    end
    cases = discover_testsuite_cases(testsuite_root; subdir = subdir,
                                     filter = filter, status = status)
    if limit > 0 && length(cases) > limit
        @info "Limiting to first $limit of $(length(cases)) cases"
        cases = cases[1:limit]
    end
    if mode == :rtest
        return run_rtest(cases, testsuite_root; kwargs...)
    else
        return run_testsuite_omjl(cases; kwargs...)
    end
end

"""
    print_rtest_summary(results)

Print a compact pass/fail summary for a `:rtest` run.
"""
function print_rtest_summary(results::Vector{RtestResult})
    total = length(results)
    passed = count(r -> r.passed, results)
    println()
    println("=" ^ 70)
    println("OpenModelica testsuite (rtest) summary")
    println("=" ^ 70)
    println("Tests:   $total")
    println("Passed:  $passed")
    println("Failed:  $(total - passed)")
    if passed < total
        println()
        println("Failing tests:")
        for r in results
            r.passed && continue
            println("  - $(r.case.file)  ($(r.failed_count)/$(r.total_count) sub-tests failed)")
        end
    end
    println("=" ^ 70)
    return nothing
end
