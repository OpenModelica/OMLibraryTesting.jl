#!/usr/bin/env bash
# Download Dymola-generated reference CSV files from MAP-LIB_ReferenceResults.
# These are the official Modelica Association reference results for MSL 3.2.3.
# Source: https://github.com/modelica/MAP-LIB_ReferenceResults (branch v3.2.3)
#
# Usage: cd OMLibraryTesting.jl/reference && bash download_refs.sh

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/modelica/MAP-LIB_ReferenceResults/v3.2.3"
CSV_DIR="csv"
SIGNALS_DIR="signals"

mkdir -p "$CSV_DIR" "$SIGNALS_DIR"

# Model paths relative to the repo root.
# Format: SHORT_NAME|REPO_PATH
MODELS=(
  "Pendulum|Modelica/Mechanics/MultiBody/Examples/Elementary/Pendulum/Pendulum"
  "DoublePendulum|Modelica/Mechanics/MultiBody/Examples/Elementary/DoublePendulum/DoublePendulum"
  "Engine1a|Modelica/Mechanics/MultiBody/Examples/Loops/Engine1a/Engine1a"
  "Rotational_First|Modelica/Mechanics/Rotational/Examples/First/First"
  "ChuaCircuit|Modelica/Electrical/Analog/Examples/ChuaCircuit/ChuaCircuit"
  "TwoMasses|Modelica/Thermal/HeatTransfer/Examples/TwoMasses/TwoMasses"
  "SignConvention|Modelica/Mechanics/Translational/Examples/SignConvention/SignConvention"
  "Oscillator|Modelica/Mechanics/Translational/Examples/Oscillator/Oscillator"
  "ShowVariableResistor|Modelica/Electrical/Analog/Examples/ShowVariableResistor/ShowVariableResistor"
  "ShowSaturatingInductor|Modelica/Electrical/Analog/Examples/ShowSaturatingInductor/ShowSaturatingInductor"
)

for entry in "${MODELS[@]}"; do
  IFS='|' read -r name path <<< "$entry"
  echo "Downloading $name..."

  # CSV reference file
  curl -fsSL "$BASE_URL/${path}.csv" -o "$CSV_DIR/${name}.csv"

  # Comparison signals list
  dir=$(dirname "$path")
  curl -fsSL "$BASE_URL/${dir}/comparisonSignals.txt" -o "$SIGNALS_DIR/${name}.txt"

  echo "  OK"
done

echo ""
echo "Downloaded $(ls "$CSV_DIR"/*.csv | wc -l) CSV files and $(ls "$SIGNALS_DIR"/*.txt | wc -l) signal lists."
