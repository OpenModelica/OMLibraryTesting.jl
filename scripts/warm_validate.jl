#= Warm-session single-model validation.

   Include this file in an ALREADY WARM Julia REPL that has `using OM`
   (and therefore OMBackend) loaded, typically the OMJL tmux session with
   the OM.jl project active. It simulates one model in the current process,
   so Revise-applied backend edits take effect without any worker spawn or
   precompilation, and compares the solution against the Dymola reference
   CSV with the same combined tolerance the coverage harness uses.

   Usage:
     include("/home/johti17/Projects/Julia/OM.jl/OMLibraryTesting.jl/scripts/warm_validate.jl")
     r = warm_validate("Modelica.Mechanics.MultiBody.Examples.Systems.RobotR3.fullRobot";
                       stopTime = 1.85, atol = 0.5, reltol = 0.30)
     r.sol            # the solution object, for further probing
     r.results        # per-signal NamedTuples (signal, pass, maxerr, tmax, ours, ref, tol)

   `rebuild = true` (default) deletes the model's OMBackend.IMTKGen.BUILT
   cache entry first, forcing a full rebuild so backend source edits tracked
   by Revise are picked up. Set `rebuild = false` to re-validate the cached
   build (fast, sampling and tolerance changes only).

   This is the fast inner loop. The cold `run_coverage(model = ...)` from the
   OMLibraryTesting project stays the final authoritative gate. =#

using DelimitedFiles

const WARM_REF_DIR = joinpath(@__DIR__, "..", "reference", "csv")

function warm_reference_path(modelName::String)::String
  local mangled = replace(modelName, "." => "_")
  local base = startswith(mangled, "Modelica_") ? mangled[(length("Modelica_") + 1):end] : mangled
  return abspath(joinpath(WARM_REF_DIR, base * ".csv"))
end

function warm_validate(modelName::String;
                       stopTime::Float64,
                       atol::Float64 = 0.5,
                       reltol::Float64 = 0.30,
                       npoints::Int = 21,
                       rebuild::Bool = true,
                       referenceFile::Union{String, Nothing} = nothing,
                       msl_version::String = "MSL:3.2.3",
                       quiet::Bool = false,
                       solverKwargs::NamedTuple = (; dense = false))
  @isdefined(OM) || error("warm_validate needs `using OM` in this session")
  @isdefined(OMBackend) || error("warm_validate needs OMBackend (loaded by `using OM`)")
  local refPath = if referenceFile === nothing
    warm_reference_path(modelName)
  elseif isfile(referenceFile)
    referenceFile
  else
    abspath(joinpath(WARM_REF_DIR, referenceFile * ".csv"))
  end
  isfile(refPath) || error("Reference CSV not found: $(refPath)")
  if rebuild
    local cname = OMBackend.canonicalName(modelName)
    haskey(OMBackend.IMTKGen.BUILT, cname) && delete!(OMBackend.IMTKGen.BUILT, cname)
    #= Deleting BUILT only rebuilds the MTK problem from the CACHED generated
       module; codegen-layer edits need a real re-translate, which also
       refreshes the module and re-caches the build. =#
    haskey(OMBackend.COMPILED_MODELS_MTK, cname) && delete!(OMBackend.COMPILED_MODELS_MTK, cname)
    OM.translate(modelName; MSL_Version = msl_version)
  end
  local sol = OM.simulate(modelName; MSL_Version = msl_version, stopTime = stopTime,
                          solverKwargs...)
  quiet || println("retcode = ", sol.retcode)
  local raw, hdr
  (raw, hdr) = readdlm(refPath, ',', header = true)
  local sigNames = [strip(String(h), '"') for h in vec(hdr)]
  local tref = Float64.(raw[:, 1])
  local grid = range(0.0, stopTime; length = npoints)
  local refAt = function (col::Int, t::Float64)
    local i = clamp(searchsortedlast(tref, t), 1, length(tref) - 1)
    #= Dymola writes duplicate timestamps at event instants (and at the
       terminal time); a zero-width bracket would divide to NaN. Take the
       value at that instant rather than interpolate across it. =#
    local dt = tref[i + 1] - tref[i]
    dt == 0 && return raw[i, col]
    local w = (t - tref[i]) / dt
    return raw[i, col] * (1 - w) + raw[i + 1, col] * w
  end
  local results = NamedTuple[]
  quiet || println(rpad("signal", 40), rpad("verdict", 9), rpad("maxerr", 12), rpad("t@max", 8),
                   rpad("ours", 12), rpad("ref", 12), "tol@max")
  for col in 2:length(sigNames)
    local nm = sigNames[col]
    local flat = replace(nm, "." => "_")
    local ok = true
    local maxerr = 0.0
    local tmax = 0.0
    local ourmax = 0.0
    local refmax = 0.0
    local tolmax = 0.0
    for t in grid
      local rv = refAt(col, Float64(t))
      local ov = try
        sol(t, idxs = Symbol(flat))
      catch
        NaN
      end
      local err = abs(ov - rv)
      local tol = atol + reltol * abs(rv)
      if err > maxerr || isnan(err)
        maxerr = err
        tmax = t
        ourmax = ov
        refmax = rv
        tolmax = tol
      end
      (isfinite(err) && err <= tol) || (ok = false)
    end
    push!(results, (; signal = nm, pass = ok, maxerr, tmax, ours = ourmax, ref = refmax, tol = tolmax))
    quiet || println(rpad(nm, 40), rpad(ok ? "PASS" : "FAIL", 9),
                     rpad(string(round(maxerr, sigdigits = 4)), 12),
                     rpad(string(round(tmax, digits = 3)), 8),
                     rpad(string(round(ourmax, sigdigits = 4)), 12),
                     rpad(string(round(refmax, sigdigits = 4)), 12),
                     string(round(tolmax, sigdigits = 4)))
  end
  local npass = count(r -> r.pass, results)
  local nfail = length(results) - npass
  quiet || println("validated ", npass, "/", length(results), " signals (", nfail, " failing)")
  return (; sol, results, npass, nfail)
end

println("warm_validate loaded: warm_validate(\"<Modelica model name>\"; stopTime = ...)")
