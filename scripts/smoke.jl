#=
Quick smoke test of the harness with OM.jl: the given MSL models through every phase, each of
which must validate. Pull requests run it (.github/workflows/smoke.yml); the coverage runs
measure everything.

    julia --project=. scripts/smoke.jl MSL:<version> <model>...

The models' reference data must be there first: reference/download_refs.sh [--msl <version>]
with the models' short names (Modelica.Blocks.Examples.PID_Controller -> Blocks_Examples_PID_Controller).
=#

import OMLibraryTesting as OLT

length(ARGS) >= 2 || error("usage: smoke.jl MSL:<version> <model>...")
const MSL = ARGS[1]
const MODELS = ARGS[2:end]

const RESULTS = OLT.run_coverage(; msl_version = MSL, n_workers = 1, timeout = 900.0,
                                 filter = Regex("^(" * join(replace.(MODELS, "." => "\\."), "|") * ")\$"))
const REACHED = Dict(r.spec.name => r.highest for r in RESULTS)
const FAILED = [m for m in MODELS if get(REACHED, m, OLT.UNKNOWN) != OLT.VALIDATE]
for m in MODELS
    println(rpad(m, 70), get(REACHED, m, "not run"))
end
isempty(FAILED) || error("$(length(FAILED)) of $(length(MODELS)) $MSL models do not validate: $(join(FAILED, ", "))")
println("Smoke ($MSL): every model validates ($(length(MODELS)))")
