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
    end
end
