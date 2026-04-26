#=
Placeholder for OMLibraryTesting comparison tests.

2026-04-23: An earlier attempt in this file added `step_hold_interpolate`
and `is_discrete_reference` helpers to `src/comparison.jl` and auto-routed
digital/enum signals through step-hold semantics inside `compare_signal`.
That was the wrong layer.

The symptom — Electrical.Digital flip-flop models (DFFREG*, DLATREG*,
DFFREGSR*) failing validate on signals like `dFFREG.dFFR.clock`,
`inertialDelaySensitive[i].x` — is caused by OMBackend not classifying
Modelica `Boolean` / `Integer` / 9-value-logic enum variables as
DISCRETE. Continuous integrators interpolate between event times, which
turns a legal Logic enum step (e.g. 3 → 1) into illegal intermediate
values (2). The reference CSV is already step-hold by construction (omc
emits at event times).

The fix belongs in OMBackend:
  - Classify `Boolean`, `Integer`, and single-module enum types as
    DISCRETE during BDAE -> SimCode -> MTK lowering (related to the
    architectural note in `.claude/CLAUDE.md`:
    "Friction FSM lowering produces rank-deficient Jacobian").
  - Emit these as MTK discrete variables / register a SaveCallback
    at event times so the SciML solution hands back step-hold values
    for `sol(t, idxs=discrete_var)`.
  - Once the backend emits step-hold values for digital signals,
    `interpolate_reference` here is correct as-is (both sides step
    piecewise-constant and Linear interpolation of (t0, v) to (t0+ε, v)
    is just v).

So no comparison-side change, and this test file is intentionally empty
until someone adds OMBackend-side tests that produce correct digital
solutions.
=#
