#=
* This file is part of OpenModelica.
*
* Copyright (c) 1998-CurrentYear, Open Source Modelica Consortium (OSMC),
* c/o Linköpings universitet, Department of Computer and Information Science,
* SE-58183 Linköping, Sweden.
*
* All rights reserved.
*
* THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
* THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
* ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
* RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
* ACCORDING TO RECIPIENTS CHOICE.
*
* The OpenModelica software and the Open Source Modelica
* Consortium (OSMC) Public License (OSMC-PL) are obtained
* from OSMC, either from the above address,
* from the URLs: http:www.ida.liu.se/projects/OpenModelica or
* http:www.openmodelica.org, and in the OpenModelica distribution.
* GNU version 3 is obtained from: http:www.gnu.org/copyleft/gpl.html.
*
* This program is distributed WITHOUT ANY WARRANTY; without
* even the implied warranty of  MERCHANTABILITY or FITNESS
* FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
* IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
*
* See the full OSMC Public License conditions for more details.
*
*/ =#

#= A static coverage site (served by GitHub Pages from the gh-pages branch): one directory per
   measured date, an index over all runs with the trend, and shields.io endpoint badges.
   scripts/publish_site.jl adds a run; the MSL coverage workflow calls it after each run.

   site/
     index.html              all runs, the latest funnel, the trend
     history.toml            one [[runs]] entry per date (the index is rebuilt from it)
     badge.json              shields.io endpoint: models that validate
     badges/<phase>.json     the same per phase
     latest/index.html       redirect to the latest run
     runs/<date>/index.html  the run's analysis (docs/COVERAGE.md rendered)
     runs/<date>/report.html the per-model report (generate_report)
     runs/<date>/summary.toml =#

const SITE_PHASES = (FRONTEND, BACKEND, SIMULATE, VALIDATE)

coverage_ok(r::ModelResult) = r.highest != BROKEN && r.highest != UNKNOWN
coverage_reached(r::ModelResult, p::Phase) = coverage_ok(r) && r.highest >= p

"""
    coverage_funnel(results) -> Vector{Pair{String, Int}}

The number of models that reached each phase, frontend through validate. A BROKEN or UNKNOWN
result reaches none.
"""
coverage_funnel(results::Vector{ModelResult}) =
    [PHASE_NAMES[p] => count(r -> coverage_reached(r, p), results) for p in SITE_PHASES]

"""
    site_folder(version) -> String

The folder of MSL `version`'s runs on the coverage site: the root (`""`) for 3.2.3, the version
covered first, `msl-<version>` for another.
"""
site_folder(version::AbstractString)::String =
    version == TOP_LEVEL_MSL_VERSION ? "" : "msl-$version"

"""
    publish_site(site, results; version = "3.2.3", date = today(), report = "", analysis = "",
                 commits = String[], note = "", library = "MSL <version>", url = "") -> String

Add a coverage run of MSL `version` to the static site in the directory `site` (created if
missing), in the version's folder (`site_folder`), and rebuild that folder's index, badges and
`latest` redirect; every version's index links to the other versions. Runs are keyed by `date`: a
second run of the same date replaces the first. `report` is the HTML report of `generate_report`,
`analysis` the Markdown of scripts/publish_coverage.jl (docs/COVERAGE.md), `commits` lines such as
"OMBackend.jl f661a4a", `url` the site's address (for the badge snippet). Returns the run's directory.
"""
function publish_site(site::AbstractString, results::Vector{ModelResult};
                      version::AbstractString = TOP_LEVEL_MSL_VERSION, date::Date = today(),
                      report::AbstractString = "", analysis::AbstractString = "",
                      commits::Vector{String} = String[], note::AbstractString = "",
                      library::AbstractString = "MSL $version", url::AbstractString = "")
    local run = Dict{String, Any}("date" => string(date), "models" => length(results),
                                  "note" => String(note), "commits" => commits)
    for (p, c) in coverage_funnel(results)
        run[p] = c
    end
    local folder = site_folder(version)
    local here = joinpath(site, folder)
    local dir = joinpath(here, "runs", string(date))
    mkpath(dir)
    isempty(report) || cp(report, joinpath(dir, "report.html"); force = true)
    local hasSignals::Bool = write_signals(joinpath(dir, "signals.json"), results)
    hasSignals || rm(joinpath(dir, "signals.json"); force = true)    # a replaced run's
    open(io -> TOML.print(io, run; sorted = true), joinpath(dir, "summary.toml"), "w")
    write(joinpath(dir, "index.html"), _site_run_page(run, isempty(analysis) ? "" : read(analysis, String),
                                                      !isempty(report), library, hasSignals))
    local history = filter(r -> r["date"] != run["date"], site_history(here))
    push!(history, run)
    sort!(history; by = r -> r["date"], rev = true)
    _prune_signals!(here, history)
    open(io -> TOML.print(io, Dict("runs" => history); sorted = true), joinpath(here, "history.toml"), "w")
    local versions = _site_versions(site)
    _write_site_index(here, history, library, url, versions, folder)
    #= The other versions' indexes, for their links to this one. =#
    for (label, other) in versions
        other == folder && continue
        local d = joinpath(site, other)
        _write_site_index(d, site_history(d), label, url, versions, other)
    end
    return dir
