function results = make_dff_movie_and_psd(matFile, varargin)
%MAKE_DFF_MOVIE_AND_PSD Calculate uncorrected DeltaF/F, a movie, and PSDs.
%
%   results = make_dff_movie_and_psd(matFile)
%   results = make_dff_movie_and_psd(matFile, Name, Value, ...)
%
% MATFILE can be a full/relative path or only a file name. A file name is
% searched for in the current folder, the project's Data/alldata folder,
% and the project's Data folder.
%
% The input MAT file must contain:
%   RawCa     - height-by-width-by-time 470-nm calcium image stack
%   FrameRate - sampling rate in Hz
%
% DeltaF/F follows the existing Code pipeline: a per-pixel baseline is the
% specified percentile in consecutive time blocks, with linear interpolation
% between block baselines. The saved dff stack and all PSDs are calculated
% from the uncorrected RawCa signal. No left/right hemisphere analysis is
% performed because the recordings do not have hemisphere labels.
%
% Outputs are saved in Results/CalWave by default:
%   <stem>_dff.mat              uncorrected DeltaF/F and metadata
%   <stem>_dff_movie.mp4        Raw fluorescence + DeltaF/F movie
%   <stem>_dff_PSD.mat           numerical PSD results
%   <stem>_dff_PSD_1x2.png       Global and 5-by-5-bin PSD distribution plot
%   <stem>_dff_PSD_1x2_log.png   log-log version of the PSD plot
%
% The implementation uses MATFILE and processes the image stack in chunks,
% so the complete recording is not loaded into RAM.

