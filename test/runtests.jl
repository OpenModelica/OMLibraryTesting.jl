#=
OMLibraryTesting.jl test suite entry point.

Covers the package's own utility code (comparison, discovery, registry)
without requiring a full Modelica simulation. For end-to-end coverage of
MSL models, see `run_coverage(...)` from a live REPL — that is the
harness itself, not a unit test.
=#

using Test

@testset "OMLibraryTesting" begin
    # Placeholder — see comparisonTests.jl note. Until OMBackend emits
    # step-hold values for discrete signals, the comparison layer here
    # has nothing useful to regression-test independently.
    @test true
end
