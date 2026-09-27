#=
OMLibraryTesting.jl test suite entry point.

Covers the package's own code without running a Modelica model. The runner
tests spawn a worker process that loads OM and DifferentialEquations, so they
need the package's full environment. For end-to-end coverage of
MSL models, see `run_coverage(...)` from a live REPL — that is the
harness itself, not a unit test.
=#

using Test

@testset "OMLibraryTesting" begin
    # Placeholder — see comparisonTests.jl note. Until OMBackend emits
    # step-hold values for discrete signals, the comparison layer here
    # has nothing useful to regression-test independently.
    @test true
    include("runnerTests.jl")
end