parser = inputParser;
parser.FunctionName = mfilename;
addRequired(parser, 'matFile', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'OutputDir', '', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'RawCaVariable', 'RawCa', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'FrameRateVariable', 'FrameRate', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'FrameRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
addParameter(parser, 'BrainMask', [], @(x) isempty(x) || islogical(x) || isnumeric(x));
addParameter(parser, 'BaselineWindowSeconds', 30, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(parser, 'BaselinePercentile', 10, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 0 && x <= 100);
addParameter(parser, 'ChunkSize', 100, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'MaxSampleFrames', 200, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'SpatialSampleStep', 4, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'MovieQuality', 90, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 0 && x <= 100);
addParameter(parser, 'MoviePlaybackRateScale', 1, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(parser, 'MovieDurationSeconds', 600, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(parser, 'WelchWindowSeconds', 30, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0);
addParameter(parser, 'WelchOverlapFraction', 0.5, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 0 && x < 1);
addParameter(parser, 'AnalysisChunkSeconds', 900, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 600);
addParameter(parser, 'FrequencyRangeHz', [0, 8], ...
    @(x) isnumeric(x) && numel(x) == 2 && all(isfinite(x)) && x(1) >= 0 && x(2) > x(1));
addParameter(parser, 'SpatialBinSize', 5, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1 && ...
    x == round(x));
addParameter(parser, 'MinimumCorticalPixelsPerBin', 1, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1 && ...
    x == round(x));
addParameter(parser, 'FrequencyChunkSize', 64, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'ProgressEvery', 500, ...
    @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'FigureVisible', 'off', ...
    @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'Overwrite', false, @(x) islogical(x) && isscalar(x));
parse(parser, matFile, varargin{:});
options = parser.Results;

rawCaVariable = char(options.RawCaVariable);
frameRateVariable = char(options.FrameRateVariable);
inputFile = resolveInputFile(char(options.matFile));
variableInfo = whos('-file', inputFile);
variableNames = {variableInfo.name};

if ~ismember(rawCaVariable, variableNames)
    error('make_dff_movie_and_psd:MissingRawCa', ...
        'The MAT file does not contain variable "%s": %s', ...
        rawCaVariable, inputFile);
end

rawInfo = variableInfo(strcmp({variableInfo.name}, rawCaVariable));
rawSize = rawInfo.size;
if numel(rawSize) ~= 3
    error('make_dff_movie_and_psd:InvalidRawCa', ...
        'Variable "%s" must be a 3-D image stack. Found size %s.', ...
        rawCaVariable, mat2str(rawSize));
end
[nRows, nColumns, nFrames] = deal(rawSize(1), rawSize(2), rawSize(3));
if any([nRows, nColumns, nFrames] < 2)
    error('make_dff_movie_and_psd:InvalidRawCa', ...
        'RawCa dimensions must all be at least 2.');
end

if isempty(options.FrameRate)
    if ~ismember(frameRateVariable, variableNames)
        error('make_dff_movie_and_psd:MissingFrameRate', ...
            ['The MAT file does not contain "%s". Provide the sampling ', ...
             'rate with the ''FrameRate'' option.'], frameRateVariable);
    end
    frameRateData = load(inputFile, frameRateVariable);
    frameRate = frameRateData.(frameRateVariable);
else
    frameRate = options.FrameRate;
end
frameRate = double(frameRate);
if ~isscalar(frameRate) || ~isfinite(frameRate) || frameRate <= 0
    error('make_dff_movie_and_psd:InvalidFrameRate', ...
        'FrameRate must be a positive, finite scalar.');
end

outputDir = resolveOutputDir(options.OutputDir);
if ~isfolder(outputDir)
    mkdir(outputDir);
end
[~, inputStem] = fileparts(inputFile);
dffFile = fullfile(outputDir, [inputStem '_dff.mat']);
movieFile = fullfile(outputDir, [inputStem '_dff_movie.mp4']);
psdFile = fullfile(outputDir, [inputStem '_dff_PSD.mat']);
plotFile = fullfile(outputDir, [inputStem '_dff_PSD_1x2.png']);
logPlotFile = fullfile(outputDir, [inputStem '_dff_PSD_1x2_log.png']);

outputFiles = {dffFile, movieFile, psdFile, plotFile, logPlotFile};
existingFiles = outputFiles(cellfun(@isfile, outputFiles));
if ~isempty(existingFiles) && ~options.Overwrite
    error('make_dff_movie_and_psd:OutputExists', ...
        ['One or more output files already exist. Set ''Overwrite'', true ', ...
         'to replace them:\n%s'], strjoin(existingFiles, newline));
end
if options.Overwrite
    for fileNumber = 1:numel(outputFiles)
        deleteIfExists(outputFiles{fileNumber});
    end
end

fprintf('Input: %s\n', inputFile);
fprintf('RawCa size: %d x %d x %d frames\n', nRows, nColumns, nFrames);
fprintf('Frame rate: %.6g Hz (duration %.2f seconds)\n', ...
    frameRate, nFrames / frameRate);
fprintf('PSD source: uncorrected 470-nm DeltaF/F\n');

dataFile = matfile(inputFile);
try
    testFrame = readRawCa(dataFile, rawCaVariable, 1, 1:nRows, 1:nColumns);
catch exception
    error('make_dff_movie_and_psd:PartialReadFailed', ...
        ['Could not read a partial RawCa frame. Save large MAT files with ', ...
         'MATLAB -v7.3. Original error: %s'], exception.message);
end
if ~isnumeric(testFrame) && ~islogical(testFrame)
    error('make_dff_movie_and_psd:InvalidRawCaType', ...
        'RawCa must contain numeric or logical image data.');
end
clear testFrame;

%% Step 1: Reference image and cortical mask
nSampleFrames = min(round(options.MaxSampleFrames), nFrames);
sampleFrames = unique(round(linspace(1, nFrames, nSampleFrames)));
% MATFILE requires equally spaced index ranges. linspace usually produces
% uneven gaps after rounding, so read these distributed sample frames one at
% a time rather than passing the complete sampleFrames vector at once.
referenceStack = zeros(nRows, nColumns, numel(sampleFrames), 'single');
for sampleNumber = 1:numel(sampleFrames)
    referenceStack(:, :, sampleNumber) = single(readRawCa( ...
        dataFile, rawCaVariable, sampleFrames(sampleNumber), ...
        1:nRows, 1:nColumns));
end
referenceImage = finiteMean(referenceStack, 3);

if isempty(options.BrainMask)
    brainMask = makeAutomaticBrainMask(referenceImage);
else
    brainMask = logical(options.BrainMask);
    if ~isequal(size(brainMask), [nRows, nColumns])
        error('make_dff_movie_and_psd:InvalidBrainMask', ...
            'BrainMask dimensions must match RawCa dimensions.');
    end
end
if nnz(brainMask) < 2
    error('make_dff_movie_and_psd:EmptyBrainMask', ...
        'The cortical BrainMask contains fewer than two pixels.');
end
fprintf('Cortical mask covers %d pixels (%.1f%% of image).\n', ...
    nnz(brainMask), 100 * nnz(brainMask) / numel(brainMask));

%% Step 2: Dynamic per-pixel baseline
framesPerBaselineBlock = max(2, round( ...
    options.BaselineWindowSeconds * frameRate));
blockStarts = 1:framesPerBaselineBlock:nFrames;
nBlocks = numel(blockStarts);
baselineAnchors = zeros(nRows, nColumns, nBlocks, 'single');
anchorFrames = zeros(1, nBlocks);

fprintf('Calculating %d baseline anchors using the %.1fth percentile...\n', ...
    nBlocks, options.BaselinePercentile);
for blockNumber = 1:nBlocks
    firstFrame = blockStarts(blockNumber);
    lastFrame = min(firstFrame + framesPerBaselineBlock - 1, nFrames);
    blockFrames = firstFrame:lastFrame;
    rawBlock = single(readRawCa(dataFile, rawCaVariable, blockFrames, ...
        1:nRows, 1:nColumns));
    sortedBlock = sort(rawBlock, 3);
    baselineIndex = max(1, min(numel(blockFrames), round( ...
        (options.BaselinePercentile / 100) * numel(blockFrames))));
    baselineAnchors(:, :, blockNumber) = sortedBlock(:, :, baselineIndex);
    anchorFrames(blockNumber) = mean([firstFrame, lastFrame]);

    if mod(blockNumber, 10) == 0 || blockNumber == nBlocks
        fprintf('Baseline block: %d/%d\n', blockNumber, nBlocks);
    end
end

%% Step 3: Fixed display limits for the movie
spatialStep = round(options.SpatialSampleStep);
sampleRows = 1:spatialStep:nRows;
sampleColumns = 1:spatialStep:nColumns;
nSamplePixels = numel(sampleRows) * numel(sampleColumns);
sampleDff = zeros(nSamplePixels * numel(sampleFrames), 1, 'single');
sampleRaw = zeros(size(sampleDff), 'single');
nextSampleIndex = 1;

for k = 1:numel(sampleFrames)
    frameNumber = sampleFrames(k);
    baselineFrame = interpolateBaseline(baselineAnchors, anchorFrames, frameNumber);
    rawFrame = single(readRawCa(dataFile, rawCaVariable, frameNumber, ...
        1:nRows, 1:nColumns));
    dffFrame = calculateDff(rawFrame, baselineFrame, brainMask);
    sampledDff = dffFrame(sampleRows, sampleColumns);
    sampledRaw = rawFrame(sampleRows, sampleColumns);
    indices = nextSampleIndex:(nextSampleIndex + numel(sampledDff) - 1);
    sampleDff(indices) = sampledDff(:);
    sampleRaw(indices) = sampledRaw(:);
    nextSampleIndex = nextSampleIndex + numel(sampledDff);
end

finiteDff = sort(abs(sampleDff(isfinite(sampleDff))));
if isempty(finiteDff) || finiteDff(end) <= 0
    error('make_dff_movie_and_psd:InvalidDffRange', ...
        'Could not determine a valid DeltaF/F movie range.');
end
dffColorLimit = finiteDff(percentileIndex(99.5, numel(finiteDff)));
if dffColorLimit <= 0
    dffColorLimit = finiteDff(end);
end

finiteRaw = sort(sampleRaw(isfinite(sampleRaw)));
if isempty(finiteRaw) || finiteRaw(end) <= finiteRaw(1)
    error('make_dff_movie_and_psd:InvalidRawRange', ...
        'Could not determine a valid raw fluorescence display range.');
end
rawDisplayLimits = double([finiteRaw(percentileIndex(1, numel(finiteRaw))), ...
    finiteRaw(percentileIndex(99.5, numel(finiteRaw)))]);
if rawDisplayLimits(2) <= rawDisplayLimits(1)
    rawDisplayLimits = double([finiteRaw(1), finiteRaw(end)]);
end
fprintf('DeltaF/F movie range: %.3f%% to %.3f%%\n', ...
    -100 * dffColorLimit, 100 * dffColorLimit);

%% Step 4: Calculate uncorrected DeltaF/F and write the movie
dffOutput = matfile(dffFile, 'Writable', true);
dffOutput.dff(nRows, nColumns, nFrames) = single(0);
dffOutput.FrameRate = frameRate;
dffOutput.brainMask = brainMask;
dffOutput.referenceImage = referenceImage;
dffOutput.baselineAnchors = baselineAnchors;
dffOutput.baselineAnchorFrames = anchorFrames;
dffOutput.baselineWindowSeconds = options.BaselineWindowSeconds;
dffOutput.baselinePercentile = options.BaselinePercentile;
dffOutput.dffUnits = 'fraction';
dffOutput.dffIsUncorrected = true;
dffOutput.movieDurationSeconds = options.MovieDurationSeconds;
dffOutput.processingComplete = false;

movieFigure = figure('Color', 'k', 'Visible', char(options.FigureVisible), ...
    'Name', 'Uncorrected RawCa and DeltaF/F movie', ...
    'Units', 'pixels', 'Position', [100, 50, 720, 900], ...
    'MenuBar', 'none', 'ToolBar', 'none');
rawAxes = axes(movieFigure, 'Position', [0.07, 0.54, 0.74, 0.41], 'Color', 'k');
dffAxes = axes(movieFigure, 'Position', [0.07, 0.06, 0.74, 0.41], 'Color', 'k');

firstBaseline = interpolateBaseline(baselineAnchors, anchorFrames, 1);
firstRaw = single(readRawCa(dataFile, rawCaVariable, 1, 1:nRows, 1:nColumns));
firstDff = calculateDff(firstRaw, firstBaseline, brainMask);
rawImageHandle = imagesc(rawAxes, firstRaw);
axis(rawAxes, 'image');
axis(rawAxes, 'off');
colormap(rawAxes, gray(256));
clim(rawAxes, rawDisplayLimits);
rawTitleHandle = title(rawAxes, 'Raw fluorescence (uncorrected) | Time = 0.00 s', ...
    'Color', 'w', 'FontWeight', 'normal');

dffImageHandle = imagesc(dffAxes, 100 .* firstDff);
dffImageHandle.AlphaData = brainMask;
axis(dffAxes, 'image');
axis(dffAxes, 'off');
colormap(dffAxes, parula(256));
clim(dffAxes, [-100 * dffColorLimit, 100 * dffColorLimit]);
colorbarHandle = colorbar(dffAxes, 'Color', 'w');
colorbarHandle.Label.String = '\DeltaF/F (%)';
colorbarHandle.Label.Color = 'w';
dffTitleHandle = title(dffAxes, '\DeltaF/F (uncorrected) | Time = 0.00 s', ...
    'Color', 'w', 'FontWeight', 'normal');

writer = VideoWriter(movieFile, 'MPEG-4');
writer.FrameRate = frameRate * options.MoviePlaybackRateScale;
writer.Quality = options.MovieQuality;
open(writer);
movieFrameCount = min(nFrames, max(1, round( ...
    options.MovieDurationSeconds * frameRate)));
fprintf('Writing the first %.2f minutes of video (%d/%d frames).\n', ...
    movieFrameCount / frameRate / 60, movieFrameCount, nFrames);

globalSignal = zeros(1, nFrames, 'single');
chunkSize = round(options.ChunkSize);
progressEvery = round(options.ProgressEvery);

fprintf('Calculating uncorrected DeltaF/F and writing the movie...\n');
try
    for firstFrameNumber = 1:chunkSize:nFrames
        lastFrameNumber = min(nFrames, firstFrameNumber + chunkSize - 1);
        frameNumbers = firstFrameNumber:lastFrameNumber;
        rawChunk = single(readRawCa(dataFile, rawCaVariable, frameNumbers, ...
            1:nRows, 1:nColumns));
        dffChunk = zeros(nRows, nColumns, numel(frameNumbers), 'single');

        for chunkFrame = 1:numel(frameNumbers)
            frameNumber = frameNumbers(chunkFrame);
            rawFrame = rawChunk(:, :, chunkFrame);
            baselineFrame = interpolateBaseline( ...
                baselineAnchors, anchorFrames, frameNumber);
            dffFrame = calculateDff(rawFrame, baselineFrame, brainMask);
            dffChunk(:, :, chunkFrame) = dffFrame;
            globalSignal(frameNumber) = finiteScalarMean(dffFrame(brainMask));
        end
        dffOutput.dff(:, :, frameNumbers) = dffChunk;

        for chunkFrame = 1:numel(frameNumbers)
            frameNumber = frameNumbers(chunkFrame);
            if frameNumber <= movieFrameCount
                elapsedTime = (frameNumber - 1) / frameRate;
                rawImageHandle.CData = rawChunk(:, :, chunkFrame);
                dffImageHandle.CData = 100 .* dffChunk(:, :, chunkFrame);
                rawTitleHandle.String = sprintf( ...
                    'Raw fluorescence (uncorrected) | Time = %.2f s', elapsedTime);
                dffTitleHandle.String = sprintf( ...
                    '\\DeltaF/F (uncorrected) | Time = %.2f s', elapsedTime);
                drawnow;
                writeVideo(writer, getframe(movieFigure));
            end
        end

        if mod(lastFrameNumber, progressEvery) < chunkSize || lastFrameNumber == nFrames
            fprintf('DeltaF/F processing: %d/%d frames (%.1f%%)\n', ...
                lastFrameNumber, nFrames, 100 * lastFrameNumber / nFrames);
        end
    end
    close(writer);
catch exception
    close(writer);
    close(movieFigure);
    rethrow(exception);
end
close(movieFigure);
dffOutput.globalSignal = globalSignal;
dffOutput.processingComplete = true;

%% Step 5: Welch PSD summaries from uncorrected DeltaF/F
windowSamples = max(2, round(options.WelchWindowSeconds * frameRate));
windowSamples = min(windowSamples, nFrames);
overlapSamples = round(options.WelchOverlapFraction * windowSamples);
if overlapSamples >= windowSamples
    error('make_dff_movie_and_psd:InvalidWelchOverlap', ...
        'Welch overlap must be smaller than the window length.');
end

% Split long recordings into analysis blocks. Each block is at least the
% requested duration, and the final short remainder is merged into the
% preceding block so every block can use the same Welch frequency axis.
analysisChunkFrames = max(windowSamples, round( ...
    options.AnalysisChunkSeconds * frameRate));
analysisChunkStarts = 1:analysisChunkFrames:nFrames;
if numel(analysisChunkStarts) > 1 && ...
        nFrames - analysisChunkStarts(end) + 1 < windowSamples
    analysisChunkStarts(end) = [];
end
analysisChunkEnds = [analysisChunkStarts(2:end) - 1, nFrames];
nAnalysisChunks = numel(analysisChunkStarts);
analysisChunkDurations = analysisChunkEnds - analysisChunkStarts + 1;

fprintf(['PSD time chunks: %d blocks, target %.1f minutes (%.1f to %.1f ', ...
    'minutes per block)\n'], nAnalysisChunks, ...
    options.AnalysisChunkSeconds / 60, ...
    min(analysisChunkDurations) / frameRate / 60, ...
    max(analysisChunkDurations) / frameRate / 60);

globalPSDAccumulator = [];
globalSegmentWeight = 0;
for chunkNumber = 1:nAnalysisChunks
    chunkFrames = analysisChunkStarts(chunkNumber):analysisChunkEnds(chunkNumber);
    [chunkPSD, chunkFrequencies, chunkSegmentCount] = localWelchPSD( ...
        globalSignal(chunkFrames), frameRate, windowSamples, overlapSamples);
    if isempty(globalPSDAccumulator)
        globalPSDAccumulator = zeros(size(chunkPSD));
        frequencies = chunkFrequencies;
    elseif ~isequal(frequencies, chunkFrequencies)
        error('make_dff_movie_and_psd:FrequencyMismatch', ...
            'Global PSD frequency axes differ between time chunks.');
    end
    globalPSDAccumulator = globalPSDAccumulator + ...
        chunkPSD .* chunkSegmentCount;
    globalSegmentWeight = globalSegmentWeight + chunkSegmentCount;
end
globalPSD = globalPSDAccumulator ./ globalSegmentWeight;
frequencyUpper = min(options.FrequencyRangeHz(2), frameRate / 2);
frequencyMask = frequencies >= options.FrequencyRangeHz(1) & ...
    frequencies <= frequencyUpper;
if ~any(frequencyMask)
    error('make_dff_movie_and_psd:EmptyFrequencyRange', ...
        'FrequencyRangeHz contains no Welch frequency bins.');
end

% Merge cortical pixels into spatial bins before calculating PSD. This is
% substantially faster than running Welch PSD for every individual pixel.
spatialBinSize = round(options.SpatialBinSize);
rowBinStarts = 1:spatialBinSize:nRows;
columnBinStarts = 1:spatialBinSize:nColumns;
nRowBins = numel(rowBinStarts);
nColumnBins = numel(columnBinStarts);
binPixelCountTable = zeros(nRowBins, nColumnBins);
binCoordinates = zeros(nRowBins * nColumnBins, 5);
binCount = 0;

for rowBin = 1:nRowBins
    rowFirst = rowBinStarts(rowBin);
    rowLast = min(nRows, rowFirst + spatialBinSize - 1);
    for columnBin = 1:nColumnBins
        columnFirst = columnBinStarts(columnBin);
        columnLast = min(nColumns, columnFirst + spatialBinSize - 1);
        nCorticalPixelsInBin = nnz(brainMask(rowFirst:rowLast, ...
            columnFirst:columnLast));
        binPixelCountTable(rowBin, columnBin) = nCorticalPixelsInBin;
        if nCorticalPixelsInBin >= options.MinimumCorticalPixelsPerBin
            binCount = binCount + 1;
            binCoordinates(binCount, :) = [rowFirst, rowLast, ...
                columnFirst, columnLast, nCorticalPixelsInBin];
        end
    end
end
binCoordinates = binCoordinates(1:binCount, :);
if binCount < 1
    error('make_dff_movie_and_psd:NoSpatialBins', ...
        'No spatial bin contains enough cortical pixels.');
end

nPositiveFrequencies = numel(frequencies);
psdOutput = matfile(psdFile, 'Writable', true);
psdOutput.globalPSD = globalPSD;
psdOutput.frequencies = frequencies;
psdOutput.frameRate = frameRate;
psdOutput.windowSamples = windowSamples;
psdOutput.overlapSamples = overlapSamples;
psdOutput.welchWindowSeconds = options.WelchWindowSeconds;
psdOutput.welchOverlapFraction = options.WelchOverlapFraction;
psdOutput.analysisChunkSeconds = options.AnalysisChunkSeconds;
psdOutput.analysisChunkFrames = analysisChunkFrames;
psdOutput.analysisChunkStarts = analysisChunkStarts;
psdOutput.analysisChunkEnds = analysisChunkEnds;
psdOutput.nAnalysisChunks = nAnalysisChunks;
psdOutput.spatialBinSize = spatialBinSize;
psdOutput.minimumCorticalPixelsPerBin = options.MinimumCorticalPixelsPerBin;
psdOutput.nSpatialBins = binCount;
psdOutput.binCoordinates = binCoordinates;
psdOutput.psdAggregation = ...
    'Welch segment-weighted average across time chunks and 5-by-5 spatial bins';
psdOutput.sourceDffFile = dffFile;
psdOutput.sourceSignal = 'Uncorrected 470-nm DeltaF/F';
psdOutput.brainMask = brainMask;
psdOutput.processingComplete = false;
psdOutput.binPowerSpectra(nPositiveFrequencies, binCount) = single(0);

fprintf('Calculating Welch PSD for %d spatial bins (%d-by-%d pixels)...\n', ...
    binCount, spatialBinSize, spatialBinSize);
dffData = matfile(dffFile);
binOffset = 0;
for rowBin = 1:nRowBins
    rowFirst = rowBinStarts(rowBin);
    rowLast = min(nRows, rowFirst + spatialBinSize - 1);
    validColumnBins = find(binPixelCountTable(rowBin, :) >= ...
        options.MinimumCorticalPixelsPerBin);
    nBlockBins = numel(validColumnBins);
    if nBlockBins == 0
        continue;
    end

    binPSDAccumulator = zeros(nPositiveFrequencies, nBlockBins);
    binSegmentWeight = 0;
    for chunkNumber = 1:nAnalysisChunks
        firstChunkFrame = analysisChunkStarts(chunkNumber);
        lastChunkFrame = analysisChunkEnds(chunkNumber);
        dffBlock = single(dffData.dff(rowFirst:rowLast, :, ...
            firstChunkFrame:lastChunkFrame));
        chunkLength = lastChunkFrame - firstChunkFrame + 1;
        binSignals = zeros(chunkLength, nBlockBins, 'single');

        for blockBin = 1:nBlockBins
            columnBin = validColumnBins(blockBin);
            columnFirst = columnBinStarts(columnBin);
            columnLast = min(nColumns, columnFirst + spatialBinSize - 1);
            binMask = brainMask(rowFirst:rowLast, columnFirst:columnLast);
            binPixels = reshape(dffBlock(:, columnFirst:columnLast, :), ...
                [], chunkLength);
            binPixels = binPixels(binMask(:), :);
            binSignals(:, blockBin) = finiteMean(binPixels, 1).';
        end

        [binPSD, binFrequencies, binSegmentCount] = localWelchPSD( ...
            binSignals, frameRate, windowSamples, overlapSamples);
        if ~isequal(frequencies, binFrequencies)
            error('make_dff_movie_and_psd:FrequencyMismatch', ...
                'Spatial-bin and global PSD frequency axes do not match.');
        end
        binPSDAccumulator = binPSDAccumulator + ...
            binPSD .* binSegmentCount;
        binSegmentWeight = binSegmentWeight + binSegmentCount;
        clear dffBlock binSignals binPixels binPSD;
    end
    binPSD = binPSDAccumulator ./ binSegmentWeight;

    binIndices = binOffset + (1:nBlockBins);
    psdOutput.binPowerSpectra(:, binIndices) = single(binPSD);
    binOffset = binOffset + nBlockBins;
    clear binPSDAccumulator binPSD;

    if mod(rowBin, 10) == 0 || rowBin == nRowBins
        fprintf('Spatial-bin PSD: %d/%d bins (%.1f%%)\n', binOffset, ...
            binCount, 100 * binOffset / binCount);
    end
end

if binOffset ~= binCount
    error('make_dff_movie_and_psd:BinCountMismatch', ...
        'Not all valid spatial bins were processed.');
end

% Calculate exact row-wise quartiles from the on-disk bin PSD matrix in
% frequency chunks, avoiding a second large in-memory PSD matrix.
binPercentiles = zeros(nPositiveFrequencies, 3, 'single');
frequencyChunkSize = round(options.FrequencyChunkSize);
for firstFrequency = 1:frequencyChunkSize:nPositiveFrequencies
    lastFrequency = min(nPositiveFrequencies, ...
        firstFrequency + frequencyChunkSize - 1);
    binPsdRows = double(psdOutput.binPowerSpectra( ...
        firstFrequency:lastFrequency, 1:binCount));
    binPercentiles(firstFrequency:lastFrequency, :) = single( ...
        rowQuantiles(binPsdRows, [25, 50, 75]));
end

psdOutput.binPercentiles = binPercentiles;
psdOutput.percentileDefinition = ...
    'Linear interpolation across sorted 5-by-5 spatial-bin spectra';
psdOutput.frequencyRangeHz = options.FrequencyRangeHz;
psdOutput.processingComplete = true;

%% Step 6: Save the 1-by-2 PSD plot
plotFrequencies = frequencies(frequencyMask);
plotGlobalPSD = globalPSD(frequencyMask);
plotBinPercentiles = binPercentiles(frequencyMask, :);

psdFigure = figure('Color', 'w', 'Visible', char(options.FigureVisible), ...
    'Name', 'Uncorrected DeltaF/F PSD summaries', ...
    'Units', 'pixels', 'Position', [80, 120, 1500, 560]);
plotLayout = tiledlayout(psdFigure, 1, 2, 'TileSpacing', 'compact', ...
    'Padding', 'compact');

globalAxes = nexttile(plotLayout, 1);
plot(globalAxes, plotFrequencies, plotGlobalPSD, ...
    'Color', [0.10, 0.35, 0.75], 'LineWidth', 1.5);
grid(globalAxes, 'on');
xlabel(globalAxes, 'Frequency (Hz)');
ylabel(globalAxes, 'Power [(DeltaF/F)^2/Hz]');
title(globalAxes, 'Global PSD');
xlim(globalAxes, [plotFrequencies(1), plotFrequencies(end)]);

pixelAxes = nexttile(plotLayout, 2);
hold(pixelAxes, 'on');
fill(pixelAxes, [plotFrequencies; flipud(plotFrequencies)], ...
    [plotBinPercentiles(:, 1); flipud(plotBinPercentiles(:, 3))], ...
    [0.75, 0.82, 0.95], 'EdgeColor', 'none', ...
    'FaceAlpha', 0.8, 'DisplayName', '25th-75th percentile');
plot(pixelAxes, plotFrequencies, plotBinPercentiles(:, 2), ...
    'Color', [0.10, 0.35, 0.75], 'LineWidth', 1.5, ...
    'DisplayName', 'Median');
hold(pixelAxes, 'off');
grid(pixelAxes, 'on');
xlabel(pixelAxes, 'Frequency (Hz)');
ylabel(pixelAxes, 'Power [(DeltaF/F)^2/Hz]');
title(pixelAxes, sprintf('%d-by-%d spatial-bin PSD distribution (n = %d)', ...
    spatialBinSize, spatialBinSize, binCount));
xlim(pixelAxes, [plotFrequencies(1), plotFrequencies(end)]);
legend(pixelAxes, 'Location', 'best');

exportgraphics(psdFigure, plotFile, 'Resolution', 200);
close(psdFigure);

%% Step 7: Save the log-log version of the 1-by-2 PSD plot
% The DC bin is excluded because zero frequency cannot be displayed on a
% logarithmic x-axis. A tiny positive floor only handles exact zero-power
% bins and does not alter the linear-scale PSD saved above.
logFrequencyMask = frequencyMask & frequencies > 0;
if ~any(logFrequencyMask)
    error('make_dff_movie_and_psd:EmptyLogFrequencyRange', ...
        'The selected frequency range contains no positive frequencies.');
end
logFrequencies = frequencies(logFrequencyMask);
logGlobalPSD = max(globalPSD(logFrequencyMask), eps);
logBinPercentiles = max(binPercentiles(logFrequencyMask, :), eps);

logPsdFigure = figure('Color', 'w', ...
    'Visible', char(options.FigureVisible), ...
    'Name', 'Uncorrected DeltaF/F PSD summaries (log-log)', ...
    'Units', 'pixels', 'Position', [80, 120, 1500, 560]);
logPlotLayout = tiledlayout(logPsdFigure, 1, 2, ...
    'TileSpacing', 'compact', 'Padding', 'compact');

logGlobalAxes = nexttile(logPlotLayout, 1);
loglog(logGlobalAxes, logFrequencies, logGlobalPSD, ...
    'Color', [0.10, 0.35, 0.75], 'LineWidth', 1.5);
grid(logGlobalAxes, 'on');
xlabel(logGlobalAxes, 'Frequency (Hz)');
ylabel(logGlobalAxes, 'Power [(DeltaF/F)^2/Hz]');
title(logGlobalAxes, 'Global PSD (log-log)');
xlim(logGlobalAxes, [logFrequencies(1), logFrequencies(end)]);

logPixelAxes = nexttile(logPlotLayout, 2);
hold(logPixelAxes, 'on');
fill(logPixelAxes, [logFrequencies; flipud(logFrequencies)], ...
    [logBinPercentiles(:, 1); flipud(logBinPercentiles(:, 3))], ...
    [0.75, 0.82, 0.95], 'EdgeColor', 'none', ...
    'FaceAlpha', 0.8, 'DisplayName', '25th-75th percentile');
loglog(logPixelAxes, logFrequencies, logBinPercentiles(:, 2), ...
    'Color', [0.10, 0.35, 0.75], 'LineWidth', 1.5, ...
    'DisplayName', 'Median');
hold(logPixelAxes, 'off');
grid(logPixelAxes, 'on');
xlabel(logPixelAxes, 'Frequency (Hz)');
ylabel(logPixelAxes, 'Power [(DeltaF/F)^2/Hz]');
title(logPixelAxes, sprintf('%d-by-%d spatial-bin PSD distribution (n = %d)', ...
    spatialBinSize, spatialBinSize, binCount));
xlim(logPixelAxes, [logFrequencies(1), logFrequencies(end)]);
legend(logPixelAxes, 'Location', 'best');

exportgraphics(logPsdFigure, logPlotFile, 'Resolution', 200);
close(logPsdFigure);

results = struct();
results.inputFile = inputFile;
results.dffFile = dffFile;
results.movieFile = movieFile;
results.psdFile = psdFile;
results.plotFile = plotFile;
results.logPlotFile = logPlotFile;
results.frameRate = frameRate;
results.nFrames = nFrames;
results.nCorticalPixels = nnz(brainMask);
results.nSpatialBins = binCount;
results.spatialBinSize = spatialBinSize;
results.frequencies = frequencies;
results.globalPSD = globalPSD;
results.binPercentiles = binPercentiles;

fprintf('\nFinished.\n');
fprintf('DeltaF/F data: %s\n', dffFile);
fprintf('DeltaF/F movie: %s\n', movieFile);
fprintf('PSD results: %s\n', psdFile);
fprintf('PSD plot: %s\n', plotFile);
end

function inputFile = resolveInputFile(matFile)
if isfile(matFile)
    inputFile = matFile;
    return;
end

calWaveDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(calWaveDir);
candidateFiles = { ...
    fullfile(projectDir, 'Data', 'alldata', matFile), ...
    fullfile(projectDir, 'Data', matFile)};
for k = 1:numel(candidateFiles)
    if isfile(candidateFiles{k})
        inputFile = candidateFiles{k};
        return;
    end
end
error('make_dff_movie_and_psd:InputNotFound', ...
    'Could not find MAT file "%s" in the current folder, Data/alldata, or Data.', matFile);
end

function outputDir = resolveOutputDir(requestedOutputDir)
if ~isempty(requestedOutputDir)
    outputDir = char(requestedOutputDir);
    return;
end
calWaveDir = fileparts(mfilename('fullpath'));
projectDir = fileparts(calWaveDir);
outputDir = fullfile(projectDir, 'Results', 'CalWave');
end

function deleteIfExists(fileName)
if isfile(fileName)
    delete(fileName);
end
end

function frame = readRawCa(dataFile, variableName, frameIndices, rowIndices, columnIndices)
subscript = substruct('.', variableName, '()', ...
    {rowIndices, columnIndices, frameIndices});
frame = subsref(dataFile, subscript);
end

function meanImage = finiteMean(data, dimension)
finiteData = isfinite(data);
data(~finiteData) = 0;
counts = sum(finiteData, dimension);
meanImage = sum(data, dimension) ./ max(counts, 1);
meanImage(counts == 0) = NaN;
end

function brainMask = makeAutomaticBrainMask(referenceImage)
validReference = referenceImage(isfinite(referenceImage));
if isempty(validReference) || max(validReference) <= min(validReference)
    error('make_dff_movie_and_psd:InvalidReference', ...
        'The reference image has no usable intensity range.');
end

referenceScaled = (referenceImage - min(validReference)) ./ ...
    (max(validReference) - min(validReference));
referenceScaled(~isfinite(referenceScaled)) = 0;

requiredFunctions = {'imbinarize', 'imfill', 'bwareafilt', ...
    'strel', 'imopen', 'imclose'};
if ~all(cellfun(@(name) exist(name, 'file') == 2, requiredFunctions))
    error('make_dff_movie_and_psd:MissingImageProcessingToolbox', ...
        ['Automatic BrainMask creation requires Image Processing Toolbox. ', ...
         'Alternatively provide a BrainMask option.']);
end

brainMask = imbinarize(referenceScaled);
brainMask = imfill(brainMask, 'holes');
brainMask = bwareafilt(brainMask, 1);
brainMask = imopen(brainMask, strel('disk', 2));
brainMask = imclose(brainMask, strel('disk', 3));
maskFraction = nnz(brainMask) / numel(brainMask);
if maskFraction < 0.05 || maskFraction > 0.95
    warning(['Automatic brain mask occupied %.1f%% of the image. ', ...
        'Using the complete image; inspect and replace it if needed.'], ...
        100 * maskFraction);
    brainMask = true(size(referenceImage));
end
end

function dffFrame = calculateDff(rawFrame, baselineFrame, brainMask)
denominator = max(baselineFrame, eps('single'));
dffFrame = (single(rawFrame) - single(baselineFrame)) ./ denominator;
dffFrame(~brainMask | ~isfinite(dffFrame)) = NaN;
end

function baselineFrame = interpolateBaseline(anchors, anchorFrames, frameNumber)
if frameNumber <= anchorFrames(1)
    baselineFrame = anchors(:, :, 1);
    return;
end
if frameNumber >= anchorFrames(end)
    baselineFrame = anchors(:, :, end);
    return;
end
rightIndex = find(anchorFrames >= frameNumber, 1, 'first');
leftIndex = rightIndex - 1;
weight = (frameNumber - anchorFrames(leftIndex)) ./ ...
    (anchorFrames(rightIndex) - anchorFrames(leftIndex));
baselineFrame = (1 - weight) .* anchors(:, :, leftIndex) + ...
    weight .* anchors(:, :, rightIndex);
end

function value = finiteScalarMean(data)
finiteData = data(isfinite(data));
if isempty(finiteData)
    value = NaN;
else
    value = mean(finiteData, 'native');
end
end

function [oneSidedPSD, frequencies, segmentCount] = localWelchPSD( ...
        signals, sampleRate, windowLength, overlapLength)
% Welch PSD for one or more signals, with signals in rows = time.
signals = double(signals);
if isvector(signals)
    signals = signals(:);
end
[nSamples, nSignals] = size(signals);
if nSamples < 2
    error('make_dff_movie_and_psd:TooFewSamples', ...
        'Welch PSD requires at least two time samples.');
end

windowLength = max(2, min(round(windowLength), nSamples));
overlapLength = min(max(0, round(overlapLength)), windowLength - 1);
stepLength = windowLength - overlapLength;
segmentStarts = 1:stepLength:(nSamples - windowLength + 1);
if isempty(segmentStarts)
    segmentStarts = 1;
    windowLength = nSamples;
end

% Interpolate occasional missing pixel values before FFT.
for signalNumber = 1:nSignals
    finiteMask = isfinite(signals(:, signalNumber));
    if all(finiteMask)
        continue;
    end
    finiteIndices = find(finiteMask);
    if numel(finiteIndices) >= 2
        missingIndices = find(~finiteMask);
        signals(missingIndices, signalNumber) = interp1( ...
            finiteIndices, signals(finiteIndices, signalNumber), ...
            missingIndices, 'linear', 'extrap');
        elseif isscalar(finiteIndices)
        signals(~finiteMask, signalNumber) = signals(finiteIndices, signalNumber);
    else
        signals(:, signalNumber) = 0;
    end
end

sampleIndex = (0:windowLength - 1)';
if windowLength > 1
    window = 0.5 - 0.5 .* cos(2 .* pi .* sampleIndex ./ ...
        (windowLength - 1));
else
    window = 1;
end
windowPower = sum(window .^ 2);
nFFT = 2 ^ nextpow2(windowLength);
nPositive = floor(nFFT / 2) + 1;
accumulatedPSD = zeros(nPositive, nSignals);

for startIndex = segmentStarts
    segment = signals(startIndex:(startIndex + windowLength - 1), :);
    segment = detrend(segment, 'linear');
    transformed = fft(segment .* window, nFFT, 1);
    segmentPSD = abs(transformed(1:nPositive, :)) .^ 2 ./ ...
        (sampleRate * windowPower);
    if nFFT > 2
        segmentPSD(2:end-1, :) = 2 .* segmentPSD(2:end-1, :);
    end
    accumulatedPSD = accumulatedPSD + segmentPSD;
end

oneSidedPSD = accumulatedPSD ./ numel(segmentStarts);
frequencies = (0:nPositive - 1)' .* (sampleRate / nFFT);
segmentCount = numel(segmentStarts);
end

function quantiles = rowQuantiles(values, requestedPercentiles)
% Linear-interpolated quantiles for each row, without Statistics Toolbox.
sortedValues = sort(values, 2);
nValues = size(sortedValues, 2);
nRows = size(sortedValues, 1);
quantiles = zeros(nRows, numel(requestedPercentiles));
for q = 1:numel(requestedPercentiles)
    position = 1 + (requestedPercentiles(q) / 100) * (nValues - 1);
    lowerIndex = floor(position);
    upperIndex = ceil(position);
    weight = position - lowerIndex;
    rowIndices = (1:nRows)';
    lowerValues = sortedValues(sub2ind([nRows, nValues], ...
        rowIndices, repmat(lowerIndex, nRows, 1)));
    upperValues = sortedValues(sub2ind([nRows, nValues], ...
        rowIndices, repmat(upperIndex, nRows, 1)));
    quantiles(:, q) = (1 - weight) .* lowerValues + weight .* upperValues;
end
end

function index = percentileIndex(percentile, nValues)
index = max(1, min(nValues, round((double(percentile) / 100) * nValues)));
end
