#=
The registry against the reference data. A stopTime past the end of its
reference compares samples with the reference's last value, frozen: on
2026-09-29 twelve entries did (Engine1b at 0.72 s, copied from Engine1a,
against a reference that ends at its StopTime 0.5 s; Rotational Friction at
Translational Friction's 5 s). Two entries of one model make the effective
one depend on Dict order.
=#

import OMLibraryTesting as OLT

@testset "registry: stopTimes within the reference data, one entry per model" begin
    local root = joinpath(@__DIR__, "..")
    local reg = OLT.TOML.parsefile(joinpath(root, "models", "models.toml"))["models"]
    local names = [s["name"] for s in values(reg)]
    local dups = sort!(unique!([n for n in names if count(==(n), names) > 1]))
    @test isempty(dups)
    local refEnd(f) = (local lastLine = ""; for l in eachline(f); lastLine = l; end;
                       parse(Float64, strip(first(split(lastLine, ',')), ['"', ' ', '\t', '\r'])))
    #= Entries without a stopTime take the MSL experiment's, which the
       runtime guard in validate_against_reference checks. =#
    local past = String[]
    for (key, s) in reg
        haskey(s, "stopTime") || continue
        local rf = get(s, "referenceFile", "")
        isempty(rf) && (rf = OLT._model_name_to_ref_key(s["name"]))
        local f = joinpath(root, "reference", "csv", rf * ".csv")
        isfile(f) || continue
        OLT.stoptime_within_reference(s["stopTime"], refEnd(f)) || push!(past, key)
    end
    @test isempty(past)
end
