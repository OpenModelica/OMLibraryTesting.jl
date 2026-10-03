using Distributed, OMLibraryTesting

"""
    probe_validate(model_name, ref_file, stopTime, mgr_pid; signal_mapping)

Run simulate + validate against reference on a worker. Print per-signal errors.
Returns the vector of SignalComparison structs.
"""
function probe_validate(model_name::String, ref_file::String, stopTime::Float64, mgr_pid::Int;
                          signal_mapping::Dict{String,String}=Dict{String,String}(),
                          solver::String="", dtmax::Float64=0.0)
    ref_dir = abspath(joinpath(@__DIR__, "..", "reference"))
    sigmap_str = repr(signal_mapping)
    code = """
        begin
            using OM, OMLibraryTesting
            local kwargs = NamedTuple()
            if !isempty("$solver")
                kw = OMLibraryTesting._resolve_solver("$solver")
                kwargs = merge(kwargs, kw)
            end
            if $dtmax > 0.0
                kwargs = merge(kwargs, (; dtmax = $dtmax))
            end
            sol = OM.simulate("$model_name"; stopTime=$stopTime, kwargs...)
            spec = OMLibraryTesting.ModelSpec("$model_name", "", "", $stopTime, OMLibraryTesting.UNKNOWN,
                                              Dict{String,Float64}(), 1.0, 0.01, "$ref_file",
                                              $sigmap_str,
                                              "", Set{OMLibraryTesting.Phase}())
            (passed, comparisons) = OMLibraryTesting.validate_against_reference(sol, spec, "$ref_dir")
            for c in comparisons
                println("  ", c.name, "  max_abs=", c.max_abs_err,
                        "  max_rel=", c.max_rel_err,
                        "  worst_t=", c.worst_time,
                        "  actual=", c.worst_actual,
                        "  expected=", c.worst_expected)
            end
            comparisons
        end
    """
    Distributed.remotecall_eval(Main, [mgr_pid], Meta.parse(code))
end
