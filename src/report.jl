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

const DEFAULT_REPORTS_DIR = joinpath(@__DIR__, "..", "reports")

function phase_cell(results::Vector{PhaseResult}, target::Phase)
    idx = findfirst(r -> r.phase == target, results)
    if isnothing(idx)
        return "<td class=\"na\">&mdash;</td>"
    end
    r = results[idx]
    time_str = "$(round(r.time_s, digits=1))s"
    if r.success
        return "<td class=\"ok\">&#10003; $time_str</td>"
    else
        tooltip = isnothing(r.error) ? "" : " title=\"$(html_escape(r.error))\""
        return "<td class=\"fail\"$tooltip>&#10007; $time_str</td>"
    end
end

function html_escape(s::String)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    s = replace(s, "\"" => "&quot;")
    return s
end

"""
    generate_report(results; format=:html, dir, changelog, msl_version, total_time,
                    filename="", name_tag="") -> String

Generate a timestamped coverage report and save it to `dir`.

`format` must be `:html` or `:markdown`.
`changelog` is an optional string describing changes since the last run.

Filename resolution (first non-empty wins):
  1. `filename` — absolute override. If it has no extension, the format extension is appended.
  2. `name_tag` — inserted into the default template: `coverage_{name_tag}_{yyyy-mm-dd_HHMM}.{ext}`.
  3. default template: `coverage_{yyyy-mm-dd_HHMM}.{ext}`.

Returns the path to the saved report file.
"""
function generate_report(results::Vector{ModelResult};
                         format::Symbol = :html,
                         dir::String = DEFAULT_REPORTS_DIR,
                         changelog::String = "",
                         msl_version::String = "3.2.3",
                         total_time::Float64 = 0.0,
                         filename::String = "",
                         name_tag::String = "")
    if format !== :html && format !== :markdown
        error("Invalid format $(repr(format)). Must be :html or :markdown.")
    end
    mkpath(dir)
    ts = Dates.format(Dates.now(), "yyyy-mm-dd_HHMM")
    ext = format === :html ? "html" : "md"
    fname = if !isempty(filename)
        isnothing(findfirst('.', filename)) ? "$(filename).$(ext)" : filename
    elseif !isempty(name_tag)
        "coverage_$(name_tag)_$(ts).$(ext)"
    else
        "coverage_$(ts).$(ext)"
    end
    filepath = joinpath(dir, fname)

    total = length(results)
    broken = count(r -> r.spec.expected == BROKEN, results)
    tested = total - broken
    frontend_pass = count(r -> r.highest >= FRONTEND, results)
    backend_pass = count(r -> r.highest >= BACKEND, results)
    simulate_pass = count(r -> r.highest >= SIMULATE, results)
    validate_pass = count(r -> r.highest >= VALIDATE, results)
    has_ref = count(r -> !isempty(r.spec.referenceFile) || !isempty(r.spec.reference), results)
    pct(n, d) = d > 0 ? "$(round(100 * n / d, digits = 1))%" : "N/A"

    content = if format === :html
        _generate_html(results, filepath, ts, total, broken, tested,
                       frontend_pass, backend_pass, simulate_pass, validate_pass,
                       has_ref, pct, changelog, msl_version, total_time)
    else
        _generate_markdown(results, filepath, ts, total, broken, tested,
                           frontend_pass, backend_pass, simulate_pass, validate_pass,
                           has_ref, pct, changelog)
    end

    write(filepath, content)
    @info "Report saved to $filepath"
    return filepath
end

