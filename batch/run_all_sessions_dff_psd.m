%% Run DeltaF/F, movie, and PSD analysis for all sessions
% This script processes every MAT file in Data/alldata.
% Complete sessions are skipped automatically. Incomplete sessions or
% sessions with missing output files are recalculated.

clear;
clc;

%% Project and input folders
batchDir = fileparts(mfilename('fullpath'));
calWaveDir = fileparts(batchDir);
projectDir = fileparts(calWaveDir);
inputDir = fullfile(projectDir, 'Data', 'alldata');
outputDir = fullfile(projectDir, 'Results', 'CalWave');

addpath(calWaveDir);

if ~isfolder(inputDir)
    error('Input folder not found: %s', inputDir);
end
if ~isfolder(outputDir)
    mkdir(outputDir);
end

% Set this to true if you want to recalculate every session.
overwriteAll = false;

matFiles = dir(fullfile(inputDir, '*.mat'));
if isempty(matFiles)
    error('No MAT files found in: %s', inputDir);
end

fprintf('Found %d MAT files in:\n%s\n', numel(matFiles), inputDir);

completedCount = 0;
skippedCount = 0;
failedCount = 0;

for sessionNumber = 1:numel(matFiles)
    inputFile = fullfile(matFiles(sessionNumber).folder, ...
        matFiles(sessionNumber).name);
    [~, inputStem] = fileparts(inputFile);

    fprintf('\n========================================\n');
    fprintf('Session %d/%d:\n%s\n', ...
        sessionNumber, numel(matFiles), matFiles(sessionNumber).name);
    fprintf('========================================\n');

    expectedFiles = {
        fullfile(outputDir, [inputStem '_dff.mat'])
        fullfile(outputDir, [inputStem '_dff_movie.mp4'])
        fullfile(outputDir, [inputStem '_dff_PSD.mat'])
        fullfile(outputDir, [inputStem '_dff_PSD_1x2.png'])
        fullfile(outputDir, [inputStem '_dff_PSD_1x2_log.png'])
        };

    isComplete = all(cellfun(@isfile, expectedFiles));
    if isComplete && ~overwriteAll
        try
            dffData = matfile(expectedFiles{1});
            dffVariables = whos(dffData);
            dffNames = {dffVariables.name};
            isComplete = ismember('processingComplete', dffNames) && ...
                logical(dffData.processingComplete) && ...
                ismember('movieDurationSeconds', dffNames) && ...
                abs(double(dffData.movieDurationSeconds) - 600) < eps(600);
            if isComplete
                psdData = matfile(expectedFiles{3});
                psdVariables = whos(psdData);
                psdNames = {psdVariables.name};
                isComplete = ismember('processingComplete', psdNames) && ...
                    logical(psdData.processingComplete) && ...
                    ismember('analysisChunkSeconds', psdNames) && ...
                    ismember('spatialBinSize', psdNames) && ...
                    double(psdData.spatialBinSize) == 5;
            end
        catch
            isComplete = false;
        end
    end

    if isComplete && ~overwriteAll
        fprintf('Skipping: all output files already exist.\n');
        skippedCount = skippedCount + 1;
        continue;
    end

    overwriteThisSession = overwriteAll || ...
        any(cellfun(@isfile, expectedFiles));

    try
        results = make_dff_movie_and_psd(inputFile, ...
            'OutputDir', outputDir, ...
            'AnalysisChunkSeconds', 900, ...
            'Overwrite', overwriteThisSession);

        fprintf('Completed session:\n%s\n', results.dffFile);
        completedCount = completedCount + 1;
    catch exception
        warning('Failed to process %s:\n%s', ...
            matFiles(sessionNumber).name, exception.message);
        failedCount = failedCount + 1;
    end
end

fprintf('\n========================================\n');
fprintf('Batch processing finished.\n');
fprintf('Completed: %d\n', completedCount);
fprintf('Skipped:   %d\n', skippedCount);
fprintf('Failed:    %d\n', failedCount);
fprintf('Output folder:\n%s\n', outputDir);