end

#= The compared signals stay with the latest SIGNAL_RUNS_KEPT runs of a version's `history` (newest
   first): the older runs' signals.json is removed, and their pages no longer link it. =#
function _prune_signals!(here::AbstractString, history::Vector{Dict{String, Any}})::Nothing
    for run in history[(SIGNAL_RUNS_KEPT + 1):end]
        local dir = joinpath(here, "runs", run["date"])
        local path = joinpath(dir, "signals.json")
        isfile(path) || continue
        rm(path)
        local page = joinpath(dir, "index.html")
        isfile(page) && write(page, replace(read(page, String), _SIGNALS_LINK => ""))
    end
    return nothing
end

const _SIGNALS_LINK = "<a href=\"signals.json\">signals.json</a>"

#= The MSL versions with runs on the site, as (label, folder) pairs: 3.2.3 at the root first,
   then the msl-<version> folders. =#
function _site_versions(site::AbstractString)::Vector{Tuple{String, String}}
    local versions = Tuple{String, String}[]
    isfile(joinpath(site, "history.toml")) && push!(versions, ("MSL $TOP_LEVEL_MSL_VERSION", ""))
    for d in sort(readdir(site))
        local m = match(r"^msl-(.+)$", d)
        m !== nothing && isfile(joinpath(site, d, "history.toml")) && push!(versions, ("MSL $(m[1])", d))
    end
    return versions
end

#= The link from the index of `folder` to the index of `target` (folders of _site_versions). =#
function _site_link(folder::AbstractString, target::AbstractString)::String
    local up = isempty(folder) ? "" : "../"
    isempty(target) && return isempty(up) ? "./" : up
    return "$up$target/"
end

"""
    site_history(site) -> Vector{Dict{String, Any}}

The runs recorded in `site/history.toml`, newest first (empty for a new site).
"""
function site_history(site::AbstractString)
    local path = joinpath(site, "history.toml")
    isfile(path) || return Dict{String, Any}[]
    return sort!(Vector{Dict{String, Any}}(get(TOML.parsefile(path), "runs", Any[])); by = r -> r["date"], rev = true)
end

_site_pct(n, total) = total == 0 ? 0.0 : 100n / total
_site_pctstr(n, total) = string(round(_site_pct(n, total); digits = 1), " %")

function _badge_color(pct)
    pct >= 90 && return "brightgreen"
    pct >= 75 && return "green"
    pct >= 60 && return "yellowgreen"
    pct >= 40 && return "yellow"
    pct >= 20 && return "orange"
    return "red"
end

_json_string(s) = string('"', replace(s, "\\" => "\\\\", "\"" => "\\\""), '"')

function _write_badge(path, label, n, total)
    mkpath(dirname(path))
    write(path, string("{\"schemaVersion\": 1, \"label\": ", _json_string(label),
                       ", \"message\": ", _json_string("$(_site_pctstr(n, total)) ($n/$total)"),
                       ", \"color\": ", _json_string(_badge_color(_site_pct(n, total))), "}\n"))
end

function _write_site_index(site::AbstractString, history::Vector{Dict{String, Any}}, library::AbstractString,
                           url::AbstractString, versions::Vector{Tuple{String, String}}, folder::AbstractString)
    local latest = first(history)
    _write_badge(joinpath(site, "badge.json"), "$library validate", latest["validate"], latest["models"])
    for p in SITE_PHASES
        local name = PHASE_NAMES[p]
        _write_badge(joinpath(site, "badges", "$name.json"), "$library $name", latest[name], latest["models"])
    end
    mkpath(joinpath(site, "latest"))
    write(joinpath(site, "latest", "index.html"), string("""<!doctype html><meta charset="utf-8">
        <meta http-equiv="refresh" content="0; url=../runs/$(latest["date"])/">
        <title>Latest coverage</title><a href="../runs/$(latest["date"])/">Latest coverage: $(latest["date"])</a>
        """))
    touch(joinpath(site, ".nojekyll"))   # plain files, no Jekyll build
    write(joinpath(site, "index.html"), _site_index_page(history, library, url, versions, folder))
