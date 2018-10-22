function [myBRTableRECIST, myRTableRECIST] = createResponseTablesRECIST(myWorksheet,myExpDataIDs,PatientIDVar,TRTVar,BRSCOREVar,RSCOREVar,timeVar,startTime,myInterventionIDs, prefixStopPairs)
% This function takes experimental data embedded in a worksheet and
% converts it to a bin table with BRSCORE data, so even
% when patients drop off therapy their best scores are
% recorded to guide VPop calibration.
%
% ARGUMENTS:
%  myWorksheet:       a workshet with the experimental data
%  myExpDataIDs:      a cell array, 1 x n time points and variables
%                      with the experimental data IDs
%  PatientIDVar:      variable with the patient IDs
%  TRTVar:            a binary variable indicating whether a patient is on
%                     treatment
%  BRSCOREVar:        variable with best overall response to date.
%  RSCOREVar:         variable with current response.
%  timeVar:           variable with time information
%  startTime:         time in the data when treatment starts
%  myInterventionIDs: a cell array, 1 x n time points and variables
%  prefixStopPairs:   a cell array of cell arrays, i.e.:
%                     {{prefix1, time1},{prefix2, time2} ...}
%                     containing VP prefix and trial stop time.
%                     This is included to correct for trials that
%                      end early.  With USUBJID conventions, the prefix
%                      generally matches a trial, i.e. CAXXXYYYY.
%  
% RETURNS
%  myBRTableRECIST
%  myRTableRECIST
%

continueFlag = false;
if nargin > 10
    warning(['Too many input arguments to ',mfilename, '. Arguments should be: myWorksheet,myExpDataIDs,PatientIDVar,TRTVar,BRSCOREVar,RSCOREVar,timeVar,startTime,myInterventionIDs, optionally prefixStopPairs.'])
    continueFlag = false;
elseif nargin > 9
    continueFlag = true;
elseif nargin > 8
    prefixStopPairs = cell(1,0);
    continueFlag = true; 
else
    warning(['Too few input arguments to ',mfilename, '. Arguments should be: myWorksheet,myExpDataIDs,PatientIDVar,TRTVar,BRSCOREVar,RSCOREVar,timeVar,startTime,myInterventionIDs, optionally prefixStopPairs.'])
    continueFlag = false;
end

% TODO: Could add more proofing to createResponseTablesRECIST
nStopTrials = length(prefixStopPairs);
prefixes = cell(1,nStopTrials);
stopTimes = nan(1,nStopTrials);
if nStopTrials > 0
    for prefixCounter = 1 : nStopTrials
        prefixes{prefixCounter} = prefixStopPairs{prefixCounter}{1};
        stopTimes(prefixCounter) = prefixStopPairs{prefixCounter}{2};
    end
end

tableVariableNamesFixed = {'time', 'expVarID', 'interventionID','elementID','elementType', 'expDataID', 'expTimeVarID','PatientIDVar','TRTVar','BRSCOREVar','RSCOREVar'};
tableVariableNames = [tableVariableNamesFixed,{'weight','expN','expCR','expPR','expSD','expPD','predN','predCR','predPR','predSD','predPD'}];
myBRTableRECIST = cell2table(cell(0,length(tableVariableNames)));
myBRTableRECIST.Properties.VariableNames = tableVariableNames;
myRTableRECIST = cell2table(cell(0,length(tableVariableNames)));
myRTableRECIST.Properties.VariableNames = tableVariableNames;

