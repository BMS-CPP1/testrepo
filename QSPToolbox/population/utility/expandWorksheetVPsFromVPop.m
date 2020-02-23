function [myWorksheet, newPassNames] = expandWorksheetVPsFromVPop(myWorksheet,newVPop, myMapelOptions,suffix,wsIterCounter, maxNewPerIter, myScreenTable, expandCohortSize, varyMethod, gaussianStd, maxNewPerOld, unweightedParents, selectByParent, myScreenFunctionName)
% This function expands a worksheet given a VPop.  It selected out VPs to expand around,
% samples for new VPs, scores the "children" based on available data, and adds
% the best children to the worksheet.
%
%  myWorksheet
%  newVPop
%  myMapelOptions
%  suffix:             a text descriptor string that will be included in what 
%                       will be written to file.  This is also used
%                       in setting VP identities.
%  wsIterCounter:      tracks the iterations through the algorithm.  Keep
%                       incrementing to avoid issues with repeated VPIDs.
%  maxNewPerIter:      maximum new VPs we can add per iteration.  Set to 
%                       -1 to use the VPop effN
%  myScreenTable:      a screen table to idenify VPs to keep
%  expandCohortSize:   size of the cohort to generate for testing
%  varyMethod:         method for resampling.  i.e. 'gaussian' or 'localPCA'
%  gaussianStd:        standard deviation for the re-sampled parameters.
%                       note this is applied across all axes in the transformed
%                       units (i.e. within bounds normalized 0-1).
%  maxNewPerOld:       maximum number of children per weighted parent
%  unweightedParents:  Whether to include unweighted VPs as seeds for 
%                       expansion if they look like they are useful.
%  selectByParent:     a boolean variable indicating whether children
%                       VPs are selected for inclusion each iteraction 
%                       based on their parent, or just pooled together
%  myScreenFunctionName: a string indicating a function to use for screening
%                         VPs before simulation.  It should take two input
%                         arguments: a worksheet and a list of VPIDs to
%                         screen.  It should return a worksheet with
%                         identical number of names of VPs, possibly 
%                         modified after bing checked against some
%                         criteria. '' indicates no screening.
%                      
%                      
% RETURNS:
%  myWorksheet
%  newPassNames
%
% TODO: this function could use more input proofing or an options object.  This
%       is also mainly intended to be called from other functions, so it hasn't
%       been done yet.

originalVPIDs = getVPIDs(myWorksheet); 
if length(originalVPIDs) > length(newVPop.pws)
    warning(['More VPs in worksheet than PWs in VPop in ',mfilename,'.  Proceeding assuming the PWs correspond to the first VPs in the worksheet.'])
    continueFlag = true;
elseif length(originalVPIDs) < length(newVPop.pws)
    warning(['Fewer VPs in worksheet than PWs in VPop in ',mfilename,'.  Exiting...'])
    continueFlag = false; 
else
    continueFlag = true;
