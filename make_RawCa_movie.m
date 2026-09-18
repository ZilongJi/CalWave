function outputFile = make_RawCa_movie(matFile, varargin)
%MAKE_RAWCA_MOVIE Export a RawCa stack from a MAT file as an MP4 movie.
%
%   outputFile = make_RawCa_movie(matFile)
%   outputFile = make_RawCa_movie(matFile, Name, Value, ...)
%
% MATFILE is either a full/relative path or a file name. If only a file
% name is supplied, this function searches the current folder, the
% project's Data/alldata folder, and the project's Data folder.
%
% The input MAT file must contain a 3-D image stack and a frame rate. By
% default these variables are named RawCa and FrameRate. Both names can be
% changed with the RawCaVariable and FrameRateVariable options.
%
% The stack is read with MATFILE in chunks. This keeps memory use bounded
% by ChunkSize frames instead of loading the complete recording into RAM.
%
% Examples
%   % Search for this file in the project's Data/alldata folder:
%   make_RawCa_movie('12-11-17 Animal 1 Run 4 P8.mat');
%
%   % Use an explicit path and output location:
%   make_RawCa_movie('D:\data\recording.mat', ...
%       'OutputFile', 'D:\movies\recording_rawca.mp4');
%
%   % Use different variable names in another MAT-file:
%   make_RawCa_movie('recording.mat', ...
%       'RawCaVariable', 'images', 'FrameRateVariable', 'fps');

