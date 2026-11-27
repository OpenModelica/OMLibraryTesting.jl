#=
Author: John Tinnerholm
Result files as reference data (ReferenceData): MAP-LIB's CSV files (load_reference_csv), MAT v4 result files
(OpenModelica's and Dymola's trajectory format, binTrans and binNormal: ScalableTestSuite, PowerSystems,
PowerGrids) and BuildingsPy reference files (Buildings' Resources/ReferenceResults/Dymola/*.txt).
=#

"""
    MatV4File

The matrices of a MAT v4 file by name: numeric ones as `Float64`, text ones as their characters' codes.
"""
struct MatV4File
    numeric::Dict{String, Matrix{Float64}}
    text::Dict{String, Matrix{UInt8}}
end

"""
    _read_mat_values(io, precision, n) -> Vector{Float64}

`n` values of a MAT v4 matrix of `precision` (the P digit of its type: 0 double, 1 single, 2 Int32, 3 Int16,
4 UInt16, 5 UInt8), little-endian.
"""
function _read_mat_values(io::IO, precision::Int, n::Int)::Vector{Float64}
    precision == 0 && return Float64.(ltoh.(read!(io, Vector{Float64}(undef, n))))
    precision == 1 && return Float64.(ltoh.(read!(io, Vector{Float32}(undef, n))))
    precision == 2 && return Float64.(ltoh.(read!(io, Vector{Int32}(undef, n))))
    precision == 3 && return Float64.(ltoh.(read!(io, Vector{Int16}(undef, n))))
    precision == 4 && return Float64.(ltoh.(read!(io, Vector{UInt16}(undef, n))))
    precision == 5 && return Float64.(read!(io, Vector{UInt8}(undef, n)))
    throw(ArgumentError("MAT v4 precision $precision"))
end

"""
    read_matv4(path) -> MatV4File

The matrices of a MAT v4 file (little-endian, real). A matrix's header is five Int32: its type
(1000 M + 100 O + 10 P + T: M byte order, P precision, T 1 for text), rows, columns, whether it is complex
and the length of its name; then its name, then its values by column.
"""
function read_matv4(path::String)::MatV4File
    local numeric = Dict{String, Matrix{Float64}}()
    local text = Dict{String, Matrix{UInt8}}()
    open(path) do io::IOStream
        while !eof(io)
            local header::Vector{Int32} = ltoh.(read!(io, Vector{Int32}(undef, 5)))
            local type::Int = Int(header[1])
            local rows::Int = Int(header[2])
            local cols::Int = Int(header[3])
            type ÷ 1000 == 0 || error("$path: a MAT v4 matrix that is not little-endian (type $type)")
            header[4] == 0 || error("$path: a complex MAT v4 matrix")
            local nameBytes::Vector{UInt8} = read(io, Int(header[5]))
            local name::String = String(nameBytes[1:something(findfirst(==(0x00), nameBytes), length(nameBytes) + 1) - 1])
            local values::Matrix{Float64} = reshape(_read_mat_values(io, (type ÷ 10) % 10, rows * cols), rows, cols)
            if type % 10 == 1
                text[name] = UInt8.(values)
            else
                numeric[name] = values
            end
        end
    end
    return MatV4File(numeric, text)
end

"""
    _mat_string(chars) -> String

A string of a MAT v4 text matrix, without the NULs and blanks that pad it.
"""
_mat_string(chars::AbstractVector{UInt8})::String = rstrip(String(filter(!=(0x00), Vector{UInt8}(chars))))

"""
    _openmodelica_style_name(name) -> String

A result variable's name as omc's readSimulationResultVars(openmodelicaStyle = true) gives it (OpenModelica's
library testing): `der(a.b)` for Dymola's `a.der(b)`, no blanks.
"""
function _openmodelica_style_name(name::String)::String
    local at = findfirst("der(", name)
    local n::String = (at !== nothing && first(at) > 1) ?
        "der(" * name[1:prevind(name, first(at))] * name[(first(at) + 4):end] : name
    return replace(n, " " => "")
end

"""
    load_reference_mat(path) -> ReferenceData

The trajectories of a MAT v4 result file (`Aclass` `Atrajectory`): the variables `dataInfo` puts in `data_2`,
by their names (`_openmodelica_style_name`), with a negative column index negated, except `time`. Parameters
(`data_1`) are left out: they do not change over time. `binTrans` files keep a variable per column of `name` and `dataInfo`
and a time point per column of `data_2`; `binNormal` files (Dymola) the transpose.
"""
function load_reference_mat(path::String)::ReferenceData
    local f::MatV4File = read_matv4(path)
    for m in ("Aclass", "name", "dataInfo", "data_2")
        (haskey(f.text, m) || haskey(f.numeric, m)) || error("$path: no $m matrix (not a trajectory result file)")
    end
    local aclass::Matrix{UInt8} = f.text["Aclass"]
    local transposed::Bool = size(aclass, 1) >= 4 && startswith(_mat_string(aclass[4, :]), "binTrans")
    local nameChars::Matrix{UInt8} = transposed ? f.text["name"] : permutedims(f.text["name"])
    local info::Matrix{Float64} = transposed ? f.numeric["dataInfo"] : permutedims(f.numeric["dataInfo"])
    local data::Matrix{Float64} = transposed ? f.numeric["data_2"] : permutedims(f.numeric["data_2"])
    local signals = Dict{String, Vector{Float64}}()
    for j in axes(nameChars, 2)
        Int(info[1, j]) == 2 || continue
        local name::String = _openmodelica_style_name(_mat_string(nameChars[:, j]))
        name == "time" && continue   # also a trajectory in some files (ScalableTestSuite's SteamPipe)
        local column::Int = Int(info[2, j])
        local values::Vector{Float64} = data[abs(column), :]
        signals[name] = column < 0 ? -values : values
    end
    return ReferenceData(data[1, :], signals)
end

"""
    load_reference_buildingspy(path) -> ReferenceData

A BuildingsPy reference file (`name=[v1, v2, ...]` lines; Buildings' Resources/ReferenceResults/Dymola): `time`
holds the start and the end, every other variable equidistant values over them, 101 or 2 for one that does not
change. All are given on the finest grid, linearly interpolated.
"""
function load_reference_buildingspy(path::String)::ReferenceData
    local raw = Dict{String, Vector{Float64}}()
    for m in eachmatch(r"^([^=\n]+)=\[([^\]]*)\]"m, read(path, String))
        raw[strip(m[1])] = [parse(Float64, strip(v)) for v in split(m[2], ',')]
    end
    haskey(raw, "time") || error("$path: no time")
    local t0::Float64 = first(raw["time"])
    local t1::Float64 = last(raw["time"])
    local n::Int = maximum(length(v) for (k, v) in raw if k != "time"; init = 2)
    local grid::Vector{Float64} = collect(range(t0, t1; length = n))
    local signals = Dict{String, Vector{Float64}}()
    for (name, values) in raw
        name == "time" && continue
        local own::Vector{Float64} = collect(range(t0, t1; length = length(values)))
        signals[name] = length(values) == n ? values : [interpolate_reference(own, values, t) for t in grid]
    end
    return ReferenceData(grid, signals)
end

"""
    load_reference(path) -> ReferenceData

A reference result file by its extension: `.csv` (MAP-LIB), `.mat` (MAT v4), `.txt` (BuildingsPy).
"""
function load_reference(path::String)::ReferenceData
    endswith(path, ".csv") && return load_reference_csv(path)
    endswith(path, ".mat") && return load_reference_mat(path)
    endswith(path, ".txt") && return load_reference_buildingspy(path)
    throw(ArgumentError("not a reference result file: $path"))
end

"""
    REFERENCE_FORMATS

Where a reference directory keeps its result files, by format: `<dir>/<folder>/<key><extension>`.
"""
const REFERENCE_FORMATS = (("csv", ".csv"), ("mat", ".mat"), ("txt", ".txt"))

"""
    reference_path(ref_dir, key) -> String

The reference result file of `key` (`_model_name_to_ref_key`) in `ref_dir`, in the first format of
`REFERENCE_FORMATS` it is there in; `""` when there is none.
"""
function reference_path(ref_dir::String, key::String)::String
    for (folder, extension) in REFERENCE_FORMATS
        local path::String = joinpath(ref_dir, folder, key * extension)
        isfile(path) && return path
    end
    return ""
end

"""
    reference_signal_names(path) -> Vector{String}

The names of the signals in a reference result file, without `time` (a CSV file's header only).
"""
function reference_signal_names(path::String)::Vector{String}
    if endswith(path, ".csv")
        local header::String = open(readline, path)
        return [String(n) for n in (strip(h, ['"', ' ', '\t', '\r', '\n']) for h in split_csv_header(header))
                if !isempty(n) && n != "time"]
    end
    return collect(keys(load_reference(path).signals))
end

"""
    DYMOLA_ONLY_VARIABLE

What Dymola writes to a result file besides the model (OpenModelica's library testing leaves them out): run
statistics, the dummy state of a model without states, package constants.
"""
const DYMOLA_ONLY_VARIABLE = r"^(?:CPUtime|EventCounter|Time|_derdummy|_dummy|(?:NonlinearSystems|_GlobalScope)\..*)$"

"""
    default_comparison_signals(ref) -> Vector{String}

The signals compared when a reference has no list of them (comparisonSignals.txt): all of its trajectories,
sorted, except Dymola's own (`DYMOLA_ONLY_VARIABLE`) and the derivatives `der(...)` (the states themselves are
compared).
"""
default_comparison_signals(ref::ReferenceData)::Vector{String} =
    sort!([n for n in keys(ref.signals) if !occursin(DYMOLA_ONLY_VARIABLE, n) && !startswith(n, "der(")])
