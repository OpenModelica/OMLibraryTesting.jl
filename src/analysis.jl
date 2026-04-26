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

"""
    categorize_error(result::ModelResult) -> String

Classify the error of a failing model into a human-readable category string.
Returns "PASS" for models that did not fail, and "TIMEOUT/KNOWN_BROKEN" for
models that were skipped or had no phase output.
"""
function categorize_error(result::ModelResult)::String
    if result.highest != BROKEN
        return "PASS"
    end
    if isempty(result.phases)
        return "TIMEOUT/KNOWN_BROKEN"
    end
    err = result.phases[end].error
    if err === nothing
        return "NO_ERROR_MSG"
    end
    # Order matters: more specific patterns first
    if occursin("MetaModelicaGeneralException", err)
        return "MetaModelicaGeneralException"
    end
    if occursin("makeTypedCall", err)
        return "makeTypedCall_Cons"
    end
    if occursin("Cannot convert Nil", err) || occursin("Cannot `convert` an object of type Nil", err)
        return "Convert_Nil_to_Vector"
    end
    if occursin("Cannot `convert` an object of type Cons", err)
        return "Convert_Cons_to_Vector"
    end
    if occursin("Cannot `convert` an object of type Nothing", err)
        m = match(r"to an object of type (\w+)", err)
        target = m !== nothing ? m.captures[1] : "unknown"
        return "Convert_Nothing_to_$target"
    end
    if occursin("UNTYPED_COMPONENT", err) || occursin("TYPED_COMPONENT", err)
        return "COMPONENT_not_callable"
    end
    if occursin("UndefVarError", err)
        m = match(r"UndefVarError: `(\w+)`", err)
        varname = m !== nothing ? m.captures[1] : "unknown"
        return "UndefVar_$varname"
    end
    if occursin("MatchFailure", err)
        return "MatchFailure"
    end
    if occursin("MethodError", err)
        m = match(r"no method matching (\w+)", err)
        mname = m !== nothing ? m.captures[1] : "unknown"
        return "MethodError_$mname"
    end
    if occursin("BoundsError", err)
        return "BoundsError"
    end
    if occursin("StackOverflowError", err)
        return "StackOverflow"
    end
    if occursin("TypeError", err)
        return "TypeError"
    end
    if occursin("Timeout", err)
        return "TIMEOUT"
    end
    return "OTHER: " * first(err, 80)
end

"""
    categorize_results(results::Vector{ModelResult}) -> Dict{String, Vector{String}}

Group all failing models by error category. Returns a dictionary mapping
category name to a vector of model names.
"""
function categorize_results(results::Vector{ModelResult})::Dict{String, Vector{String}}
    categories = Dict{String, Vector{String}}()
    for r in results
        cat = categorize_error(r)
        if cat == "PASS"
            continue
        end
        if !haskey(categories, cat)
            categories[cat] = String[]
        end
        push!(categories[cat], r.spec.name)
    end
    return categories
end

"""
    print_error_analysis(results::Vector{ModelResult}; max_examples::Int = 5)

Print a formatted error category breakdown for all failing models in `results`.
Each category shows count and up to `max_examples` model names.
"""
function print_error_analysis(results::Vector{ModelResult}; max_examples::Int = 5)
    total = length(results)
    passed = count(r -> r.highest != BROKEN, results)
    failed_count = total - passed
    known_broken = count(r -> r.spec.expected == BROKEN, results)

    println()
    println("=" ^ 70)
    println("Error Analysis")
    println("=" ^ 70)
    println("Total: $total | Passed: $passed ($(round(100*passed/total, digits=1))%) | Failed: $failed_count | Known broken: $known_broken")
    println()

    categories = categorize_results(results)
    sorted = sort(collect(categories), by = x -> length(x[2]), rev = true)

    for (cat, models) in sorted
        println("$(lpad(length(models), 4))  $cat")
        n_show = min(length(models), max_examples)
        for m in models[1:n_show]
            println("        $m")
        end
        if length(models) > max_examples
            println("        ... and $(length(models) - max_examples) more")
        end
    end
    println()
end

"""
    models_with_error(results::Vector{ModelResult}, category::String) -> Vector{String}

Return the names of all models whose error matches `category` (exact match
on the categorize_error output).
"""
function models_with_error(results::Vector{ModelResult}, category::String)::Vector{String}
    categories = categorize_results(results)
    return get(categories, category, String[])
end

"""
    models_with_error(results::Vector{ModelResult}, pattern::Regex) -> Vector{String}

Return the names of all models whose error category matches `pattern`.
"""
function models_with_error(results::Vector{ModelResult}, pattern::Regex)::Vector{String}
    categories = categorize_results(results)
    matched = String[]
    for (cat, models) in categories
        if occursin(pattern, cat)
            append!(matched, models)
        end
    end
    return sort(matched)