if continueFlag


    
    allExpDataIDs = getExpDataIDs(myWorksheet);

    for varCounter = 1 : length(myExpDataIDs)
        
        myExpDataID = myExpDataIDs{varCounter};
        interventionID = myInterventionIDs{varCounter};            
        
        curIndex = find(ismember(allExpDataIDs,myExpDataID));
        curData = myWorksheet.expData{curIndex}.data;
        % First remove off treatment rows
        curData = curData(find(curData{:,TRTVar}==1),:);
        % Need to make all table vars into string for this to work
        new_variable = arrayfun(@(value) cast(value{1}, 'char'), curData.(BRSCOREVar), 'uniform', 0);
        curData.(BRSCOREVar) = new_variable;
        new_variable = arrayfun(@(value) cast(value{1}, 'char'), curData.(RSCOREVar), 'uniform', 0);
        curData.(RSCOREVar) = new_variable;  
        % We are just looking for BR, so this filter makes sense
        curData = curData(find(ismember(curData{:,BRSCOREVar},{'PD','SD','PR','CR'})),:);
        % Now also filter once a patient hits CR, PD
        curPatientIDs = unique(curData{:,PatientIDVar},'stable');
        nPatients = length(curPatientIDs);
        allRows = nan(0,1);
        for patientCounter = 1 : nPatients
            curRows = find(ismember(curData{:,PatientIDVar},curPatientIDs(patientCounter)));
            %lastRows = find(ismember(curData{curRows,BRSCOREVar},{'PD','CR'}) | ismember(curData{curRows,RSCOREVar},{'PD','CR'}));
            % First filter out PD2 and subsequent time points
			% We will exclude all data with PD2 for now
			lastRows = find(ismember(curData{curRows,BRSCOREVar},{'PD2'}) | ismember(curData{curRows,RSCOREVar},{'PD2'}));
			if ~isempty(lastRows)
				lastRows = lastRows(1)-1;
                if lastRows > 0
                    curRows = curRows(1:lastRows);
                else
                    curRows = [];
                end
            end
            if length(curRows) > 0  
                lastRows = find(ismember(curData{curRows,RSCOREVar},{'PD','CR'}));
                if (length(lastRows) > 1)
                    curRows = curRows(1:lastRows(1));
                end
                allRows = [allRows; curRows];
            end
        end
        selectData = curData(allRows,:);
        new_variable = arrayfun(@(value) cast(value{1}, 'char'), selectData.(BRSCOREVar), 'uniform', 0);
        selectData.(BRSCOREVar) = new_variable;  
        new_variable = arrayfun(@(value) cast(value{1}, 'char'), selectData.(RSCOREVar), 'uniform', 0);
        selectData.(RSCOREVar) = new_variable;          

        % We want a full matrix with nTimePoint x nVP with the BRSCORE.
        allTimes = unique(selectData{:,timeVar});
        allTimes = sort(allTimes,'ascend');
        % This may be redundant.  That is, we don't expect a response
        % unless we are beyond startTime anyway.
        allTimes = allTimes(find(allTimes>startTime));
        fullCell = cell(length(allTimes),nPatients);
        for patientCounter = 1 :nPatients
            patientID = curPatientIDs{patientCounter};
            curRows = find(ismember(selectData{:,PatientIDVar},patientID));
            curData = selectData(curRows,:);
            lastBRSCORE = '.';
            for timeCounter = 1 : length(allTimes)
                curTime = allTimes(timeCounter);
                if sum(ismember(curData{:,timeVar},curTime)) > 0
                    curRow = find((ismember(curData{:,timeVar},curTime)));
                    lastBRSCORE = curData{curRow,BRSCOREVar};
                    lastBRSCORE = lastBRSCORE{1};
                end
                % We need to add a check in case the trial has stopped
                passCheck = true;
                if length(prefixes) > 0
                    for prefixCounter = 1:length(prefixes)
                        if startsWith(patientID,prefixes{prefixCounter},'IgnoreCase',true) && (curTime > stopTimes(prefixCounter))
                            passCheck = false;
                        end
                    end
                end
                if ~passCheck
                    lastBRSCORE = '.';
                end
                fullCell{timeCounter,patientCounter} = lastBRSCORE;
            end
        end
        % Now we want to count...
        for timeCounter = 1 : length(allTimes);
            curData = fullCell(timeCounter,:);
            nCR = sum(ismember(curData,'CR'));
            nPR = sum(ismember(curData,'PR'));
            nSD = sum(ismember(curData,'SD'));
            nPD = sum(ismember(curData,'PD'));
            expN = nCR+nPR+nSD+nPD;
            curProbs = [nCR, nPR, nSD, nPD] / expN;
            curRow = {allTimes(timeCounter), 'BRSCORE', interventionID, 'BRSCORE','derived',myExpDataID, timeVar,PatientIDVar,TRTVar,BRSCOREVar,RSCOREVar};
            curRow = [curRow,{1, expN, curProbs(1), curProbs(2), curProbs(3), curProbs(4), nan, nan, nan, nan, nan}];
            curRow = cell2table(curRow);
            curRow.Properties.VariableNames = myBRTableRECIST.Properties.VariableNames; 
            myBRTableRECIST = [myBRTableRECIST; curRow];    
        end
        
        % Repeat for the RSCORE
        % We want a full matrix with nTimePoint x nVP with the RSCORE.
        % We want to keep the last value once a patient hits PD or CR
        % but also allow missing values if a patients stops therapy before
        % PD or CR.
        % If we do not have data at a time point but the patient has
        % not hit PD/CR yet, we impute from the last observation
        allTimes = unique(selectData{:,timeVar});
        allTimes = sort(allTimes,'ascend');
        % This may be redundant.  That is, we don't expect a response
        % unless we are beyond startTime anyway.
        allTimes = allTimes(find(allTimes>startTime));
        fullCell = cell(length(allTimes),nPatients);
        for patientCounter = 1 :nPatients
            patientID = curPatientIDs{patientCounter};
            curRows = find(ismember(selectData{:,PatientIDVar},patientID));
            curData = selectData(curRows,:);
            lastRSCORE = '';
            % Last time we have for the current VP
            lastTime = max(curData{:,timeVar});
            for timeCounter = 1 : length(allTimes)
                curTime = allTimes(timeCounter);
                % Update the last RSCORE if we have
                % a measure for the current time for the current VP
                if sum(ismember(curData{:,timeVar},curTime)) > 0
                    curRow = find((ismember(curData{:,timeVar},curTime)));
                    lastRSCORE = curData{curRow,RSCOREVar};
                    lastRSCORE = lastRSCORE{1};
                end
                if curTime <= lastTime
                    fullCell{timeCounter,patientCounter} = lastRSCORE;
                else
                    % Check to see if the last event should be carried
                    % forward.
                    if ismember(lastRSCORE,{'CR','PD'})
                        % In this case we carry CR, PD forward unless
                        % we've specified the trial has ended via the prefix.
                        passCheck = true;
                        if length(prefixes) > 0
                            for prefixCounter = 1:length(prefixes)
                                if startsWith(patientID,prefixes{prefixCounter},'IgnoreCase',true) && (curTime > stopTimes(prefixCounter))
                                    passCheck = false;
                                end
                            end
                        end
                        if passCheck
                            fullCell{timeCounter,patientCounter} = lastRSCORE;
                        else
                            fullCell{timeCounter,patientCounter} = '.';
                        end
                    else
                        % In the case there was a dropout without hitting
                        % CR/PD treat subsequent values as missing
                        fullCell{timeCounter,patientCounter} = '.';
                    end
                end
            end
        end
        % Now we want to count...
        for timeCounter = 1 : length(allTimes);
            curData = fullCell(timeCounter,:);
            nCR = sum(ismember(curData,'CR'));
            nPR = sum(ismember(curData,'PR'));
            nSD = sum(ismember(curData,'SD'));
            nPD = sum(ismember(curData,'PD'));
            expN = nCR+nPR+nSD+nPD;
            curProbs = [nCR, nPR, nSD, nPD] / expN;
            curRow = {allTimes(timeCounter), 'RSCORE', interventionID, 'RSCORE','derived',myExpDataID, timeVar,PatientIDVar,TRTVar,BRSCOREVar,RSCOREVar};
            curRow = [curRow,{1, expN, curProbs(1), curProbs(2), curProbs(3), curProbs(4), nan, nan, nan, nan, nan}];
            curRow = cell2table(curRow);
            curRow.Properties.VariableNames = myRTableRECIST.Properties.VariableNames; 
            myRTableRECIST = [myRTableRECIST; curRow];    
        end        
        
    end
        
end
end