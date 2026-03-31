# OMLibraryTesting.jl

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
│   └── report.jl             # HTML report generation
├── models/
│   └── models.toml           # Per-model overrides (atol, reltol, expected phase, signal mapping)
├── reference/
│   ├── csv/                  # Dymola reference CSVs (MAP-LIB, MSL 3.2.3)
│   ├── signals/              # Per-model comparisonSignals.txt files
│   ├── download_refs.sh      # Script to fetch/refresh reference files from GitHub
│   └── generate_refs.mos     # OpenModelica script to generate reference results
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

# Generate an HTML report
OMLibraryTesting.generate_report(results)

# Print a summary to stdout
OMLibraryTesting.print_summary(results)

# Analyse failures
OMLibraryTesting.print_error_analysis(results)
```

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

Reference trajectories come from the MAP-LIB Dymola reference results (MSL 3.2.3 branch). Run `reference/download_refs.sh` to fetch or refresh them.

## License

GPL v3 / OSMC Public License 1.2. See `LICENSE.md`.