end

"""
    error_for_model(results::Vector{ModelResult}, model_name::String) -> Union{Nothing, String}

Return the full error string for a specific model, or nothing if it passed
or was not found.
"""
function error_for_model(results::Vector{ModelResult}, model_name::String)::Union{Nothing, String}
    for r in results
        if r.spec.name == model_name
            if isempty(r.phases)
                return nothing
            end
            return r.phases[end].error
        end
    end
    return nothing
end

"""
    run_frontend_coverage(; timeout::Float64 = 60.0, kwargs...) -> Vector{ModelResult}

Convenience wrapper that runs coverage for frontend phase only with a short
timeout. Equivalent to `run_coverage(phases=[FRONTEND], timeout=timeout; kwargs...)`.
"""
function run_frontend_coverage(; timeout::Float64 = 60.0, kwargs...)
    return run_coverage(; phases = [FRONTEND], timeout = timeout, kwargs...)
end

"""
    subcategorize_meta_errors(results::Vector{ModelResult}; max_examples::Int = 5)

Subcategorize the MetaModelicaGeneralException failures by extracting the actual
Modelica-level error messages from the error strings. Prints a breakdown showing
the distinct error patterns within this catch-all category.
"""
function subcategorize_meta_errors(results::Vector{ModelResult}; max_examples::Int = 5)
    subcats = Dict{String, Vector{String}}()
    for r in results
        categorize_error(r) == "MetaModelicaGeneralException" || continue
        err = r.phases[end].error
        err === nothing && continue
        subcat = _extract_meta_subcat(err)
        if !haskey(subcats, subcat)
            subcats[subcat] = String[]
        end
        push!(subcats[subcat], r.spec.name)
    end
    sorted = sort(collect(subcats), by = x -> length(x[2]), rev = true)
    println()
    println("=" ^ 70)
    println("MetaModelicaGeneralException Subcategories")
    println("=" ^ 70)
    total = sum(length(v) for (_, v) in sorted)
    println("Total MetaModelicaGeneralException: $total")
    println()
    for (subcat, models) in sorted
        println("$(lpad(length(models), 4))  $subcat")
        n_show = min(length(models), max_examples)
        for m in models[1:n_show]
            println("        $m")
        end
        if length(models) > max_examples
            println("        ... and $(length(models) - max_examples) more")
        end
    end
    println()
    return subcats
end

function _extract_meta_subcat(err::String)::String
    # Extract Message: lines from the error string
    messages = String[]
    for m in eachmatch(r"Message:(.+?)(?:\n|$)", err)
        msg = strip(m.captures[1])
        isempty(msg) && continue
        push!(messages, msg)
    end
    if isempty(messages)
        # Try to extract from the stacktrace or error text directly
        if occursin("not callable", err)
            return "COMPONENT_not_callable"
        end
        # Return first 80 chars as fallback
        return "UNKNOWN: " * first(err, 80)
    end
    # Use the LAST Message: line as the primary error (most specific)
    msg = messages[end]
    # Classify by pattern
    if occursin("Function parameter", msg) && occursin("not given by the function call", msg)
        m = match(r"Function parameter (\w+) was not given", msg)
        param = m !== nothing ? m.captures[1] : "?"
        return "UNFILLED_SLOT($param)"
    end
    if occursin("Invalid type", msg) && occursin("for function component", msg)
        m = match(r"Invalid type ([^\s]+)", msg)
        ty = m !== nothing ? m.captures[1] : "?"
        return "INVALID_FUNC_TYPE($ty)"
    end
    if occursin("__NOT_IMPLEMENTED__", msg)
        return "NOT_IMPLEMENTED"
    end
    if occursin("No matching function found", msg) || occursin("NO_MATCHING_FUNCTION", msg)
        return "NO_MATCHING_FUNCTION"
    end
    if occursin("Ambiguous matching functions", msg)
        return "AMBIGUOUS_MATCH"
    end
    if occursin("Unresolvable type", msg)
        return "UNRESOLVABLE_TYPE"
    end
    if occursin("Internal error", msg)
        return "INTERNAL_ERROR: " * first(msg, 60)
    end
    if occursin("isn't a record", msg) || occursin("not a record", msg)
        return "NOT_A_RECORD"
    end
    if occursin("not a function", msg)
        return "NOT_A_FUNCTION"
    end
    # Fallback: truncate the message
    return first(msg, 60)
end

# ── HTML Report Parsing ───────────────────────────────────────────────