end

    
if continueFlag    
    
    myCoeffs = getVPCoeffs(myWorksheet);
    [nAxis, nOriginalVPs] = size(myCoeffs);	
    
    myVPRangeTable = createVPRangeTable(newVPop);
    % Consider an entry if it is off of one of the edges by more than 10%
    myCutoff = 0.1;

    disp('---------')
    disp(['Check of VP filling ranges in ',mfilename,'.'])
    myIndicesLow = find(myVPRangeTable{:,'minMissing'}>myCutoff);
    myIndicesHigh = find(myVPRangeTable{:,'maxMissing'}>myCutoff);
    myIndices = unique(sort([myIndicesLow;myIndicesHigh],'ascend'),'stable');
    % Print portions of the table to screen so we can track progress.
    myVPRangeTable(myIndices,{'elementID','interventionID','time','expN','rangeCover','minMissing','maxMissing'})

    % We will pre-rank parent VPs we might want to add
    % to resampling based on the observed data    
    % This step will only be impactful if
    % unweightedParents is not false
    if unweightedParents
        myVPRangeTable = myVPRangeTable(myIndices,:);
        [nRows,nCols] = size(myVPRangeTable);
        myIndicesLow = find(myVPRangeTable{:,'minMissing'}>myCutoff);
        myIndicesHigh = find(myVPRangeTable{:,'maxMissing'}>myCutoff);     
        myValuesLow = myVPRangeTable{myIndicesLow,'minMissing'};
        myValuesHigh = myVPRangeTable{myIndicesHigh,'maxMissing'};
        nLowValues = length(myValuesLow);
        nHighValues = length(myValuesHigh);
        lowTracker = 1*ones(nLowValues,1);
        highTracker = 2*ones(nHighValues,1);         
        myValuesCombine = [myValuesLow;myValuesHigh];
        myIndicesCombine = [myIndicesLow;myIndicesHigh];
        [myValuesCombineSort, myValuesCombineIndices] = sort(myValuesCombine,'descend');
        combineTracker = [lowTracker;highTracker];
        combineTracker = combineTracker(myValuesCombineIndices);
        myIndicesCombine = myIndicesCombine(myValuesCombineIndices);
        % We will manually sort through the VPs
        parentVPs = cell(1,nLowValues + nHighValues);
        for parentCounter = 1 : (nLowValues + nHighValues)
            if combineTracker(parentCounter) > 1.5
                myIndex = myIndicesCombine(parentCounter);
                parentVPs(parentCounter) = myVPRangeTable{myIndex,'vpIDsMax'};
            else
                myIndex = myIndicesCombine(parentCounter);
                parentVPs(parentCounter) = myVPRangeTable{myIndex,'vpIDsMin'};
            end
        end
 
        parentVPs(isempty(parentVPs)) = [];
        nParentCandidates = length(parentVPs);
        parentVPsPass = cell(1,length(parentVPs));
        parentsPassCounter = 1;
        for checkCounter =1 :  nParentCandidates
            curCheckParents = parentVPs{checkCounter};
            % We need to compare to other parents in the list to 
            % 1. pick the best parent that might cover multiple edges and
            % 2. minimize double counting for edges
            [~, curCheckSize] = size(curCheckParents);
            
            if checkCounter < nParentCandidates
                curCheckscore = zeros(nParentCandidates-(checkCounter),curCheckSize);
                % First check the current set of parents against the ones
                % further down the list in case one of the parents
                % in the current set appears there.
                for otherParentCounter = (checkCounter + 1) : nParentCandidates
                    testParents = parentVPs{otherParentCounter};
                    curCheckscore(otherParentCounter - checkCounter,:) = ismember(curCheckParents,testParents);
                end
                otherParentIndices = (checkCounter + 1) : nParentCandidates;
                % After we have the comparison for the current parents,
                % we pick the one with highest score as compared to
                % other rows
                sumParentScores = sum(curCheckscore,1);
                bestIndex = find(sumParentScores == max(sumParentScores));
                if length(bestIndex) > 1
                    % In case of a tie
                    bestIndex = bestIndex(1);
                end
                % Now we note the other VP sets that contained the best
                % parent
                curCheckscore = curCheckscore(:,bestIndex);
                % These are the rows where we found a match and can 
                % substitute in the current best parent
                substituteOtherParentIndex = otherParentIndices(find(curCheckscore));
                if length(substituteOtherParentIndex) > 0
                    parentVPs(substituteOtherParentIndex) = {{curCheckParents{bestIndex}}};
                end
                parentVPsPass{checkCounter} = curCheckParents{bestIndex};
                
            else
                % For the last entry, we do no comparison
                parentVPsPass{checkCounter} = curCheckParents{1};
            end
            
        end
        edgeVPIDs = unique(parentVPsPass,'stable');
    else
        edgeVPIDs = {};
    end
    % Get the indices for the edgeVPs in the original VPIDs.  Order
    % should be preserved.
    edgeVPIndices = nan(1, length(edgeVPIDs));
    for vpCounter = 1 : length(edgeVPIDs)
        edgeVPIndices(vpCounter) = find(ismember(originalVPIDs,edgeVPIDs{vpCounter}));
    end  
    
    
    % Consider VPs for inclusion as seed if they are weighted "heavily"
    pwExpandCutoff = 0.01;
    allResponseTypeIDs = getResponseTypeIDs(myWorksheet);
    nResponseTypes = length(allResponseTypeIDs);
    myPWs = newVPop.pws;
    curEffN = round(1/sum(myPWs.^2));
    highVPIndices1 = find(myPWs>=pwExpandCutoff);
    [~, highVPIndices2] = sort(myPWs, 'descend');
    highVPIndices2 = highVPIndices2(1 : curEffN);
    highVPindicesCat = [highVPIndices2,highVPIndices1];
    [highVPIndices,i,j] = unique(highVPindicesCat, 'first'); 
    highVPIndices = highVPindicesCat(sort(i));
    highVPIDs = originalVPIDs(highVPIndices);
    [edgeVPIDs,sortIndicesPick] = setdiff(edgeVPIDs,highVPIDs,'stable');
    edgeVPIndices = edgeVPIndices(sortIndicesPick);
    % Now combine considerations for heavily weighted VPs and
    % parents that look like they are useful.
    disp(['Considering ',num2str(length(highVPIDs)),' VPs as expansion seeds from prevalence weight considerations in ',mfilename,'.'])
    disp(['Adding ',num2str(length(edgeVPIDs)),' VPs as expansion seeds from phenotype range considerations in ',mfilename,'.'])
    highVPIDsMono = highVPIDs;
    highVPindicesMono = highVPIndices;
    nHighVPs = length(highVPIDsMono);
    nEdgeVPs = length(edgeVPIDs);
    highVPIDs = cell(1,nHighVPs + nEdgeVPs);
    highVPIndices = nan(1,nHighVPs + nEdgeVPs);
    nHighAdded=1;
    nEdgeAdded = 0;
    highVPIDs{1} = highVPIDsMono{1};
    highVPIndices(1) = highVPindicesMono(1);
    % Need an intelligent way of interlacing
    % the concerns of range coverage and
    % spreading out PWs.
    for addCounter = 2: length(highVPIDs)
        if ((nEdgeAdded < nHighAdded) && (nEdgeAdded < nEdgeVPs)) || (nHighAdded >= nHighVPs)
            nEdgeAdded = nEdgeAdded + 1;
            highVPIDs{addCounter} = edgeVPIDs{nEdgeAdded};
            highVPIndices(addCounter) = edgeVPIndices(nEdgeAdded);    
        else
            nHighAdded = nHighAdded + 1;
            highVPIDs{addCounter} = highVPIDsMono{nHighAdded};
            highVPIndices(addCounter) = highVPindicesMono(nHighAdded); 
        end
    end

    % Decide how many of the VPs from the seed expansion we can add.
    if maxNewPerIter < 0
        maxNewPerIterChecked = curEffN;
    else
        maxNewPerIterChecked = maxNewPerIter;
    end
	
    % We'll allow more than maxNewPerOld if it looks like we want
    % to allow many new VPs per seed.  We won't allow more
	% if we are selecting children based on parent and
	% we have many parents. If we are pooling all the children
	% together and picking the best, we will ignore this.
    maxNewPerOld = max(maxNewPerOld,ceil(maxNewPerIterChecked/length(highVPIndices)));

    myVaryAxesOptions = varyAxesOptions;
    myVaryAxesOptions.varyMethod = varyMethod;
    myVaryAxesOptions.gaussianStd = gaussianStd;
    myVaryAxesOptions.varyAxisIDs = getAxisDefIDs(myWorksheet);
    myVaryAxesOptions.intSeed = wsIterCounter;

    myVaryAxesOptions.additionalIDString = [suffix,num2str(wsIterCounter)];
    myVaryAxesOptions.baseVPIDs = highVPIDs;
    myVaryAxesOptions.newPerOld = ceil(expandCohortSize/length(highVPIDs));

    if selectByParent
        disp(['Note due to the maxNewPerIter and maxNewPerOld settings, it is possible only children from ',num2str(ceil(maxNewPerIterChecked/maxNewPerOld)),' VP parents will be selected in ',mfilename,'.'])    
    end
    disp('---')    
    
    
    jitteredWorksheet = addVariedVPs(myWorksheet, myVaryAxesOptions);
    curVPIDs = getVPIDs(jitteredWorksheet);
    newIndices = (find(~ismember(curVPIDs,originalVPIDs)));
    newVPIDs = curVPIDs(newIndices);

    % We will also randomize a coefficient
    for vpCounter = 1 : length(newVPIDs);
        curVPID = newVPIDs{vpCounter};
        % randomize one of the new VP axis coefficients
        axisIndex = randsample([1:nAxis],1);
        vpIndex = find(ismember(curVPIDs,curVPID));
        jitteredWorksheet.axisProps.axisVP.coefficients(axisIndex,vpIndex) = rand(1);
    end

    mySimulateOptions = simulateOptions;
    mySimulateOptions.rerunExisting = false;
    mySimulateOptions.optimizeType = 'none';
	% Inherit the pool properties
	mySimulateOptions.poolRestart = myMapelOptions.poolRestart;
	mySimulateOptions.poolClose = myMapelOptions.poolClose;    
    
    % Also screen the worksheet if a function is provided
    if length(myScreenFunctionName) > 0
        jitteredWorksheet = eval([myScreenFunctionName,'(jitteredWorksheet,newVPIDs,mySimulateOptions)']);
    end
    
    jitteredWorksheet = simulateWorksheet(jitteredWorksheet,mySimulateOptions);
    curVPIDs = getVPIDs(jitteredWorksheet);
    originalIndices = (find(ismember(curVPIDs,originalVPIDs)));
    newIndices = (find(~ismember(curVPIDs,originalVPIDs)));
    newVPIDs = curVPIDs(newIndices);     

    % Identify the VPs that don't fulfill the worksheet response
    % as well as those in the initial worksheet in order to filter
    % them.
    disp('---')
    disp(['Screening newly simulated VPs in ',mfilename,'.'])
    jitteredWorksheet = screenWorksheetVPs(jitteredWorksheet, myScreenTable, true, newVPIDs);
    disp('---------')
    curVPIDs = getVPIDs(jitteredWorksheet);
    originalIndices = (find(ismember(curVPIDs,originalVPIDs)));
    newIndices = (find(~ismember(curVPIDs,originalVPIDs)));
    newVPIDs = curVPIDs(newIndices); 
    
    % We create a "dummy" vpop object to help score
    % the simulated VPs and see which look
    % like they will be more useful.
    if isa(newVPop,'VPop')
        testVPop = VPop;
    elseif isa(newVPop,'VPopRECIST')
        testVPop = VPopRECIST;
    elseif isa(newVPop,'VPopRECISTnoBin')
        testVPop = VPopRECISTnoBin;
    end
    testVPop.expData = newVPop.expData;
    testVPop.mnSDTable = newVPop.mnSDTable;
    testVPop.binTable = newVPop.binTable;
    testVPop.distTable = newVPop.distTable;
    testVPop.distTable2D = newVPop.distTable2D;   
    testVPop.corTable = newVPop.corTable;
    testVPop.subpopTable = newVPop.subpopTable;    
    if isa(newVPop,'VPopRECIST') || isa(newVPop,'VPopRECISTnoBin')
        testVPop.brTableRECIST = newVPop.brTableRECIST;
        testVPop.rTableRECIST = newVPop.rTableRECIST;        
        testVPop.relSLDvar = newVPop.relSLDvar;
        testVPop.absALDVar = newVPop.absALDVar;
        testVPop.crCutoff = newVPop.crCutoff;             
        testVPop.recistSimFilter = createRECISTSimFilter(jitteredWorksheet, testVPop);
    end
    if ~isa(newVPop,'VPopRECISTnoBin')
		testVPop = testVPop.assignIndices(jitteredWorksheet, myMapelOptions);
    end
    testVPop = testVPop.getSimData(jitteredWorksheet);
	testVPop.subpopTable = updateSubpopTableVPs(testVPop.subpopTable, jitteredWorksheet);
    testVPop = testVPop.addTableSimVals();  
    % For evaluation
    % coerce pws to be the same.
    testVPop.pws = ones(1,length(curVPIDs))./length(curVPIDs);
    testVPop = testVPop.addPredTableVals();    
    
	% Now get the score matrix for the new VPs
    % We can remove the LC scoring option for now
    % if isa(newVPop,'VPopRECIST')
    %     newVPScores = scoreWorksheetVPsLC(testVPop,originalIndices,newIndices);
    % else
        newVPScores = scoreWorksheetVPs(testVPop,originalIndices,newIndices);
    % end


    newPassNames = cell(1,0);
	if selectByParent
		% Select valid VPs from each higher weighted seed VP
		for highCounter = 1 : length(highVPIDs)
			parentID=highVPIDs(highCounter);
			childrenBase = strcat(parentID, ['_',suffix,num2str(wsIterCounter)]);
			allChildrenBaseIndices = cellfun(@isempty,strfind(curVPIDs,childrenBase));
			allChildrenBaseIndices=find(~allChildrenBaseIndices);
			allChildrenBaseIndices=intersect(allChildrenBaseIndices,newIndices);
			childIDs = curVPIDs(allChildrenBaseIndices);
			childIDs = newVPIDs(find(ismember(newVPIDs,childIDs)));
			childScores = newVPScores(:,find(ismember(newVPIDs,childIDs)));
			% We will prioritize VPs that score well
			[nScoresPerVP, nCurChildren] = size(childScores);
			sortIndices = nan(nScoresPerVP, nCurChildren);
			for rowCounter = 1 : nScoresPerVP
				nonZeroIndices = find(childScores(rowCounter,:)>0);
				[curScores, curIndices] = sort(childScores(rowCounter,nonZeroIndices),'descend');
				childScores(rowCounter,:) = nan(1,nCurChildren);
				childScores(rowCounter,1:length(nonZeroIndices)) = curScores;
				sortIndices(rowCounter,1:length(nonZeroIndices)) = nonZeroIndices(curIndices);
			end
			sortIndices=reshape(sortIndices,1,[]);
			sortIndices = sortIndices(find(~isnan(sortIndices)));
			sortIndices = unique(sortIndices,'stable');        
			childIDs = childIDs(sortIndices);
			npass = length(childIDs);
			if (npass > 0)
				newPassNames = [newPassNames,childIDs(1:min(npass,maxNewPerOld))];
			end
		end
		if maxNewPerIterChecked < 1
			newPassNames = cell(1,0);
		elseif length(newPassNames) > maxNewPerIterChecked
			newPassNames = newPassNames(1 : maxNewPerIterChecked);
		elseif length(newPassNames) < maxNewPerIterChecked
			addIndices = find(~ismember(newVPIDs,newPassNames));
			if length(addIndices) > 0
				addVPIDs = newVPIDs(addIndices);
				addScores = newVPScores(addIndices);
				[addScores, addIndices] = sort(addScores, 'descend');
				nToAdd = min(maxNewPerIterChecked-length(newPassNames),length(addScores));
				addVPIDs = addVPIDs(addIndices(1:nToAdd));
				newPassNames = [newPassNames, addVPIDs];
			end
		end		
	else
		% Otherwise, we pool the children from
		% all of our test VPs and just take the best
		[nScoresPerVP, nCurChildren] = size(newVPScores);
		childScores = newVPScores;
		sortIndices = nan(nScoresPerVP, nCurChildren);
		for rowCounter = 1 : nScoresPerVP
			nonZeroIndices = find(childScores(rowCounter,:)>0);
			[curScores, curIndices] = sort(childScores(rowCounter,nonZeroIndices),'descend');
			childScores(rowCounter,:) = nan(1,nCurChildren);
			childScores(rowCounter,1:length(nonZeroIndices)) = curScores;
			sortIndices(rowCounter,1:length(nonZeroIndices)) = nonZeroIndices(curIndices);
		end
		sortIndices=reshape(sortIndices,1,[]);
		sortIndices = sortIndices(find(~isnan(sortIndices)));
		sortIndices = unique(sortIndices,'stable');        
		childIDs = newVPIDs(sortIndices);
		npass = length(childIDs);
		% We just allow up to maxNewPerIter
		% in the case where we are pooling children
		if (npass > 0)
			newPassNames = childIDs(1:min(npass,maxNewPerIter));
		end
	end

    % The repeats should already be screened, but just in case
    newPassNames = unique(newPassNames,'first');

    % Finalize the updated cohort
    mergeNames = [originalVPIDs,newPassNames];
    myWorksheet = copyWorksheet(jitteredWorksheet,mergeNames);

    %         % Repopulate results.  Note that this is not necessary
    %         % and some time to each iteration, but help to avoid issues
    %         % if the original worksheet was carrying old, invalid results.
    %         % This is therefore removed, better to check the worksheet
    %         % VPs before calling expandVPopEffN.
    %         myWorksheet.results = {};
    %         myWorksheet = simulateWorksheet(myWorksheet);
else
    warning(['Unable to proceed in ',mfilename,'.  Returning input worksheet.'])
end
end