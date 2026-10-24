# OMLibraryTesting.jl

[![MSL coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fopenmodelica.github.io%2FOMLibraryTesting.jl%2Fbadge.json)](https://openmodelica.github.io/OMLibraryTesting.jl/)
[![MSL 4.1.0 coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fopenmodelica.github.io%2FOMLibraryTesting.jl%2Fmsl-4.1.0%2Fbadge.json)](https://openmodelica.github.io/OMLibraryTesting.jl/msl-4.1.0/)

A Julia package for running MSL (Modelica Standard Library) coverage tests against [OM.jl](https://github.com/OpenModelica/OM.jl). It auto-discovers all experiment models in the MSL using `omc`, runs each through the OM.jl pipeline (flatten -> translate -> simulate -> validate), and generates HTML coverage reports.

## Overview

Each model is tested through up to four pipeline phases:

| Phase      | Description                                      |
|------------|--------------------------------------------------|
| `FRONTEND` | Flatten the Modelica model via OMFrontend.jl     |
| `BACKEND`  | Lower the flat model via OMBackend.jl            |
| `SIMULATE` | Solve the generated ODE/DAE system               |
| `VALIDATE` | Compare simulation output against reference data |

Results are compared against Dymola-generated reference trajectories from the MAP-LIB reference results repository.

## Latest coverage

<!-- coverage:begin (scripts/publish_coverage.jl) -->
Measured 2026-10-24 on 425 MSL 3.2.3 example models: frontend 422 (99.3 %), backend 422 (99.3 %), simulate 405 (95.3 %), validate 388 (91.3 %). Per domain and what stops the rest: [docs/COVERAGE.md](docs/COVERAGE.md).
<!-- coverage:end -->

<!-- coverage-4.1.0:begin (scripts/publish_coverage.jl) -->
Measured 2026-10-24 on 534 MSL 4.1.0 example models: frontend 533 (99.8 %), backend 530 (99.3 %), simulate 515 (96.4 %), validate 499 (93.4 %). Per domain and what stops the rest: [docs/COVERAGE_4.1.0.md](docs/COVERAGE_4.1.0.md).
<!-- coverage-4.1.0:end -->

Every published run, by date, with the trend: the [coverage site](https://openmodelica.github.io/OMLibraryTesting.jl/) (MSL 3.2.3; MSL 4.1.0 in [msl-4.1.0/](https://openmodelica.github.io/OMLibraryTesting.jl/msl-4.1.0/)).

## Directory Structure

```
OMLibraryTesting.jl/
├── src/
│   ├── OMLibraryTesting.jl   # Module entry point
│   ├── types.jl              # Phase enum, ModelSpec, ModelResult, PhaseResult
│   ├── registry.jl           # TOML override loader
│   ├── discovery.jl          # omc-based experiment discovery
│   ├── runner.jl             # WorkerManager and run_coverage orchestration
│   ├── comparison.jl         # CSV trajectory comparison
│   ├── analysis.jl           # Error categorization and analysis utilities
│   ├── report.jl             # HTML report generation
│   ├── site.jl               # Coverage site: one page per run, index, badges
│   └── testsuite.jl          # Fetch + run the upstream OpenModelica testsuite (rtest / OM.jl modes)
├── models/
│   ├── models.toml           # Per-model overrides (atol, reltol, expected phase, signal mapping), MSL 3.2.3
│   ├── models_4.1.0.toml     # The same for MSL 4.1.0
│   └── experiments_Modelica_<version>.txt  # The experiment models omc lists (record_experiments)
├── reference/
│   ├── csv/                  # Dymola reference CSVs (MAP-LIB, MSL 3.2.3)
│   ├── signals/              # Per-model comparisonSignals.txt files
│   ├── 4.1.0/                # The same for MSL 4.1.0 (csv/, signals/)
│   ├── download_refs.sh      # Script to fetch/refresh reference files from GitHub
│   └── generate_refs.mos     # OpenModelica script to generate reference results
├── docs/
│   ├── COVERAGE.md           # The latest published MSL 3.2.3 coverage (scripts/publish_coverage.jl)
│   └── COVERAGE_4.1.0.md     # The same for MSL 4.1.0
├── results/                  # Runtime output (ignored by git)
└── reports/                  # Generated coverage reports (ignored by git)
```

## Usage

```julia
using Pkg
Pkg.develop(path=".")   # or add via the parent OM.jl environment

import OMLibraryTesting

# Run full MSL coverage (auto-discovers ~425 experiment models)
results = OMLibraryTesting.run_coverage(msl_version = "MSL:3.2.3")

# Filter by domain
results = OMLibraryTesting.run_coverage(domain = "Thermal", msl_version = "MSL:3.2.3")

# Run a single model
results = OMLibraryTesting.run_coverage(model = "Modelica.Thermal.HeatTransfer.Examples.TwoMasses")

# MSL 4.1.0: its experiment list, registry (models/models_4.1.0.toml) and reference data
# (reference/4.1.0/); OMFrontend bundles 3.2.3 and 4.1.0 as single files (the resources a model
# reads come from the installed library: ~/.openmodelica/libraries, Modelica 4.1.0)
results = OMLibraryTesting.run_coverage(msl_version = "MSL:4.1.0")

# Generate an HTML report
OMLibraryTesting.generate_report(results)

# Print a summary to stdout
OMLibraryTesting.print_summary(results)

# Analyse failures
OMLibraryTesting.print_error_analysis(results)
```

The "Latest coverage" section above and docs/COVERAGE.md are published by the `MSL coverage` workflow
(.github/workflows/coverage.yml: MSL 3.2.3 weekly, MSL 4.1.0 every third day, or by hand from the Actions
tab with `msl` and `commit` set). It runs `scripts/run_full_coverage.jl` with `OMJL_COVERAGE_NOSKIP=1` (every
model through every phase) in two shard jobs (`OMJL_COVERAGE_SHARD=1/2` and `2/2`: every second model each,
within the 6-hour job limit); the publish job merges their results (`scripts/merge_coverage.jl`, which checks
that every model is there once) and passes them to the publisher. It also adds the run to the
coverage site, served by GitHub Pages from the `gh-pages` branch (`scripts/publish_site.jl`): `runs/<date>/` with
the analysis and the per-model report, an index over all runs, and the badges (`badge.json`, models that
validate; `badges/<phase>.json`); MSL 4.1.0 has the same in `msl-4.1.0/`, docs/COVERAGE_4.1.0.md and its own
section above. The same by hand (`OMJL_COVERAGE_MSL`, default `MSL:3.2.3`, selects the version for all three):

```bash
OMJL_COVERAGE_NOSKIP=1 julia --project=. scripts/run_full_coverage.jl
# or in shards, merged: OMJL_COVERAGE_SHARD=1/2 ... and 2/2 ..., then
#   julia --project=. scripts/merge_coverage.jl logs/partial_<tag1>_<ts>.jls logs/partial_<tag2>_<ts>.jls
julia --project=. scripts/publish_coverage.jl logs/partial_full_msl_<timestamp>.jls [commits.txt] ["how the run was made"]
julia --project=. scripts/publish_site.jl <gh-pages checkout> logs/partial_full_msl_<timestamp>.jls reports/<report>.html docs/COVERAGE.md [commits.txt] ["how the run was made"]
```

## Hot Validation Loop (`scripts/warm_validate.jl`)

`run_coverage` spawns cold worker processes that re-precompile the OM.jl stack after
every source edit, which costs minutes per cycle. For iterating on a single model from
a warm Julia REPL (with `using OM` done and Revise active), use the hot variant:

```julia
include("scripts/warm_validate.jl")

r = warm_validate("Modelica.Mechanics.MultiBody.Examples.Loops.Engine1a";
                  stopTime = 0.72, atol = 0.1, reltol = 0.05)
r.npass, r.nfail   # validation score
r.results          # per-signal table (signal, pass, maxerr, tmax, ours, ref, tol)
r.sol              # solution object for probing
```

What it does on each call:

* Forces a true rebuild (clears both the `OMBackend.IMTKGen.BUILT` problem cache and
  the `OMBackend.COMPILED_MODELS_MTK` generated-module cache, then re-runs
  `OM.translate`), so Revise-applied edits in any layer, including codegen, take
  effect. Pass `rebuild = false` to re-validate the cached build when only sampling
  or tolerances changed.
* Simulates in-process and samples saved steps (`dense = false`) on the same 21-point
  grid the harness uses, comparing every reference-CSV signal with the combined
  tolerance `|err| <= atol + reltol * |ref|`.

Keyword arguments mirror the `models.toml` overrides: `stopTime`, `atol`, `reltol`,
`npoints`, `referenceFile`, `msl_version`, `solverKwargs`, `quiet`.

The hot loop is for iteration; `run_coverage` remains the authoritative cold gate
before promoting a model in `models/models.toml`.

## OpenModelica `testsuite/` Regression Suite (`src/testsuite.jl`)

In addition to MSL coverage, the harness can fetch and run the upstream
[OpenModelica `testsuite/`](https://github.com/OpenModelica/OpenModelica/tree/master/testsuite)
regression tests (the `.mos` cases the `rtest` Perl harness drives). The first call
sparse-clones only the `testsuite/` directory (partial, cone-mode checkout) into
`.testsuite_cache/`; later calls reuse it.

Two run modes share one fetch + discovery front-end:

| Mode      | What it tests | Returns |
|-----------|---------------|---------|
| `:omjl`   | Each test's model target through the OM.jl `FRONTEND -> BACKEND -> SIMULATE` pipeline (reuses `run_model` / the worker pool). | `Vector{ModelResult}` |
| `:rtest`  | The upstream Perl `rtest` harness against the system `omc` (tests the C compiler). | `Vector{RtestResult}` |

```julia
import OMLibraryTesting

# OM.jl pipeline over a testsuite subdirectory (default mode)
results = OMLibraryTesting.run_testsuite(; mode = :omjl,
                                           subdir = "simulation/modelica/equations",
                                           limit = 20)
OMLibraryTesting.print_summary(results)

# Upstream rtest harness against system omc
rs = OMLibraryTesting.run_testsuite(; mode = :rtest,
                                      subdir = "flattening/modelica/scodeinst",
                                      status = "correct", limit = 20)
OMLibraryTesting.print_rtest_summary(rs)
```

Selected keywords (`run_testsuite`):

* `fetch` (true) sparse-clone / update the testsuite first; `ref` ("master") git ref;
  `dest` cache dir. Pass `fetch = false` to skip the network and reuse the cache.
* `subdir` restrict discovery to a testsuite subdirectory; `filter` regex over the
  repo-relative `.mos` path; `status` (default `"correct"`) `// status:` header filter;
  `limit` cap the number of cases.
* `:omjl` forwards `msl_version, stopTime, from_phase, to_phase, timeout, n_workers,
  check_sim_code`; `:rtest` forwards `omcflags, verbose`.

Notes and limitations:

* `:omjl` mode only runs cases that load a **bundled** MSL version (3.2.x, or 4.x as 4.1.0)
  and target a `Modelica.*` class. Cases using MSL trunk, third-party libraries,
  or inline-defined models are reported as skipped with a reason. It stops at
  `SIMULATE` by default because the testsuite ships no validation CSVs in this harness.
* `:rtest` mode needs `omc-diff` in the scaffolded OPENMODELICAHOME. `fetch_testsuite`
  builds it from `testsuite/difftool` when possible; that build requires `flex` plus a
  C compiler. If `flex` is missing, install it (e.g. `sudo apt-get install flex`) and
  re-run `fetch_testsuite`, otherwise `run_rtest` raises with a clear message.

A convenience wrapper lives in `scripts/run_testsuite.jl`.

## Model Registry (`models/models.toml`)

The TOML file stores per-model overrides. The model list itself is always auto-discovered from omc. Example entry:

```toml
[models."Modelica.Mechanics.MultiBody.Examples.Elementary.Pendulum"]
expected = "validate"
referenceFile = "Modelica.Mechanics.MultiBody.Examples.Elementary.Pendulum.csv"
atol = 1e-3
reltol = 1e-3

[models."Modelica.Mechanics.MultiBody.Examples.Elementary.Pendulum".signalMapping]
"rev.phi" = "revolute1_phi"
```

### Signal Name Mapping

Reference CSVs use Modelica dot notation (e.g., `rev.phi`). OM.jl uses underscore notation (e.g., `revolute1_phi`). The default mapping converts dots to underscores. Add a `signalMapping` table for models where names differ between the reference and OM.jl output.

## Reference Data

Reference trajectories come from the MAP-LIB Dymola reference results (branch v3.2.3, and v4.1.0 for MSL 4.1.0). Run `reference/download_refs.sh` (MSL 3.2.3) or `reference/download_refs.sh --msl 4.1.0` to fetch or refresh them.

## License

GPL v3 / OSMC Public License 1.2. See `LICENSE.md`.
