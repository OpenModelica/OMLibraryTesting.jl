#=
Tests for the MAP-LIB reference downloads (src/references.jl): the paths and branch, and one small
model fetched (11 bytes), one that MAP-LIB does not have.
=#

@testset "MAP-LIB reference results" begin
    @test OLT.maplib_branch("4.1.0+maint.om") == "v4.1.0"
    @test OLT.maplib_branch("3.2.3") == "v3.2.3"
    @test OLT.maplib_reference_path("ModelicaTest.Blocks.Limiters") == "ModelicaTest/Blocks/Limiters/Limiters"
    @test OLT.maplib_reference_path("Modelica.Blocks.Examples.PID_Controller") ==
          "Modelica/Blocks/Examples/PID_Controller/PID_Controller"
    @test_throws ArgumentError OLT.download_references(OLT.coverage_target(; library = "PNlib@3.0.0"))
    mktempdir() do dir
        @test OLT.download_references(["ModelicaTest.Math.TestNonlinear", "ModelicaTest.NoSuchModel"], dir;
                                      branch = "v4.1.0") == 1
        @test isfile(joinpath(dir, "csv", "ModelicaTest_Math_TestNonlinear.csv"))
        @test isfile(joinpath(dir, "signals", "ModelicaTest_Math_TestNonlinear.txt"))
        @test !isfile(joinpath(dir, "csv", "ModelicaTest_NoSuchModel.csv"))
        @test isempty(filter(endswith(".part"), readdir(joinpath(dir, "csv"))))
        #= The downloaded file is the one auto_detect_references! finds. =#
        local spec = OLT.ModelSpec("ModelicaTest.Math.TestNonlinear", "TestNonlinear", "Math", 1.0, OLT.VALIDATE,
                                   Dict{String, Float64}(), 0.0, 0.0, "", Dict{String, String}(), "", Set{OLT.Phase}())
        @test only(OLT.auto_detect_references!([spec], dir)).referenceFile == "ModelicaTest_Math_TestNonlinear"
    end
end