parser = inputParser;
parser.FunctionName = mfilename;
addRequired(parser, 'matFile', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'OutputFile', '', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'OutputDir', '', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'RawCaVariable', 'RawCa', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'FrameRateVariable', 'FrameRate', @(x) ischar(x) || (isstring(x) && isscalar(x)));
addParameter(parser, 'FrameRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
addParameter(parser, 'LowPercentile', 1, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 0 && x < 100);
addParameter(parser, 'HighPercentile', 99.5, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x > 0 && x <= 100);
addParameter(parser, 'MaxSampleFrames', 200, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'SpatialSampleStep', 4, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'ChunkSize', 100, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'Quality', 90, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 0 && x <= 100);
addParameter(parser, 'ProgressEvery', 500, @(x) isnumeric(x) && isscalar(x) && isfinite(x) && x >= 1);
addParameter(parser, 'Overwrite', false, @(x) islogical(x) && isscalar(x));
parse(parser, matFile, varargin{:});
options = parser.Results;

matFile = char(options.matFile);
rawCaVariable = char(options.RawCaVariable);
frameRateVariable = char(options.FrameRateVariable);

inputFile = resolveInputFile(matFile);
variableInfo = whos('-file', inputFile);
variableNames = {variableInfo.name};

if ~ismember(rawCaVariable, variableNames)
    error('make_RawCa_movie:MissingRawCa', ...
        'The MAT file does not contain the RawCa variable "%s": %s', ...
        rawCaVariable, inputFile);
end

rawInfo = variableInfo(strcmp({variableInfo.name}, rawCaVariable));
rawSize = rawInfo.size;
if numel(rawSize) ~= 3
    error('make_RawCa_movie:InvalidRawCa', ...
        'Variable "%s" must be a height-by-width-by-time array. Found size %s.', ...
        rawCaVariable, mat2str(rawSize));
end

nRows = rawSize(1);
nColumns = rawSize(2);
nFrames = rawSize(3);
if any(~isfinite([nRows, nColumns, nFrames])) || any([nRows, nColumns, nFrames] < 1)
    error('make_RawCa_movie:InvalidRawCa', 'The RawCa dimensions must be positive.');
end

if isempty(options.FrameRate)
    if ~ismember(frameRateVariable, variableNames)
        error('make_RawCa_movie:MissingFrameRate', ...
            ['The MAT file does not contain the frame-rate variable "%s". ' ...
             'Provide a value with ''FrameRate'', or change ''FrameRateVariable''.'], ...
            frameRateVariable);
    end
    frameRateData = load(inputFile, frameRateVariable);
    frameRate = frameRateData.(frameRateVariable);
else
    frameRate = options.FrameRate;
end
frameRate = double(frameRate);
if ~isscalar(frameRate) || ~isfinite(frameRate) || frameRate <= 0
    error('make_RawCa_movie:InvalidFrameRate', ...
        'FrameRate must be a positive, finite scalar.');
end

outputFile = resolveOutputFile(inputFile, options);
outputFolder = fileparts(outputFile);
if ~isempty(outputFolder) && ~isfolder(outputFolder)
    mkdir(outputFolder);
end
if isfile(outputFile) && ~options.Overwrite
    error('make_RawCa_movie:OutputExists', ...
        'Output file already exists: %s\nSet ''Overwrite'', true to replace it.', ...
        outputFile);
end

fprintf('Input: %s\n', inputFile);
fprintf('RawCa size: %d x %d x %d frames\n', nRows, nColumns, nFrames);
fprintf('Frame rate: %.6g Hz (duration %.2f seconds)\n', ...
    frameRate, nFrames / frameRate);

% A MATFILE handle permits partial reads from v7.3 MAT files. The first
% read below also gives a clear error for files that cannot be sliced.
dataFile = matfile(inputFile);
try
    firstFrame = readRawCa(dataFile, rawCaVariable, 1, 1:nRows, 1:nColumns);
catch exception
    error('make_RawCa_movie:ReadFailed', ...
        ['Could not read a partial RawCa frame from this MAT file. ' ...
         'Large inputs should be saved with MATLAB -v7.3. Original error: %s'], ...
        exception.message);
end
if ~isnumeric(firstFrame) && ~islogical(firstFrame)
    error('make_RawCa_movie:InvalidRawCaType', ...
        'Variable "%s" must contain numeric or logical image data.', rawCaVariable);
end

% Estimate fixed display limits from spatially subsampled frames distributed
% through the recording. Fixed limits prevent frame-to-frame flicker.
nSampleFrames = min(round(options.MaxSampleFrames), nFrames);
sampleFrames = unique(round(linspace(1, nFrames, nSampleFrames)));
rowStep = round(options.SpatialSampleStep);
columnStep = rowStep;
sampleRows = 1:rowStep:nRows;
sampleColumns = 1:columnStep:nColumns;
nPixelsPerSample = numel(sampleRows) * numel(sampleColumns);
sampleValues = zeros(nPixelsPerSample * numel(sampleFrames), 1, 'single');

fprintf('Estimating display limits from %d sampled frames...\n', ...
    numel(sampleFrames));
nextIndex = 1;
for k = 1:numel(sampleFrames)
    sampleImage = single(readRawCa(dataFile, rawCaVariable, sampleFrames(k), ...
        sampleRows, sampleColumns));
    indices = nextIndex:(nextIndex + numel(sampleImage) - 1);
    sampleValues(indices) = sampleImage(:);
    nextIndex = nextIndex + numel(sampleImage);
end

sampleValues = sort(sampleValues(isfinite(sampleValues)));
if isempty(sampleValues)
    error('make_RawCa_movie:NoFiniteData', ...
        'RawCa contains no finite values in the sampled frames.');
end

lowIndex = percentileIndex(options.LowPercentile, numel(sampleValues));
highIndex = percentileIndex(options.HighPercentile, numel(sampleValues));
displayLow = double(sampleValues(lowIndex));
displayHigh = double(sampleValues(highIndex));

if displayHigh <= displayLow
    displayLow = double(sampleValues(1));
    displayHigh = double(sampleValues(end));
end
if displayHigh <= displayLow
    error('make_RawCa_movie:ConstantData', ...
        'Cannot create contrast limits because sampled RawCa is constant.');
end
fprintf('Display range: %.6g to %.6g\n', displayLow, displayHigh);

writer = VideoWriter(outputFile, 'MPEG-4');
writer.FrameRate = frameRate;
writer.Quality = options.Quality;
open(writer);

try
    chunkSize = round(options.ChunkSize);
    progressEvery = round(options.ProgressEvery);
    for firstFrameNumber = 1:chunkSize:nFrames
        lastFrameNumber = min(nFrames, firstFrameNumber + chunkSize - 1);
        frameNumbers = firstFrameNumber:lastFrameNumber;
        rawChunk = single(readRawCa(dataFile, rawCaVariable, frameNumbers, ...
            1:nRows, 1:nColumns));

        for chunkFrame = 1:numel(frameNumbers)
            imageData = rawChunk(:, :, chunkFrame);
            imageData = (imageData - displayLow) ./ (displayHigh - displayLow);
            imageData = min(max(imageData, 0), 1);
            imageData(~isfinite(imageData)) = 0;

            grayFrame = uint8(255 .* imageData);
            rgbFrame = repmat(grayFrame, 1, 1, 3);
            writeVideo(writer, rgbFrame);
        end

        if mod(lastFrameNumber, progressEvery) < chunkSize || lastFrameNumber == nFrames
            fprintf('Written %d/%d frames (%.1f%%)\n', lastFrameNumber, ...
                nFrames, 100 * lastFrameNumber / nFrames);
        end
    end
    close(writer);
catch exception
    close(writer);
    rethrow(exception);
end

fprintf('Movie saved to:\n%s\n', outputFile);
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

error('make_RawCa_movie:InputNotFound', ...
    'Could not find MAT file "%s" in the current folder, Data/alldata, or Data.', matFile);
end

function outputFile = resolveOutputFile(inputFile, options)
if ~isempty(options.OutputFile)
    outputFile = char(options.OutputFile);
    return;
end

if isempty(options.OutputDir)
    calWaveDir = fileparts(mfilename('fullpath'));
    projectDir = fileparts(calWaveDir);
    outputDir = fullfile(projectDir, 'Results', 'RawCa_movies');
else
    outputDir = char(options.OutputDir);
end

[~, inputStem] = fileparts(inputFile);
outputFile = fullfile(outputDir, [inputStem '_RawCa_movie.mp4']);
end

function frame = readRawCa(dataFile, variableName, frameIndices, rowIndices, columnIndices)
% Dynamic partial indexing keeps variable names configurable without eval.
subscript = substruct('.', variableName, '()', ...
    {rowIndices, columnIndices, frameIndices});
frame = subsref(dataFile, subscript);
end

function index = percentileIndex(percentile, nValues)
index = max(1, min(nValues, round((double(percentile) / 100) * nValues)));
end
