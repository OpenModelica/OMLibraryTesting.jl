#=
run_on_worker must time a model out while its worker runs code that never yields.
Polling isready on the worker's Future used to block until that code finished, which
also kept the timeout timers from interrupting it: a pegged solve hung the whole run.
Here the worker's _run_model_phases is replaced by a 120 s busy loop; the result must
come back as a timeout within seconds, once through the interrupt and once through the
kill (the loop ignores the interrupt).
=#

using Distributed
import OMLibraryTesting
const OLT = OMLibraryTesting

#= The worker's typed _run_model_phases methods are more specific than `args...`, so they
   are deleted first; the worker is a throwaway one, killed at the end. =#
function _busy_worker!(pid::Int; ignore_interrupt::Bool)
    loop = :(let t = time(), s = 0.0
                 while time() - t < 120.0
                     s += sin(s) + 1.0e-9
                 end
                 (Tuple{Int, Bool, Float64, Union{Nothing, String}}[], 0)
             end)
    body = ignore_interrupt ? :(disable_sigint(() -> $loop)) : loop
    Distributed.remotecall_eval(OLT, pid, quote
        foreach(Base.delete_method, collect(methods(_run_model_phases)))
        _run_model_phases(args...) = $body
    end)
end

@testset "run_on_worker times out a worker that never yields" begin
    spec = OLT.ModelSpec("Busy.Model", "Busy_Model", "Busy", 1.0, OLT.SIMULATE,
                         Dict{String, Float64}(), 0.0, 0.0, "", Dict{String, String}(), "",
                         Set{OLT.Phase}())
    mgr = OLT.WorkerManager()
    try
        _busy_worker!(OLT.ensure_worker!(mgr); ignore_interrupt = false)
        elapsed = @elapsed r = OLT.run_on_worker(mgr, spec, [OLT.SIMULATE]; timeout = 3.0, grace_period = 5.0)
        @test r.highest == OLT.BROKEN
        @test startswith(something(r.phases[1].error, ""), "Timeout")
        @test !endswith(r.phases[1].error, "[worker killed]")
        @test elapsed < 8.0
        @test mgr.pid !== nothing   # the interrupt was enough; the worker lives on

        _busy_worker!(OLT.ensure_worker!(mgr); ignore_interrupt = true)
        elapsed = @elapsed r = OLT.run_on_worker(mgr, spec, [OLT.SIMULATE]; timeout = 3.0, grace_period = 5.0)
        @test r.highest == OLT.BROKEN
        @test endswith(something(r.phases[1].error, ""), "[worker killed]")
        @test elapsed < 30.0
        @test mgr.pid === nothing
    finally
        OLT.cleanup!(mgr)
    end
end