end

const _SITE_CSS = """
:root { --bg: #ffffff; --fg: #111418; --muted: #5b6470; --line: #d9dee5; --accent: #1f5fa8;
        --bar: #e8eef6; --frontend: #7aa7d9; --backend: #4f86c6; --simulate: #2c66ab; --validate: #0f3f7a; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0f1216; --fg: #e8ebef; --muted: #9aa4b0; --line: #2a313a; --accent: #7fb2ec;
          --bar: #1b222b; --frontend: #3d6a99; --backend: #4f86c6; --simulate: #7aa7d9; --validate: #b5d2f2; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg);
       font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
main { max-width: 960px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 1.6em; margin: 0 0 4px; } h2 { font-size: 1.2em; margin: 32px 0 8px; }
p.lead, .muted { color: var(--muted); }
a { color: var(--accent); }
nav { margin-bottom: 16px; } nav a, nav strong { margin-right: 16px; }
.table-wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th:first-child, td:first-child { text-align: left; }
th { font-weight: 600; color: var(--muted); }
.funnel { display: grid; grid-template-columns: 6em 1fr 8.5em; gap: 6px 12px; align-items: center; }
.funnel .track { background: var(--bar); height: 14px; border-radius: 3px; overflow: hidden; }
.funnel .fill { height: 100%; }
.funnel .num { text-align: right; font-variant-numeric: tabular-nums; }
svg text { fill: var(--muted); font-size: 11px; }
.legend span { display: inline-block; margin-right: 14px; } .legend i { display: inline-block; width: 10px; height: 10px; margin-right: 5px; border-radius: 2px; }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
pre { background: var(--bar); padding: 10px 12px; border-radius: 4px; overflow-x: auto; }
.analysis td { white-space: normal; }
"""

_site_page(title, body) = string("""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>""", html_escape(String(title)), "</title><style>", _SITE_CSS, "</style></head>\n<body><main>\n", body,
    "\n</main></body></html>\n")

function _site_funnel(run)
    local io = IOBuffer()
    println(io, "<div class=\"funnel\">")
    for p in SITE_PHASES
        local name = PHASE_NAMES[p]
        local pct = _site_pct(run[name], run["models"])
        println(io, "<div>$name</div><div class=\"track\"><div class=\"fill\" style=\"width: $(round(pct; digits = 1))%; background: var(--$name)\"></div></div>",
                "<div class=\"num\">$(run[name]) · $(_site_pctstr(run[name], run["models"]))</div>")
    end
    println(io, "</div>")
    return String(take!(io))
end

#= The share of models reaching each phase over the runs, oldest left; one SVG polyline per phase. =#
function _site_trend(history)
    local runs = reverse(history)
    local w, h, l, r, t, b = 900, 220, 40, 12, 10, 26
    local n = length(runs)
    local x(i) = n == 1 ? l + (w - l - r) / 2 : l + (i - 1) * (w - l - r) / (n - 1)
    local y(pct) = t + (100 - pct) * (h - t - b) / 100
    local io = IOBuffer()
    println(io, "<svg viewBox=\"0 0 $w $h\" width=\"100%\" role=\"img\" aria-label=\"Coverage per run\">")
    for g in 0:25:100
        println(io, "<line x1=\"$l\" x2=\"$(w - r)\" y1=\"$(y(g))\" y2=\"$(y(g))\" style=\"stroke: var(--line)\"/>",
                "<text x=\"$(l - 6)\" y=\"$(y(g) + 4)\" text-anchor=\"end\">$g%</text>")
    end
    local step = max(1, cld(n, 8))
    for (i, run) in enumerate(runs)
        (i - 1) % step == 0 || i == n || continue
        local anchor = n == 1 ? "middle" : i == 1 ? "start" : i == n ? "end" : "middle"
        println(io, "<text x=\"$(x(i))\" y=\"$(h - 8)\" text-anchor=\"$anchor\">$(run["date"])</text>")
    end
    for p in SITE_PHASES
        local name = PHASE_NAMES[p]
        local pts = join(("$(round(x(i); digits = 1)),$(round(y(_site_pct(run[name], run["models"])); digits = 1))"
                          for (i, run) in enumerate(runs)), " ")
        n > 1 && println(io, "<polyline points=\"$pts\" style=\"fill: none; stroke: var(--$name); stroke-width: 2\"/>")
        for (i, run) in enumerate(runs)
            println(io, "<circle cx=\"$(round(x(i); digits = 1))\" cy=\"$(round(y(_site_pct(run[name], run["models"])); digits = 1))\" r=\"3\" style=\"fill: var(--$name)\">",
                    "<title>$(run["date"]) $name $(run[name])/$(run["models"])</title></circle>")
        end
    end
    println(io, "</svg>")
    println(io, "<div class=\"legend muted\">", join(("<span><i style=\"background: var(--$(PHASE_NAMES[p]))\"></i>$(PHASE_NAMES[p])</span>"
                                                     for p in SITE_PHASES)), "</div>")
    return String(take!(io))
