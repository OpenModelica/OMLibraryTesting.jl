#=
Tests for the reference results (src/references.jl, src/resultFiles.jl): the sources and their paths, the
MAT v4 (binTrans, binNormal) and BuildingsPy readers on files written here, and small real files fetched:
MAP-LIB's ModelicaTest.Math.TestNonlinear (11 bytes), PowerGrids' TestDeadBand (.mat, 3.7 kB) and PowerSystems'
DCmotor_ser (.mat.xz, 2.5 kB).
=#

"""
A MAT v4 matrix: its header, name and values (`T` 1 for text, as UInt8; else Float64, or Int32 for dataInfo).
"""
function writeMatrix(io::IO, name::String, values::AbstractMatrix; text::Bool = false, int::Bool = false)
    local precision::Int = text ? 5 : (int ? 2 : 0)
    write(io, Int32[10 * precision + (text ? 1 : 0), size(values, 1), size(values, 2), 0, length(name) + 1])
    write(io, Vector{UInt8}(name), 0x00)
    write(io, text ? UInt8.(vec(values)) : (int ? Int32.(vec(values)) : Float64.(vec(values))))
end

"""
Strings as the rows of a text matrix, padded with blanks.
"""
textRows(strings::Vector{String}) =
    permutedims(hcat([UInt8.(collect(rpad(s, maximum(length, strings)))) for s in strings]...))

"""
A trajectory file of time, a parameter p = 2, x = 1 + t and y = -x (column -2), at t = 0, 1, 2.
"""
function writeTrajectory(path::String; transposed::Bool)
    local names = textRows(["time", "p", "x", "y"])
    local info = [0 1 0 -1; 1 2 0 0; 2 2 0 0; 2 -2 0 0]   # a row per variable
    local data2 = [0.0 1.0; 1.0 2.0; 2.0 3.0]              # a row per time point: time, x
    open(path, "w") do io
        writeMatrix(io, "Aclass", textRows(["Atrajectory", "1.1", "", transposed ? "binTrans" : "binNormal"]); text = true)
        writeMatrix(io, "name", transposed ? permutedims(names) : names; text = true)
        writeMatrix(io, "description", textRows(["", "", "", ""]); text = true)
        writeMatrix(io, "dataInfo", transposed ? permutedims(info) : info; int = true)
        writeMatrix(io, "data_1", transposed ? [0.0 2.0; 2.0 2.0] : [0.0 2.0; 2.0 2.0])
        writeMatrix(io, "data_2", transposed ? permutedims(data2) : data2)
    end
end

