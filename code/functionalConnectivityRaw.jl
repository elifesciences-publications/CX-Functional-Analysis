## We first load the fluorescence analysis Package, together with the labbook related functions
#using dynamicFluo
using JLD
using DataFrames
using subpixelRegistration
using Images
using FileIO,ImageMagick
using FluorescentSeries
using Unitful
using PrairieFunctionalConnectivity

############################################## Parameters definition ###########
## Where the labbook table is :
tablePath = "PairsForConnectivity.csv"

### Where the data is :
baseDataFolder =  "../../smb/smb-share:server=dm11,share=jayaramanlab/DATA/Romain/LALConnectivityProject/"

### Which experimental day we want to process (or nothing if we want to process everything) :
#expday=nothing
expday = ARGS##["jul0617"]

### Correct for movement artefacts in individual runs?
@everywhere mvtCorrect = false

### Apply a clustering step after detecting the fluorescent regions (analysis gets pretty slow when true) :
dynclust = false

### DF of all results
toUpdate = true
#toUpdate = false
#################################################################################

problemFolders = String[]

linesToType = readtable("LinesAndTypes.csv")
(mainTab,subTab) = PrairieFunctionalConnectivity.readLabbook(tablePath,expDay=expday)

if toUpdate == false
    fullDf = Dict()
    images = Dict()
else
    fullDf = JLD.load("rawData.jld")
    images = JLD.load("expImages.jld")
end

