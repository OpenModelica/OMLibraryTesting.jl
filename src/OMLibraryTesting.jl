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

module OMLibraryTesting

using TOML
using Dates
using Distributed
import OM
import OMBackend
import OMFrontend

include("types.jl")
include("registry.jl")
include("comparison.jl")
include("discovery.jl")
include("runner.jl")
include("analysis.jl")
include("report.jl")

export Phase, BROKEN, FRONTEND, BACKEND, SIMULATE, VALIDATE, UNKNOWN
export PhaseResult, ModelSpec, ModelResult
export ReferenceData, SignalComparison
export load_models, load_models_by_domain, list_domains, load_registry_meta
export load_reference_csv, load_comparison_signals, validate_against_reference
export discover_experiments, merge_overrides!
export run_coverage, run_model, WorkerManager
export generate_report, print_summary
export categorize_error, categorize_results, print_error_analysis
export models_with_error, error_for_model, run_frontend_coverage
export subcategorize_meta_errors

end