@testset "Reference results" begin
    @testset "sources and paths" begin
        @test OLT.maplib_branch("4.1.0+maint.om") == "v4.1.0"
        @test OLT.maplib_reference_path("ModelicaTest.Blocks.Limiters") == "ModelicaTest/Blocks/Limiters/Limiters"
        @test OLT.reference_source("ModelicaTest", "4.1.0+maint.om") ==
              OLT.ReferenceSource("$(OLT.MAPLIB_URL)/v4.1.0", OLT.MAPLIB_LAYOUT, "")
        @test OLT.reference_source("PowerSystems", "2.0.0").suffix == ".mat.xz"
        @test OLT._reference_folder(".mat.xz") == ("mat", ".mat")
        @test OLT._reference_folder("_res.mat") == ("mat", ".mat")
        @test OLT._reference_folder(".txt") == ("txt", ".txt")
        @test_throws ArgumentError OLT.reference_source("PNlib", "3.0.0")
        @test_throws ArgumentError OLT.download_references(OLT.coverage_target(; library = "PNlib@3.0.0"))
        @test OLT._openmodelica_style_name("a.b.der(c)") == "der(a.b.c)"
        @test OLT._openmodelica_style_name("der(x)") == "der(x)"
    end

    @testset "MAT v4 and BuildingsPy readers" begin
        mktempdir() do dir
            for transposed in (true, false)
                local path = joinpath(dir, "t$(transposed).mat")
                writeTrajectory(path; transposed)
                local ref = OLT.load_reference(path)
                @test ref.time == [0.0, 1.0, 2.0]
                @test sort(collect(keys(ref.signals))) == ["x", "y"]   # no parameter p, no time
                @test ref.signals["x"] == [1.0, 2.0, 3.0]
                @test ref.signals["y"] == [-1.0, -2.0, -3.0]
            end
            local bpy = joinpath(dir, "Buildings_A_B.txt")
            write(bpy, "last-generated=2024-04-01\nstatistics-simulation=\n{\n  \"linear\": \" \"\n}\n" *
                       "time=[0e+00, 2e+00]\na.y=[0e+00, 1e+00, 4e+00]\nb.k=[5e+00, 5e+00]\nCPUtime=[0e+00, 1e+00, 2e+00]\n")
            local ref = OLT.load_reference(bpy)
            @test ref.time == [0.0, 1.0, 2.0]
            @test ref.signals["a.y"] == [0.0, 1.0, 4.0]
            @test ref.signals["b.k"] == [5.0, 5.0, 5.0]
            @test OLT.default_comparison_signals(ref) == ["a.y", "b.k"]   # not Dymola's CPUtime
            #= Found by key in txt/, after csv/ and mat/. =#
            mkpath(joinpath(dir, "txt")); cp(bpy, joinpath(dir, "txt", "Buildings_A_B.txt"))
            @test OLT.reference_path(dir, "Buildings_A_B") == joinpath(dir, "txt", "Buildings_A_B.txt")
            @test OLT.reference_path(dir, "Buildings_A_C") == ""
            @test sort(OLT.reference_signal_names(OLT.reference_path(dir, "Buildings_A_B"))) == ["CPUtime", "a.y", "b.k"]
        end
    end

    @testset "fetched" begin
        mktempdir() do dir
            local maplib = OLT.reference_source("ModelicaTest", "4.1.0+maint.om")
            @test OLT.download_references(["ModelicaTest.Math.TestNonlinear", "ModelicaTest.NoSuchModel"], dir, maplib) == 1
            @test isfile(joinpath(dir, "signals", "ModelicaTest_Math_TestNonlinear.txt"))
            @test !isfile(joinpath(dir, "csv", "ModelicaTest_NoSuchModel.csv"))
            @test OLT.download_reference("PowerGrids.Controls.Test.TestDeadBand", dir, OLT.reference_source("PowerGrids", "1.0.3"))
            local pg = OLT.load_reference(OLT.reference_path(dir, "PowerGrids_Controls_Test_TestDeadBand"))
            @test haskey(pg.signals, "deadBand.y") && length(pg.time) == length(pg.signals["deadBand.y"]) > 2
            local ps = "PowerSystems.Examples.AC1ph_DC.Drives.DCmotor_ser"
            @test OLT.download_reference(ps, dir, OLT.reference_source("PowerSystems", "2.0.0"))
            local psRef = OLT.load_reference(OLT.reference_path(dir, "PowerSystems_Examples_AC1ph_DC_Drives_DCmotor_ser"))
            @test !isempty(psRef.signals) && issorted(psRef.time)
            @test isempty(filter(f -> occursin(".part", f), readdir(joinpath(dir, "mat"))))
            #= The fetched files are what auto_detect_references! finds. =#
            local spec(name) = OLT.ModelSpec(name, name, "", 1.0, OLT.VALIDATE, Dict{String, Float64}(), 0.0, 0.0,
                                             "", Dict{String, String}(), "", Set{OLT.Phase}())
            @test [s.referenceFile for s in OLT.auto_detect_references!([spec(ps), spec("ModelicaTest.Math.TestNonlinear")], dir)] ==
                  ["PowerSystems_Examples_AC1ph_DC_Drives_DCmotor_ser", "ModelicaTest_Math_TestNonlinear"]
        end
    end
end
