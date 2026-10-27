#=
Tests for the signals a validation compared (src/signals.jl): compare_signal keeps the values it
compared, the worker's tuples carry them, signals_json writes them, generate_report puts them next to
the report, and the site keeps them for the latest SIGNAL_RUNS_KEPT runs.
=#

using Dates
import OMLibraryTesting as OLT

#= A solution stand-in: `sol(t; idxs)` of one signal. =#
struct ValuesOf{F}
    f::F
end
(s::ValuesOf)(t; idxs = nothing) = s.f(t)

@testset "Compared signals" begin
    local ref = OLT.ReferenceData([0.0, 0.5, 1.0], Dict("x" => [0.0, 1.0, 2.0]))

    #= compare_signal keeps the reference's and OM.jl's values at the comparison times. =#
    local ok = OLT.compare_signal(ValuesOf(t -> 2t), ref, "x", 1.0; npoints = 5)
    @test ok.passed && ok.times == [0.0, 0.25, 0.5, 0.75, 1.0]
    @test ok.expected ≈ [0.0, 0.5, 1.0, 1.5, 2.0] && ok.actual ≈ ok.expected
    #= A comparison that stops at a non-finite value: OM.jl's values up to it, none after. =#
    local stopped = OLT.compare_signal(ValuesOf(t -> t < 0.5 ? 2t : Inf), ref, "x", 1.0; npoints = 5)
    @test !stopped.passed && stopped.actual[1:2] == [0.0, 0.5] && isinf(stopped.actual[3])
    @test all(isnan, stopped.actual[4:5]) && stopped.expected ≈ ok.expected
    #= A signal the reference does not have: nothing compared. =#
    @test isempty(OLT.compare_signal(ValuesOf(t -> 2t), ref, "y", 1.0; npoints = 5).times)

    #= A worker returns the comparisons as plain tuples; the parent rebuilds them. =#
    local back = OLT.SignalComparison(OLT._signal_tuple(stopped)...)
    @test back.name == "x" && back.times == stopped.times && isequal(back.actual, stopped.actual)

    local spec(name) = OLT.ModelSpec(name, name, "Test", 1.0, OLT.VALIDATE, Dict{String, Float64}(),
                                     1e-4, 3e-3, "", Dict{String, String}(), "", Set{OLT.Phase}())
    local validated = OLT.ModelResult(spec("A.\"quoted\""), OLT.PhaseResult[], OLT.VALIDATE, "", [ok])
    local failed = OLT.ModelResult(spec("B"), OLT.PhaseResult[], OLT.SIMULATE, "", [stopped])
    local none = OLT.ModelResult(spec("C"), OLT.PhaseResult[], OLT.FRONTEND, "")
    local results = [none, failed, validated]

    #= JSON by model: shared times as [first, last, count], 6 significant digits, null for none. =#
    local json = OLT.signals_json(results)
    @test startswith(json, "{\"models\":{\"A.\\\"quoted\\\"\":{\"validated\":true,\"atol\":0.0001,\"reltol\":0.003,")
    @test occursin("\"time\":[0.0,1.0,5]", json)
    @test occursin("\"reference\":[0.0,0.5,1.0,1.5,2.0],\"omjl\":[0.0,0.5,1.0,1.5,2.0]", json)
    @test occursin("\"B\":{\"validated\":false,", json) && occursin("\"omjl\":[0.0,0.5,null,null,null]", json)
    @test !occursin("\"C\"", json)
    @test count(==('{'), json) == count(==('}'), json) && count(==('['), json) == count(==(']'), json)

    mktempdir() do dir
        @test !OLT.write_signals(joinpath(dir, "none.json"), [none]) && !isfile(joinpath(dir, "none.json"))
        #= generate_report puts the signals next to the HTML report. =#
        local html = OLT.generate_report(results; dir, filename = "run.html")
        @test read(joinpath(dir, "run.signals.json"), String) == json
        #= The report links each model's signals (passed of compared) to its viewer. =#
        local page = read(html, String)
        @test occursin("data-model=\"A.&quot;quoted&quot;\"", page) && occursin(">signals 1/1</a>", page)
        @test occursin("class=\"sig-link sig-has-fail\" href=\"#\" data-model=\"B\"", page)
        @test !occursin("data-model=\"C\"", page) && occursin("function toggleSignals", page)

        #= The site: signals.json with each run, linked from its page, kept for the latest runs only. =#
        local site = joinpath(dir, "site")
        local first = OLT.publish_site(site, results; date = Date(2026, 11, 1), report = html)
        @test read(joinpath(first, "signals.json"), String) == json
        @test occursin("<a href=\"signals.json\">", read(joinpath(first, "index.html"), String))
        local without = OLT.publish_site(site, [none]; date = Date(2026, 11, 2))
        @test !isfile(joinpath(without, "signals.json"))
        @test !occursin("signals.json", read(joinpath(without, "index.html"), String))
        for day in 3:(OLT.SIGNAL_RUNS_KEPT + 2)    # the first run is no longer among the latest
            OLT.publish_site(site, results; date = Date(2026, 11, day))
        end
        @test !isfile(joinpath(first, "signals.json"))
        @test !occursin("signals.json", read(joinpath(first, "index.html"), String))
        local kept = filter(d -> isfile(joinpath(site, "runs", d, "signals.json")), readdir(joinpath(site, "runs")))
        @test length(kept) == OLT.SIGNAL_RUNS_KEPT && maximum(kept) == "2026-11-$(lpad(OLT.SIGNAL_RUNS_KEPT + 2, 2, '0'))"
    end
end