function _generate_html(results, filepath, ts, total, broken, tested,
                        frontend_pass, backend_pass, simulate_pass, validate_pass,
                        has_ref, pct, changelog, msl_version, total_time)
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    time_str = if total_time > 0
        mins = floor(Int, total_time / 60)
        secs = round(Int, total_time % 60)
        "$(mins) min $(secs) s"
    else
        ""
    end

    sorted_results = sort(results, by = x -> (x.spec.domain, x.spec.name))

    rows = IOBuffer()
    current_domain = ""
    for r in sorted_results
        if r.spec.domain != current_domain
            current_domain = r.spec.domain
            print(rows, """
            <tr class="domain-header">
              <td colspan="6"><strong>$(html_escape(current_domain))</strong></td>
            </tr>
            """)
        end
        row_class = r.spec.expected == BROKEN ? "broken-row" : ""
        name_short = replace(r.spec.name, "Modelica." => "")
        fe_cell = phase_cell(r.phases, FRONTEND)
        be_cell = phase_cell(r.phases, BACKEND)
        sim_cell = phase_cell(r.phases, SIMULATE)
        val_cell = phase_cell(r.phases, VALIDATE)
        total_model_time = sum(p.time_s for p in r.phases; init = 0.0)
        time_cell = isempty(r.phases) ? "&mdash;" : "$(round(total_model_time, digits=1))s"
        print(rows, """
        <tr class="$row_class">
          <td class="model-name">$name_short</td>
          $fe_cell
          $be_cell
          $sim_cell
          $val_cell
          <td class="time">$time_cell</td>
        </tr>
        """)
    end

    changelog_html = if !isempty(changelog)
        "<div class=\"changelog\"><strong>Changes:</strong> $(html_escape(changelog))</div>"
    else
        ""
    end

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>Modelica $msl_version - OM.jl Pipeline Test Results</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
             margin: 2em; background: #fff; color: #333; }
      h1 { margin-bottom: 0.2em; }
      .meta { color: #666; font-size: 0.9em; margin-bottom: 0.5em; }
      .meta code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
      .changelog { color: #555; font-size: 0.9em; margin-bottom: 1.5em; }
      .summary-table { border-collapse: collapse; margin-bottom: 2em; }
      .summary-table th, .summary-table td { border: 1px solid #ccc; padding: 6px 16px; text-align: right; }
      .summary-table th { background: #f5f5f5; text-align: left; }
      .summary-table td:last-child { font-weight: bold; }
      table.results { border-collapse: collapse; width: 100%; }
      table.results th { border: 1px solid #ccc; padding: 4px 10px; background: #f5f5f5;
                         text-align: left; font-size: 0.85em; text-transform: uppercase; }
      table.results td { border: 1px solid #ccc; padding: 4px 10px; font-size: 0.9em; }
      .model-name { font-family: monospace; font-size: 0.85em; }
      .ok { background: #d4edda; color: #155724; text-align: center; }
      .fail { background: #f8d7da; color: #721c24; text-align: center; cursor: help; }
      .na { color: #888; text-align: center; }
      .time { text-align: right; color: #666; font-family: monospace; }
      .broken-row { opacity: 0.5; }
      .broken-row td { font-style: italic; }
      .domain-header td { background: #e9ecef; font-size: 0.85em; padding: 6px 10px; }
    </style>
    </head>
    <body>
    <h1>Modelica $msl_version - OM.jl Pipeline Test Results</h1>
    <div class="meta">
      Generated: $timestamp$(isempty(time_str) ? "" : " | Total runtime: $time_str") | $total models ($broken known broken)
    </div>
    $changelog_html

    <table class="summary-table">
    <tr><th>Stage</th><th>Passed</th><th>Total</th><th>Rate</th></tr>
    <tr><td>Frontend</td><td>$frontend_pass</td><td>$tested</td><td>$(pct(frontend_pass, tested))</td></tr>
    <tr><td>Backend</td><td>$backend_pass</td><td>$tested</td><td>$(pct(backend_pass, tested))</td></tr>
    <tr><td>Simulate</td><td>$simulate_pass</td><td>$tested</td><td>$(pct(simulate_pass, tested))</td></tr>
    <tr><td>Validate</td><td>$validate_pass</td><td>$has_ref</td><td>$(pct(validate_pass, has_ref))</td></tr>
    </table>

    <table class="results">
    <thead>
    <tr>
      <th>Model</th>
      <th>Frontend</th>
      <th>Backend</th>
      <th>Simulate</th>
      <th>Validate</th>
      <th>Time</th>
    </tr>
    </thead>
    <tbody>
    $(String(take!(rows)))
    </tbody>
    </table>
    </body>
    </html>
    """
end

function _generate_markdown(results, filepath, ts, total, broken, tested,
                            frontend_pass, backend_pass, simulate_pass, validate_pass,
                            has_ref, pct, changelog)
    categories = categorize_results(results)
    sorted_cats = sort(collect(categories), by = x -> length(x[2]), rev = true)

    io = IOBuffer()
    println(io, "# MSL Coverage Report")
    println(io, "")
    println(io, "Date: $ts")
    println(io, "")
    if !isempty(changelog)
        println(io, "## Changes Since Last Report")
        println(io, "")
        println(io, changelog)
        println(io, "")
    end
    println(io, "## Summary")
    println(io, "")
    println(io, "| Stage | Passed | Total | Rate |")
    println(io, "|-------|--------|-------|------|")
    println(io, "| Frontend | $frontend_pass | $tested | $(pct(frontend_pass, tested)) |")
    println(io, "| Backend | $backend_pass | $tested | $(pct(backend_pass, tested)) |")
    println(io, "| Simulate | $simulate_pass | $tested | $(pct(simulate_pass, tested)) |")
    if has_ref > 0
        println(io, "| Validate | $validate_pass | $has_ref | $(pct(validate_pass, has_ref)) |")
    end
    println(io, "")
    println(io, "Known broken: $broken")
    println(io, "")
    println(io, "## Error Breakdown")
    println(io, "")
    println(io, "| Count | Category |")
    println(io, "|-------|----------|")
    for (cat, models) in sorted_cats
        println(io, "| $(length(models)) | $cat |")
    end
    println(io, "")
    println(io, "## Error Details")
    println(io, "")
    for (cat, models) in sorted_cats
        println(io, "### $cat ($(length(models)))")
        println(io, "")
        for m in sort(models)
            println(io, "- $m")
        end
        println(io, "")
    end
    println(io, "## Passing Models ($(frontend_pass))")
    println(io, "")
    passing = sort([r.spec.name for r in results if r.highest >= FRONTEND])
    for m in passing
        println(io, "- $m")
    end
    println(io, "")

    return String(take!(io))
end