end

function _site_index_page(history::Vector{Dict{String, Any}}, library::AbstractString, url::AbstractString,
                          versions::Vector{Tuple{String, String}}, folder::AbstractString)
    local latest = first(history)
    local io = IOBuffer()
    if length(versions) > 1
        println(io, "<nav>", join((other == folder ? "<strong>$(html_escape(label))</strong>" :
                                   "<a href=\"$(_site_link(folder, other))\">$(html_escape(label))</a>"
                                   for (label, other) in versions)), "</nav>")
    end
    println(io, "<h1>OM.jl coverage of the $(html_escape(String(library))) examples</h1>")
    println(io, "<p class=\"lead\">Each experiment model goes through OM.jl's pipeline: flatten (frontend), translate (backend), ",
            "simulate, and validate against the reference trajectories. Measured by ",
            "<a href=\"https://github.com/OpenModelica/OMLibraryTesting.jl\">OMLibraryTesting.jl</a>.</p>")
    println(io, "<h2>Latest: <a href=\"runs/$(latest["date"])/\">$(latest["date"])</a>, $(latest["models"]) models</h2>")
    println(io, _site_funnel(latest))
    println(io, "<h2>Per run</h2>", _site_trend(history))
    println(io, "<div class=\"table-wrap\"><table><tr><th>Date</th><th>Models</th>",
            join(("<th>$(PHASE_NAMES[p])</th>" for p in SITE_PHASES)), "<th></th></tr>")
    for run in history
        local cells = join(("<td>$(run[PHASE_NAMES[p]]) <span class=\"muted\">($(_site_pctstr(run[PHASE_NAMES[p]], run["models"])))</span></td>"
                            for p in SITE_PHASES))
        println(io, "<tr><td><a href=\"runs/$(run["date"])/\">$(run["date"])</a></td><td>$(run["models"])</td>", cells,
                "<td><a href=\"runs/$(run["date"])/report.html\">per model</a></td></tr>")
    end
    println(io, "</table></div>")
    println(io, "<h2>Badge</h2><p class=\"muted\">The share of models that validate in the latest run ",
            "(<code>badge.json</code>; <code>badges/&lt;phase&gt;.json</code> per phase), for a README:</p>")
    local base = isempty(url) ? "&lt;this site&gt;/" :
                 html_escape(String(rstrip(url, '/') * "/" * (isempty(folder) ? "" : "$folder/")))
    println(io, "<pre>[![Coverage](https://img.shields.io/endpoint?url=$(base)badge.json)]($base)</pre>")
    return _site_page("OM.jl coverage", String(take!(io)))
end

function _site_run_page(run, analysis, hasReport, library, hasSignals::Bool = false)
    local io = IOBuffer()
    print(io, "<nav><a href=\"../../\">All runs</a>")
    hasReport && print(io, "<a href=\"report.html\">Per-model report</a>")
    hasSignals && print(io, _SIGNALS_LINK)
    println(io, "<a href=\"summary.toml\">summary.toml</a></nav>")
    if !isempty(analysis)    # it names the note and the commits itself
        println(io, "<div class=\"analysis table-wrap\">", Markdown.html(Markdown.parse(analysis)), "</div>")
    else
        println(io, "<h1>$(html_escape(String(library))) coverage, $(run["date"])</h1>", _site_funnel(run))
        isempty(run["note"]) || println(io, "<p class=\"muted\">", html_escape(run["note"]), "</p>")
        isempty(run["commits"]) || println(io, "<p class=\"muted\">Commits: ", html_escape(join(run["commits"], ", ")), "</p>")
    end
    return _site_page("OM.jl coverage $(run["date"])", String(take!(io)))
end