for i in (1:size(subTab)[1])

    if subTab[i,:][:TAGS] == ":Movement:"
        mvtCorrect=true
    end

    genotypePre = subTab[Symbol(subTab[:ActivatorExp][i])][i]
    genotypePost = subTab[:ActivatorExp][i] == "Gal4" ? subTab[:LexA][i] : subTab[:Gal4][i]
    cellPre = linesToType[:Type_Description][linesToType[:Line] .== genotypePre][1]
    cellPost = linesToType[:Type_Description][linesToType[:Line] .== genotypePost][1]
    cellToCell = "$(cellPre)-to-$(cellPost)"
    genotype = "$(subTab[:LexA][i])LexA-$(subTab[:Gal4][i])Gal4-Chrimson-in-$(subTab[:ActivatorExp][i])"
    expName = "$(cellToCell)/$(genotype)/$(subTab[:Region][i])/$(subTab[:folderName][i])-Fly$(getFlyN(subTab[i,:],mainTab))"

    fly = PrairieFunctionalConnectivity.makeflyDict(subTab[i,:],dataFolder=baseDataFolder);

    pockelsParams = [fly[i]["globalConfig"]["laserPower_0"] for i in eachindex(fly)]
    runs = subTab[i,:RegionRuns]

    if (length(subTab[i,:][:Drug][1]) !== 0)
        drugStart = DateTime(subTab[i,:][:DrugTime][1][1:8],"H:M:S")
    else
        drugStart = DataFrames.NA
    end

    println(expName)

    if length(fly) == 0
        println("Nothing in there")
        push!(problemFolders,expName)
        continue
    end
    ## Load all the data to get the baseline and the ROIs
    runFluos = pmap(fly) do run
        gc()
        roiDict = PrairieFunctionalConnectivity.runExtract(run,mvtCorrect=mvtCorrect)
    end

    ## Checking for inhomogenous ROIs
    if any(runFluos .== "Run not completed")
        println("Bad runs selection, one couldn't be loaded")
        push!(problemFolders,expName)
        continue
    end

    if any([size(runFluos[run]["av"]) != (size(runFluos[1]["av"])) for run in 2:length(runFluos)])
        println("Bad runs selection, some have a different size...")
        push!(problemFolders,expName)
        continue
    end
    ## Alignment of the different runs, relatively low resolution (so pixel statistics are not affected)
    #repeatsDft = Array(Array{Dict},length(runFluos)-1)
    maxShiftPos = [0;0]
    maxShiftNeg = [0;0]
    for run in 1:(length(runFluos)-1)
        registration = stackDftReg(runFluos[run]["av"],ref=runFluos[length(runFluos)]["av"],ufac=1)
        maxShiftPos = round(Int64,maximum([maxShiftPos registration["shift"]],2))
        maxShiftNeg = round(Int64,minimum([maxShiftNeg registration["shift"]],2))
        ## Align the grand averages
        runFluos[run]["av"] = alignFromDict(runFluos[run]["av"],registration)
        ## Align the run averages (those are "volumes" so we need to set the z shift to 0)
        registration["shift"] = [registration["shift"];0]
        runFluos[run]["runAv"] = alignFromDict(runFluos[run]["runAv"],registration)
        ## Finally align the individual runs
        for rep in 1:length(runFluos[run]["green"])
            runFluos[run]["green"][rep][:,:,:] = alignFromDict(runFluos[run]["green"][rep],registration)
        end
    end
    ## Cropping everything to the area common to all repeats // catch time to drug
    cropRegion = [(1+maxShiftPos[i]):(size(runFluos[1]["av"])[i]+maxShiftNeg[i]) for i in 1:2]
    for run in 1:length(runFluos)
        runFluos[run]["av"] = runFluos[run]["av"][cropRegion...]
        runFluos[run]["runAv"] = runFluos[run]["runAv"][cropRegion...,:]
        for rep in 1:length(runFluos[run]["green"])
            runFluos[run]["green"][rep] = runFluos[run]["green"][rep][cropRegion...,:]
        end
        if !isna(drugStart)
                runFluos[run]["timeToDrug"] = drugStart - runFluos[run]["runStart"]
        else
            runFluos[run]["timeToDrug"] = DataFrames.NA
        end
    end

    ## Average of all the repeats
    grdAv = mapreduce(x -> x["av"],+,runFluos)/length(runFluos) ##*(2^16)
    #grdAv = AxisArray(grdAv,

    using Clustering
    function kMeansIm(img,nl)
        imgR = reshape(img,(size(img)[1]*size(img)[2],nimages(img))).'
        kRes = kmeans(imgR,nl)
        ### We want the cluster numbers to be sorted by the average intensity in the cluster
        reord = sortperm(mean(kRes.centers,1)[:])
        clusts = map((x) -> findfirst(reord,x),assignments(kRes))
        roi = reshape(clusts,size_spatial(img))-1
        roi
    end
    fluorescentRegions = kMeansIm(grdAv,2)


    fluoSimple = [cat(3,[FluorescentSerie(rep,fluorescentRegions) for rep in runF["green"]]...) for runF in runFluos]
    fluoParams = [Dict("pulseNumber" => runF["pulseNumber"],"timeToDrug" => runF["timeToDrug"],"stimIntensity"=>runF["stimIntensity"]) for runF in runFluos]
    ## Find the global F0 as the median of the 3% dimmer pixels ?

    deltaFluoSimple = fluoSimple
    globalBackground = mean([run["B"] for run in runFluos])
    powerLevels = unique(pockelsParams)
    if length(powerLevels)>1
      info("More than one Pockels setting used here")
    end

    globalBaseline = Array{Array{Float64,1}}(length(powerLevels))
    for pw in eachindex(powerLevels)
        runsIdx = find(pockelsParams .== powerLevels[pw])
        if length(runsIdx) == 1
            giantFluo = fluoSimple[runsIdx[1]]
        else
            #giantFluo = vcat(fluoSimple[runsIdx]...)
            giantFluo = vcat([x.data for x in fluoSimple[runsIdx]]...)
        end
        giantFluo = reshape(permutedims(giantFluo,[1;3;2]),size(giantFluo,1)*size(giantFluo,3),size(giantFluo,2))
        globalQ3 = [quantile(giantFluo[:,i],0.05) for i in 1:size(giantFluo)[2]]
        globalBaseline = median(giantFluo[find(giantFluo.< globalQ3.')],1)[:]
        deltaFluoSimple[runsIdx] = [deltaFF(fluoSimple[runsIdx][i],globalBaseline,globalBackground) for i in eachindex(fluoSimple[runsIdx])]
    end

    fullDf["$(subTab[:folderName][i])-Fly$(getFlyN(subTab[i,:],mainTab))-$(subTab[:Region][i])"] = collect(zip(deltaFluoSimple,fluoParams))

    grdAv = AxisArray(Gray.(N4f12.(grdAv)),axes(runFluos[1]["green"][1],1),axes(runFluos[1]["green"][1],2))
    fluorescentRegions = AxisArray(fluorescentRegions,axes(runFluos[1]["green"][1],1),axes(runFluos[1]["green"][1],2))

    images["$(subTab[:folderName][i])-Fly$(getFlyN(subTab[i,:],mainTab))-$(subTab[:Region][i])"] = Dict("average_image"=> grdAv,"ROIs"=> fluorescentRegions)
end

#JLD.save("rawDataLocal.jld",fullDfLocal)
JLD.save("rawData.jld",fullDf)
JLD.save("expImages.jld",images)

JLD.save("labbookTable.jld","df",mainTab)
