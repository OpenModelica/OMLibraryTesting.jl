# Fetch the upstream OpenModelica `testsuite/` regression suite and run it through
# OMLibraryTesting. Usage from a warm OM.jl REPL with OMLibraryTesting loaded:
#
#   include(".../scripts/run_testsuite.jl")
#
#   # OM.jl pipeline (default): frontend -> backend -> simulate on MSL targets
#   results = run_testsuite(; mode = :omjl, subdir = "simulation/modelica/equations",
#                             limit = 20)
#   print_summary(results)
#
#   # Upstream Perl rtest harness against the system omc (needs omc-diff; see
#   # scaffold_rtest_home! — install flex if omc-diff cannot be built):
#   rs = run_testsuite(; mode = :rtest, subdir = "flattening/modelica/scodeinst",
#                        status = "correct", limit = 20)
#   print_rtest_summary(rs)
#
# First call clones only the testsuite directory (sparse, partial) into
# `<pkg>/.testsuite_cache/OpenModelica/testsuite`. Subsequent calls reuse it; pass
# `fetch = false` to skip the network entirely, or `ref = "master"` to update.

using OMLibraryTesting

@info "run_testsuite is available. Example:" example =
    "run_testsuite(; mode=:omjl, subdir=\"simulation/modelica/equations\", limit=20)"
