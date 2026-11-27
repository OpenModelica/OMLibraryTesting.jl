#=
Tests for the coverage site (src/site.jl): the funnel, a run's files, the history across runs
(a second run of the same date replaces the first), the badges and the index.
=#

using Dates
using TOML

@testset "Coverage site" begin
    local spec(name) = OLT.ModelSpec(name, name, "Test", 1.0, OLT.VALIDATE, Dict{String, Float64}(),
                                     0.0, 0.0, "", Dict{String, String}(), "", Set{OLT.Phase}())
    local result(name, highest) = OLT.ModelResult(spec(name), OLT.PhaseResult[], highest, "")
    local results = [result("A", OLT.VALIDATE), result("B", OLT.SIMULATE), result("C", OLT.FRONTEND),
                     result("D", OLT.BROKEN), result("E", OLT.UNKNOWN)]

    @test OLT.coverage_funnel(results) == ["frontend" => 3, "backend" => 2, "simulate" => 2, "validate" => 1]

    mktempdir() do site
        local report = joinpath(site, "in.html"); write(report, "<html>per model</html>")
        local analysis = joinpath(site, "in.md"); write(analysis, "# Coverage\n\n| Phase | Models |\n|---|---|\n| frontend | 3 |\n")
        local dir = OLT.publish_site(site, results; date = Date(2026, 10, 3), report, analysis,
                                     commits = ["OM.jl abc1234"], note = "test run")
        @test dir == joinpath(site, "runs", "2026-10-03")
        @test read(joinpath(dir, "report.html"), String) == "<html>per model</html>"
        @test occursin("<table>", read(joinpath(dir, "index.html"), String))
        @test TOML.parsefile(joinpath(dir, "summary.toml"))["validate"] == 1
        @test isfile(joinpath(site, ".nojekyll"))

        OLT.publish_site(site, results[1:2]; date = Date(2026, 10, 4))
        OLT.publish_site(site, results[1:4]; date = Date(2026, 10, 3))    # replaces the first run
        local history = OLT.site_history(site)
        @test [r["date"] for r in history] == ["2026-10-04", "2026-10-03"]
        @test history[2]["models"] == 4
        @test occursin("../runs/2026-10-04/", read(joinpath(site, "latest", "index.html"), String))
        local badge = read(joinpath(site, "badge.json"), String)
        @test occursin("\"message\": \"50.0 % (1/2)\"", badge) && occursin("\"color\": \"yellow\"", badge)
        @test isfile(joinpath(site, "badges", "frontend.json"))
        local index = read(joinpath(site, "index.html"), String)
        @test occursin("runs/2026-10-04/report.html", index) && occursin("<polyline", index)
        @test !occursin("<nav>", index)   # one version: no links to others

        #= Another MSL version: its own folder, history and badges; the indexes link each other. =#
        @test OLT.site_folder("3.2.3") == "" && OLT.site_folder("4.1.0") == "msl-4.1.0"
        local dir4 = OLT.publish_site(site, results[1:3]; version = "4.1.0", date = Date(2026, 10, 12),
                                      url = "https://example.org/cov")
        @test dir4 == joinpath(site, "msl-4.1.0", "runs", "2026-10-12")
        @test [r["date"] for r in OLT.site_history(joinpath(site, "msl-4.1.0"))] == ["2026-10-12"]
        @test [r["date"] for r in OLT.site_history(site)] == ["2026-10-04", "2026-10-03"]   # 3.2.3 untouched
        @test occursin("\"label\": \"MSL 4.1.0 validate\"", read(joinpath(site, "msl-4.1.0", "badge.json"), String))
        @test occursin("\"label\": \"MSL 3.2.3 validate\"", read(joinpath(site, "badge.json"), String))
        local index4 = read(joinpath(site, "msl-4.1.0", "index.html"), String)
        @test occursin("<a href=\"../\">MSL 3.2.3</a>", index4) && occursin("<strong>MSL 4.1.0</strong>", index4)
        @test occursin("https://example.org/cov/msl-4.1.0/badge.json", index4)
        @test occursin("<a href=\"msl-4.1.0/\">MSL 4.1.0</a>", read(joinpath(site, "index.html"), String))

        #= Another library: its folder after the MSL versions in every index, its badge on simulate, no README badge. =#
        local target::OLT.CoverageTarget = OLT.coverage_target(; library = "Buildings@13.0.0")
        @test target.folder == "lib-Buildings-13.0.0" && OLT.library_site_folder("ModelicaTest", "4.1.0+maint.om") == "lib-ModelicaTest-4.1.0_maint.om"
        local dirB = OLT.publish_site(site, results[1:3]; version = target.version, date = Date(2026, 11, 27),
                                      library = target.label, folder = target.folder, badge = OLT.SIMULATE)
        @test dirB == joinpath(site, "lib-Buildings-13.0.0", "runs", "2026-11-27")
        @test TOML.parsefile(joinpath(site, "lib-Buildings-13.0.0", "history.toml"))["library"] == "Buildings 13.0.0"
        @test occursin("\"label\": \"Buildings 13.0.0 simulate\"", read(joinpath(site, "lib-Buildings-13.0.0", "badge.json"), String))
        local indexB = read(joinpath(site, "lib-Buildings-13.0.0", "index.html"), String)
        @test occursin("<a href=\"../msl-4.1.0/\">MSL 4.1.0</a><strong>Buildings 13.0.0</strong>", indexB)
        @test occursin("go up to simulate", indexB) && !occursin("<h2>Badge</h2>", indexB)
        local indexRoot = read(joinpath(site, "index.html"), String)
        @test occursin("<a href=\"lib-Buildings-13.0.0/\">Buildings 13.0.0</a>", indexRoot) && occursin("<h2>Badge</h2>", indexRoot)
        @test occursin("\"label\": \"MSL 3.2.3 validate\"", read(joinpath(site, "badge.json"), String))
    end
end

@testset "Coverage target" begin
    local msl::OLT.CoverageTarget = OLT.coverage_target(; msl = "MSL:4.1.0")
    @test (msl.library, msl.version, msl.msl_version, msl.label, msl.folder, msl.references) ==
          ("Modelica", "4.1.0", "MSL:4.1.0", "MSL 4.1.0", "msl-4.1.0", true)
    @test msl.registry == OLT.default_models_path("4.1.0")
    local lib::OLT.CoverageTarget = OLT.coverage_target(; library = "ThermofluidStream@1.4.0")
    @test (lib.library, lib.version, lib.msl_version, lib.label, lib.references) ==
          ("ThermofluidStream", "1.4.0", "LIB:ThermofluidStream@1.4.0", "ThermofluidStream 1.4.0", false)
    @test basename(lib.registry) == "models_ThermofluidStream_1.4.0.toml"
    @test_throws ArgumentError OLT.coverage_target(; library = "Buildings")
    @test_throws ArgumentError OLT.coverage_target(; library = "Modelica@4.1.0")
    @test withenv(() -> OLT.coverage_target_from_env().folder, "OMJL_COVERAGE_LIBRARY" => "PNlib@3.0.0") == "lib-PNlib-3.0.0"
end
