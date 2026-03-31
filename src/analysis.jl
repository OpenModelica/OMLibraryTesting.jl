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