"""
    ParsedModel

Lightweight struct holding per-model data extracted from an HTML coverage report.
"""
struct ParsedModel
    name::String
    domain::String
    is_broken::Bool
    phases::Dict{Phase, Symbol}      # Phase => :pass / :fail / :na
    errors::Dict{Phase, String}      # Phase => tooltip error text (fail only)
    times::Dict{Phase, Float64}      # Phase => seconds (pass/fail only)
end

"""
    parse_report(path::String) -> Vector{ParsedModel}
    parse_report()              -> Vector{ParsedModel}

Parse an HTML coverage report produced by `generate_report` and return a vector
of `ParsedModel` structs.  With no arguments, finds the most recent `.html`
file in the default reports directory.

The HTML we generate has a rigid structure per model row:

    <td class="model-name">NAME</td>
    <td class="ok">✓ 1.2s</td>          # pass
    <td class="fail" title="ERR">✗ 0.3s</td>  # fail
    <td class="na">&mdash;</td>                # not attempted

This function extracts model name, phase status, error tooltips, and timings.
"""
function parse_report(path::String)::Vector{ParsedModel}
    html = read(path, String)
    _parse_report_html(html)
end

function parse_report()::Vector{ParsedModel}
    dir = DEFAULT_REPORTS_DIR
    if !isdir(dir)
        error("Reports directory does not exist: $dir")
    end
    files = filter(f -> endswith(f, ".html"), readdir(dir; join = true))
    if isempty(files)
        error("No HTML reports found in $dir")
    end
    latest = sort(files, by = mtime, rev = true)[1]
    @info "Parsing latest report: $latest"
    parse_report(latest)
end

const _PHASE_ORDER_PARSE = [FRONTEND, BACKEND, SIMULATE, VALIDATE]

function _parse_report_html(html::String)::Vector{ParsedModel}
    results = ParsedModel[]
    current_domain = ""

    # Walk all <tr> rows linearly; track the current domain from domain headers
    row_re = r"<tr[^>]*>(.*?)</tr>"s
    domain_re = r"class=\"domain-header\".*?<strong>(.*?)</strong>"s
    model_re = r"<td class=\"model-name\">(.*?)</td>(.*)"s
    # The title attribute may contain newlines, so use [\s\S]*? to match any char
    cell_re = r"<td class=\"(ok|fail|na)\"([\s\S]*?)>([\s\S]*?)</td>"

    for tr in eachmatch(row_re, html)
        row_html = tr.captures[1]

        # Check if this is a domain header
        dm = match(domain_re, row_html)
        if dm !== nothing
            current_domain = _html_unescape(dm.captures[1])
            continue
        end

        # Check if this is a model row
        mm = match(model_re, row_html)
        mm === nothing && continue

        is_broken = occursin("broken-row", tr.match)
        name = "Modelica." * strip(mm.captures[1])
        cells_html = mm.captures[2]

        phases = Dict{Phase, Symbol}()
        errors = Dict{Phase, String}()
        times = Dict{Phase, Float64}()

        cell_matches = collect(eachmatch(cell_re, cells_html))

        for (i, cm) in enumerate(cell_matches)
            i > length(_PHASE_ORDER_PARSE) && break
            phase = _PHASE_ORDER_PARSE[i]
            cls = cm.captures[1]

            if cls == "ok"
                phases[phase] = :pass
                t = _extract_time(cm.captures[3])
                t !== nothing && (times[phase] = t)
            elseif cls == "fail"
                phases[phase] = :fail
                t = _extract_time(cm.captures[3])
                t !== nothing && (times[phase] = t)
                tooltip = match(r"title=\"([\s\S]*?)\"", cm.captures[2])
                if tooltip !== nothing
                    errors[phase] = _html_unescape(tooltip.captures[1])
                end
            else
                phases[phase] = :na
            end
        end

        push!(results, ParsedModel(name, current_domain, is_broken, phases, errors, times))
    end
    return results
end

function _extract_time(cell_content::AbstractString)::Union{Nothing, Float64}
    m = match(r"([\d.]+)s", cell_content)
    m === nothing && return nothing
    tryparse(Float64, m.captures[1])
end

function _html_unescape(s::AbstractString)::String
    s = replace(s, "&amp;" => "&")
    s = replace(s, "&lt;" => "<")
    s = replace(s, "&gt;" => ">")
    s = replace(s, "&quot;" => "\"")
    s = replace(s, "&#10003;" => "")
    s = replace(s, "&#10007;" => "")
    s = replace(s, "&mdash;" => "")
    strip(s)
end

# ── Query helpers on parsed reports ────────────────────────────────────

