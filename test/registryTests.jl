#=
The registry against the reference data. A stopTime past the end of its
reference compares samples with the reference's last value, frozen: on
2026-09-29 twelve entries did (Engine1b at 0.72 s, copied from Engine1a,
against a reference that ends at its StopTime 0.5 s; Rotational Friction at
Translational Friction's 5 s). Two entries of one model make the effective
one depend on Dict order.
=#

import OMLibraryTesting as OLT

@testset "registry $version: stopTimes within the reference data, one entry per model" for version in ("3.2.3", "4.1.0")
    local path = OLT.default_models_path(version)
    local reg = OLT.TOML.parsefile(path)["models"]
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
        local f = joinpath(OLT.reference_dir(path, version), "csv", rf * ".csv")
        isfile(f) || continue
        OLT.stoptime_within_reference(s["stopTime"], refEnd(f)) || push!(past, key)
    end
    @test isempty(past)
end

@testset "per-version registry, reference data and MSL loading" begin
    local models = normpath(joinpath(@__DIR__, "..", "models"))
    local reference = normpath(joinpath(@__DIR__, "..", "reference"))
    @test OLT.msl_library_version("MSL:4.1.0") == "4.1.0"
    @test normpath(OLT.default_models_path("3.2.3")) == joinpath(models, "models.toml")
    @test normpath(OLT.default_models_path("4.1.0")) == joinpath(models, "models_4.1.0.toml")
    @test OLT.reference_dir(OLT.default_models_path("3.2.3"), "3.2.3") == reference
    @test OLT.reference_dir(OLT.default_models_path("4.1.0"), "4.1.0") == joinpath(reference, "4.1.0")
    @test OLT.load_registry_meta(OLT.default_models_path("4.1.0"))["msl_version"] == "MSL:4.1.0"
    #= Every 4.1.0 entry is an experiment of 4.1.0. =#
    local experiments = Set(first(split(l, '|')) for l in eachline(joinpath(models, "experiments_Modelica_4.1.0.txt")))
    @test all(e -> e["name"] in experiments, values(OLT.TOML.parsefile(OLT.default_models_path("4.1.0"))["models"]))
    #= Bundled versions by MSL_Version; others are installed libraries (not loaded here). =#
    @test OLT._msl_kwargs("MSL:3.2.3") == (; MSL_Version = "MSL:3.2.3")
    @test OLT._msl_kwargs("MSL:4.1.0") == (; MSL_Version = "MSL:4.1.0")
end
