using Distributed, OMLibraryTesting

"""
    probe_one(name, ref_file, stopTime, mgr_pid; solver="", dtmax=0.0, initAlg="", atol=0.5, reltol=0.01)

Probe a model. Print the simulate retcode and either validation max errors or the simulate error.
Returns (sim_ok::Bool, comparisons::Union{Nothing, Vector{SignalComparison}}, sim_err::String)
"""
function probe_one(name::String, ref_file::String, stopTime::Float64, mgr_pid::Int;
                    solver::String="", dtmax::Float64=0.0, initAlg::String="",
                    atol::Float64=0.5, reltol::Float64=0.01)
    ref_dir = abspath(joinpath(@__DIR__, "..", "reference"))
    code = """
        begin
            using OM, OMLibraryTesting
            local sim_ok = false
            local sim_err = ""
            local kwargs = NamedTuple()
            if !isempty("$solver")
                kw = OMLibraryTesting._resolve_solver("$solver"); kwargs = merge(kwargs, kw)
            end
            if !isempty("$initAlg")
                kw = OMLibraryTesting._resolve_init_alg("$initAlg"); kwargs = merge(kwargs, kw)
            end
            if $dtmax > 0.0
                kwargs = merge(kwargs, (; dtmax = $dtmax))
            end
            local sol = nothing
            try
                sol = OM.simulate("$name"; stopTime=$stopTime, kwargs...)
                if sol.retcode == ReturnCode.Success
                    sim_ok = true
                else
                    sim_err = string(sol.retcode)
                end
            catch e
                sim_err = sprint(showerror, e; context = :compact => true)
                sim_err = first(sim_err, 200)
            end
            if sim_ok
                spec = OMLibraryTesting.ModelSpec("$name", "", "", $stopTime, OMLibraryTesting.UNKNOWN,
                                                  Dict{String,Float64}(), $atol, $reltol, "$ref_file",
                                                  Dict{String,String}(), "", Set{OMLibraryTesting.Phase}())
                local passed, comparisons
                try
                    (passed, comparisons) = OMLibraryTesting.validate_against_reference(sol, spec, "$ref_dir")
                    println("  [$("$name")] SIM-OK, validate passed=", passed)
                    for c in comparisons
                        if !isnan(c.max_abs_err)
                            println("    ", c.name, "  max_abs=", round(c.max_abs_err, sigdigits=3),
                                    "  rel=", round(c.max_rel_err, sigdigits=3),
                                    "  passed=", c.passed)
                        end
                    end
                catch e
                    println("  [$("$name")] SIM-OK, validate ERROR: ", first(sprint(showerror, e), 200))
                end
            else
                println("  [$("$name")] SIM-FAIL solver=$solver initAlg=$initAlg: ", sim_err)
            end
        end
    """
    Distributed.remotecall_eval(Main, [mgr_pid], Meta.parse(code))
end