"""
    failing_models(parsed; phase=nothing) -> Vector{@NamedTuple{name::String, phase::Phase, error::String}}

Return all models that failed at any phase (or a specific `phase`), with
the phase and error message.
"""
function failing_models(parsed::Vector{ParsedModel}; phase::Union{Nothing, Phase} = nothing)
    result = @NamedTuple{name::String, phase::Phase, error::String}[]
    for pm in parsed
        pm.is_broken && continue
        for (ph, status) in pm.phases
            status == :fail || continue
            phase !== nothing && ph != phase && continue
            err = get(pm.errors, ph, "")
            push!(result, (name = pm.name, phase = ph, error = err))
        end
    end
    sort!(result, by = x -> (Int(x.phase), x.name))
    return result
end

"""
    passing_models(parsed; up_to::Phase = VALIDATE) -> Vector{String}

Return names of all non-broken models that passed at least up to `up_to` phase.
"""
function passing_models(parsed::Vector{ParsedModel}; up_to::Phase = SIMULATE)::Vector{String}
    result = String[]
    for pm in parsed
        pm.is_broken && continue
        passed = true
        for ph in _PHASE_ORDER_PARSE
            Int(ph) > Int(up_to) && break
            if get(pm.phases, ph, :na) != :pass
                passed = false
                break
            end
        end
        passed && push!(result, pm.name)
    end
    sort!(result)
end

"""
    failing_by_error(parsed; phase=nothing) -> Dict{String, Vector{String}}

Group failing models by error substring pattern (similar to `categorize_results`
but working from parsed HTML). Returns dict mapping error category to model names.
"""
function failing_by_error(parsed::Vector{ParsedModel}; phase::Union{Nothing, Phase} = nothing)
    categories = Dict{String, Vector{String}}()
    for pm in parsed
        pm.is_broken && continue
        for (ph, status) in pm.phases
            status == :fail || continue
            phase !== nothing && ph != phase && continue
            err = get(pm.errors, ph, "")
            cat = _categorize_error_string(err)
            if !haskey(categories, cat)
                categories[cat] = String[]
            end
            push!(categories[cat], pm.name)
        end
    end
    return categories
end

function _categorize_error_string(err::String)::String
    isempty(err) && return "UNKNOWN"
    occursin("STMT_NORETCALL", err) && return "STMT_NORETCALL"
    occursin("variabilityToDAEConst", err) && return "variabilityToDAEConst"
    occursin("FLAT_TREE", err) && return "FLAT_TREE"
    occursin("Values.", err) && return "Values_module"
    occursin("ExtraEquationsSystemException", err) && return "ExtraEquations"
    occursin("MetaModelicaGeneralException", err) && return "MetaModelicaException"
    occursin("MatchFailure", err) && return "MatchFailure"
    occursin("UndefVarError", err) && begin
        m = match(r"UndefVarError: `(\w+)`", err)
        varname = m !== nothing ? m.captures[1] : "unknown"
        return "UndefVar_$varname"
    end
    occursin("FieldError", err) && return "FieldError"
    occursin("MethodError", err) && return "MethodError"
    occursin("BoundsError", err) && return "BoundsError"
    occursin("StackOverflow", err) && return "StackOverflow"
    occursin("Timeout", err) && return "Timeout"
    occursin("retcode", err) && return "SimulationFailed"
    occursin("Validation failed", err) && return "ValidationFailed"
    return "OTHER: " * first(err, 60)
end

"""
    print_report_summary(parsed::Vector{ParsedModel})

Print a summary table from parsed HTML report data.
"""
function print_report_summary(parsed::Vector{ParsedModel})
    active = filter(pm -> !pm.is_broken, parsed)
    broken = length(parsed) - length(active)
    n = length(active)

    fe = count(pm -> get(pm.phases, FRONTEND, :na) == :pass, active)
    be = count(pm -> get(pm.phases, BACKEND, :na) == :pass, active)
    sim = count(pm -> get(pm.phases, SIMULATE, :na) == :pass, active)
    val = count(pm -> get(pm.phases, VALIDATE, :na) == :pass, active)

    pct(x) = n > 0 ? "$(round(100 * x / n, digits = 1))%" : "N/A"

    println()
    println("=" ^ 60)
    println("Parsed Report Summary ($n active, $broken known broken)")
    println("=" ^ 60)
    println("  Frontend:  $fe / $n  ($(pct(fe)))")
    println("  Backend:   $be / $n  ($(pct(be)))")
    println("  Simulate:  $sim / $n  ($(pct(sim)))")
    println("  Validate:  $val / $n  ($(pct(val)))")
    println("=" ^ 60)

    cats = failing_by_error(parsed)
    if !isempty(cats)
        println()
        println("Error categories:")
        for (cat, models) in sort(collect(cats), by = x -> length(x[2]), rev = true)
            println("  $(lpad(length(models), 4))  $cat")
        end
    end
    println()
end

