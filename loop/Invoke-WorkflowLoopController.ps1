[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ControllerPath,
    [string]$EventPath = '',
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ReportPath = '',
    [string]$EvidenceIndexPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Loop.IO.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkflowLoop.Criteria.psm1') -Force

$rootResolved = Get-NormalizedPath -Path (Resolve-Path -LiteralPath $Root).Path
$controllerResolved = (Resolve-Path -LiteralPath $ControllerPath).Path
$errors = New-Object System.Collections.Generic.List[string]
$evidenceVerificationMode = 'ADVISORY_UNTRUSTED'
$evidenceIndex = $null
$evidenceById = @{}
$validatorById = @{}
$targetVerificationStatus = 'UNTRUSTED'
$loopId = ''
$projectId = ''

function Add-ControllerError([string]$Message) { [void]$errors.Add($Message) }
function Has-Property($Object, [string]$Name) { return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] }

function Get-RequiredString($Object, [string]$Name, [string]$Path) {
    if (-not (Has-Property $Object $Name)) { Add-ControllerError "$Path.$Name is required"; return '' }
    $value = [string]$Object.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { Add-ControllerError "$Path.$Name must be non-empty"; return '' }
    return $value
}

function Resolve-EvidenceFile([string]$Reference, [string]$Label) {
    $native = ConvertTo-NativePath -RelativePath $Reference
    $path = $rootResolved
    foreach ($component in $native.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
        $path = Join-Path $path $component
        if (-not (Test-PathWithin -Parent $rootResolved -Child $path)) { throw "$Label escapes Root" }
        if (-not (Test-Path -LiteralPath $path)) { throw "$Label missing" }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw "$Label contains a link" }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label missing" }
    return $path
}

function Get-EvidenceBindingSha256([string[]]$EvidenceRefs) {
    $records = foreach ($ref in @($EvidenceRefs) | Sort-Object) {
        if ($evidenceById.ContainsKey([string]$ref)) { [ordered]@{ evidenceId = [string]$ref; sha256 = [string]$evidenceById[[string]$ref].sha256 } }
    }
    $canonical = ConvertTo-Json -InputObject @($records) -Depth 10 -Compress
    return Get-StringSha256 -Value $canonical
}

function Test-TrustedCriterion([string[]]$EvidenceRefs, [string]$ValidatorResultRef, [string]$ValidatorRef, [string]$CriterionId) {
    if ($evidenceVerificationMode -ne 'TRUSTED') { return }
    foreach ($evidenceRef in @($EvidenceRefs)) {
        if (-not $evidenceById.ContainsKey($evidenceRef)) { Add-ControllerError "criterion[$CriterionId] evidence is not indexed: $evidenceRef" }
    }
    if ([string]::IsNullOrWhiteSpace($ValidatorResultRef) -or -not $validatorById.ContainsKey($ValidatorResultRef)) {
        Add-ControllerError "criterion[$CriterionId] validator result is not indexed: $ValidatorResultRef"
        return
    }
    $resultRecord = $validatorById[$ValidatorResultRef]
    try { $resultPath = Resolve-EvidenceFile ([string]$resultRecord.sourceRef) "validator result source $ValidatorResultRef" }
    catch { Add-ControllerError $_.Exception.Message; return }
    $resultHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resultPath).Hash.ToLowerInvariant()
    if ($resultHash -ne [string]$resultRecord.sha256) { Add-ControllerError "validator result hash mismatch: $ValidatorResultRef"; return }
    try { $result = Get-Content -LiteralPath $resultPath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { Add-ControllerError "validator result JSON invalid: $ValidatorResultRef"; return }
    if ([int]$result.schemaVersion -ne 1 -or [string]$result.validatorResultRef -ne $ValidatorResultRef) { Add-ControllerError "validator result identity/schema mismatch: $ValidatorResultRef" }
    foreach ($field in @('validatorVersion','validatorSourceRef','loopId','projectId','checkedAt','inputEvidenceSha256','provenance')) { if (-not (Has-Property $result $field)) { Add-ControllerError "validator result field missing: $ValidatorResultRef.$field" } }
    if ([string]$result.loopId -ne $loopId -or [string]$result.projectId -ne $projectId) { Add-ControllerError "validator result loop/project binding mismatch: $ValidatorResultRef" }
    Test-DateTimeValue ([string]$result.checkedAt) "validator[$ValidatorResultRef].checkedAt"
    if (-not (Has-Property $result.provenance 'kind') -or @('AUTOMATED','HUMAN_REVIEW') -notcontains [string]$result.provenance.kind) { Add-ControllerError "validator result provenance is invalid: $ValidatorResultRef" }
    if ([string]$result.inputEvidenceSha256 -ne (Get-EvidenceBindingSha256 $EvidenceRefs)) { Add-ControllerError "validator result input evidence hash mismatch: $ValidatorResultRef" }
    if ([string]$result.status -ne 'PASS') { Add-ControllerError "criterion[$CriterionId] validator result is not PASS: $ValidatorResultRef" }
    if ([string]$result.validatorRef -ne $ValidatorRef) { Add-ControllerError "criterion[$CriterionId] validator identity mismatch: $ValidatorResultRef" }
    foreach ($evidenceRef in @($EvidenceRefs)) {
        if (@($result.evidenceRefs) -notcontains $evidenceRef) { Add-ControllerError "criterion[$CriterionId] validator result does not bind evidence: $evidenceRef" }
    }
}

function Get-IntegerField($Object, [string]$Name, [string]$Path, [long]$Minimum) {
    if (-not (Has-Property $Object $Name)) { Add-ControllerError "$Path.$Name is required"; return $Minimum }
    try {
        $decimalValue = [decimal]$Object.$Name
        if ($decimalValue -ne [decimal]::Truncate($decimalValue)) { Add-ControllerError "$Path.$Name must be an integer"; return $Minimum }
        $value = [long]$decimalValue
    } catch { Add-ControllerError "$Path.$Name must be an integer"; return $Minimum }
    if ($value -lt $Minimum) { Add-ControllerError "$Path.$Name must be at least $Minimum" }
    return $value
}

function Test-DateTimeValue([string]$Value, [string]$Path) {
    $parsed = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [DateTimeOffset]::TryParse($Value, [ref]$parsed)) { Add-ControllerError "$Path must be a valid date-time" }
}

function Write-JsonUtf8($Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 40) + "`n"), [Text.UTF8Encoding]::new($false))
}

try { $state = Get-Content -LiteralPath $controllerResolved -Encoding UTF8 -Raw | ConvertFrom-Json } catch { Add-ControllerError "controller JSON cannot be parsed: $($_.Exception.Message)"; $state = $null }

if ($null -ne $state) {
    if (Has-Property $state 'evidenceVerificationMode') { $evidenceVerificationMode = [string]$state.evidenceVerificationMode }
    if (@('TRUSTED', 'ADVISORY_UNTRUSTED') -notcontains $evidenceVerificationMode) { Add-ControllerError "evidenceVerificationMode is invalid: $evidenceVerificationMode" }
    if (-not (Has-Property $state 'usageVerificationMode') -or @('ADVISORY_UNTRUSTED', 'HOST_RECEIPT_VERIFIED') -notcontains [string]$state.usageVerificationMode) { Add-ControllerError 'usageVerificationMode must be ADVISORY_UNTRUSTED or HOST_RECEIPT_VERIFIED' }
    if ((Has-Property $state 'usageVerificationMode') -and [string]$state.usageVerificationMode -eq 'HOST_RECEIPT_VERIFIED') { Add-ControllerError 'HOST_RECEIPT_VERIFIED is unavailable until a host receipt adapter is registered' }
    if ($evidenceVerificationMode -eq 'TRUSTED') {
        $indexCandidate = if (-not [string]::IsNullOrWhiteSpace($EvidenceIndexPath)) { $EvidenceIndexPath } elseif (Has-Property $state 'evidenceIndexRef') { [string]$state.evidenceIndexRef } else { '' }
        if ([string]::IsNullOrWhiteSpace($indexCandidate)) { Add-ControllerError 'TRUSTED loop requires evidenceIndexRef or EvidenceIndexPath' }
        else {
            try {
                $indexResolved = Resolve-EvidenceFile $indexCandidate 'evidence index'
                $evidenceIndexRaw = Get-Content -LiteralPath $indexResolved -Encoding UTF8 -Raw
                $evidenceIndex = $evidenceIndexRaw | ConvertFrom-Json
                if ([int]$evidenceIndex.schemaVersion -ne 1) { Add-ControllerError 'evidence index schemaVersion must be 1' }
                if (-not (Has-Property $state 'evidenceIndexSha256')) { Add-ControllerError 'TRUSTED loop requires evidenceIndexSha256' } else {
                    $actualIndexSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $indexResolved).Hash.ToLowerInvariant()
                    if ($actualIndexSha -ne [string]$state.evidenceIndexSha256) { Add-ControllerError 'evidence index hash drift detected' }
                }
                if ((Has-Property $state 'loopId') -and [string]$evidenceIndex.loopId -ne [string]$state.loopId) { Add-ControllerError 'evidence index loopId does not match controller' }
                if ((Has-Property $state 'projectId') -and [string]$evidenceIndex.projectId -ne [string]$state.projectId) { Add-ControllerError 'evidence index projectId does not match controller' }
                foreach ($record in @($evidenceIndex.evidence)) {
                    $id = [string]$record.evidenceId
                    if ($evidenceById.ContainsKey($id)) { Add-ControllerError "duplicate evidence index id: $id" } else { $evidenceById[$id] = $record }
                    try {
                        $sourcePath = Resolve-EvidenceFile ([string]$record.sourceRef) 'evidence source'
                        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
                        if ($actual -ne [string]$record.sha256) { Add-ControllerError "evidence hash mismatch: $id" }
                    } catch { Add-ControllerError "$($_.Exception.Message): $id" }
                }
                foreach ($record in @($evidenceIndex.validatorResults)) {
                    $id = [string]$record.validatorResultRef
                    if ($validatorById.ContainsKey($id)) { Add-ControllerError "duplicate validator result id: $id" } else { $validatorById[$id] = $record }
                    try {
                        $resultPath = Resolve-EvidenceFile ([string]$record.sourceRef) 'validator result source'
                        $resultHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resultPath).Hash.ToLowerInvariant()
                        if ($resultHash -ne [string]$record.sha256) { Add-ControllerError "validator result hash mismatch: $id" }
                    } catch { Add-ControllerError "$($_.Exception.Message): $id" }
                }
            } catch { Add-ControllerError "evidence index cannot be loaded: $($_.Exception.Message)" }
        }
    }
}

$loopId = ''
$criteria = @()
$ledger = @()
$targetById = @{}
$maxIterations = 0L
$maxElapsedMinutes = 0L
$maxTokens = 0L
$maxNoProgressIterations = 0L
$maxRepeatedFingerprint = 0L
$compactionIntervalTokens = 0L
$usageIterations = 0L
$usageElapsed = 0L
$usageTokens = 0L
$usageNoProgress = 0L
$usageRepeatedFingerprint = 0L
$lastHandoffTokens = 0L
$terminalStatus = ''
$ledgerEventIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

if ($null -ne $state) {
    if (-not (Has-Property $state 'schemaVersion') -or [int]$state.schemaVersion -ne 1) { Add-ControllerError 'schemaVersion must be 1' }
    if (-not (Has-Property $state 'controllerVersion') -or [string]$state.controllerVersion -ne '1.2.0') { Add-ControllerError 'controllerVersion must be 1.2.0; migrate legacy state with Convert-WorkflowLoopState.ps1' }
    $loopId = Get-RequiredString $state 'loopId' 'controller'
    $projectId = Get-RequiredString $state 'projectId' 'controller'
    [void](Get-RequiredString $state 'objective' 'controller')
    $workflowStage = Get-RequiredString $state 'workflowStage' 'controller'
    try {
        $transitions = Get-Content -LiteralPath (Join-Path $rootResolved (ConvertTo-NativePath -RelativePath 'governance/workflow-transitions.json')) -Encoding UTF8 -Raw | ConvertFrom-Json
        if (@($transitions.stages) -notcontains $workflowStage) { Add-ControllerError "workflowStage is not registered: $workflowStage" }
    } catch { Add-ControllerError "workflow transition registry cannot be parsed: $($_.Exception.Message)" }

    if (Has-Property $state 'targetCriteria') { $criteria = @($state.targetCriteria) }
    if ($criteria.Count -lt 1) { Add-ControllerError 'targetCriteria must contain at least one criterion' }
    foreach ($criterion in $criteria) {
        $criterionId = Get-RequiredString $criterion 'criterionId' 'criterion'
        [void](Get-RequiredString $criterion 'description' "criterion[$criterionId]")
        [void](Get-RequiredString $criterion 'validatorRef' "criterion[$criterionId]")
        if (-not [string]::IsNullOrWhiteSpace($criterionId)) {
            if ($targetById.ContainsKey($criterionId)) { Add-ControllerError "duplicate criterionId: $criterionId" } else { $targetById[$criterionId] = $criterion }
        }
        $criterionStatus = if (Has-Property $criterion 'status') { [string]$criterion.status } else { '' }
        if (@('PENDING', 'PASS', 'FAIL') -notcontains $criterionStatus) { Add-ControllerError "criterion[$criterionId].status is invalid" }
        $criterionEvidence = @()
        if (Has-Property $criterion 'evidenceRefs') { $criterionEvidence = @($criterion.evidenceRefs) } else { Add-ControllerError "criterion[$criterionId].evidenceRefs is required" }
        $criterionEvidenceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($criterionEvidenceValue in $criterionEvidence) {
            $criterionEvidenceId = [string]$criterionEvidenceValue
            if ($criterionEvidenceId -notmatch '^E-[A-Za-z0-9._-]+$') { Add-ControllerError "criterion[$criterionId] has invalid evidence: $criterionEvidenceId" }
            if (-not $criterionEvidenceSet.Add($criterionEvidenceId)) { Add-ControllerError "criterion[$criterionId] has duplicate evidence: $criterionEvidenceId" }
        }
        $criterionResultRef = if ((Has-Property $criterion 'validatorResultRef') -and $null -ne $criterion.validatorResultRef) { [string]$criterion.validatorResultRef } else { '' }
        if ($criterionStatus -eq 'PASS' -and ($criterionEvidence.Count -lt 1 -or [string]::IsNullOrWhiteSpace($criterionResultRef))) { Add-ControllerError "criterion[$criterionId] PASS requires evidence and validatorResultRef" }
        if ($criterionStatus -eq 'PASS') { Test-TrustedCriterion $criterionEvidence $criterionResultRef ([string]$criterion.validatorRef) $criterionId }
    }
    if (-not (Has-Property $state 'targetCriteriaSha256')) { Add-ControllerError 'targetCriteriaSha256 is required' } else {
        try {
            if ((Get-WorkflowLoopCriteriaSha256 -Criteria @($criteria)) -ne [string]$state.targetCriteriaSha256) { Add-ControllerError 'targetCriteria hash mismatch' }
        } catch { Add-ControllerError ('targetCriteria canonicalization failed: ' + $_.Exception.Message) }
    }
    if (-not (Has-Property $state 'evidenceIndexSha256')) { Add-ControllerError 'evidenceIndexSha256 is required' }

    if (-not (Has-Property $state 'budgets')) {
        Add-ControllerError 'budgets is required'
    } else {
        $maxIterations = Get-IntegerField $state.budgets 'maxIterations' 'budgets' 1
        $maxElapsedMinutes = Get-IntegerField $state.budgets 'maxElapsedMinutes' 'budgets' 1
        $maxTokens = Get-IntegerField $state.budgets 'maxTokens' 'budgets' 1
        $maxNoProgressIterations = Get-IntegerField $state.budgets 'maxNoProgressIterations' 'budgets' 1
        $maxRepeatedFingerprint = Get-IntegerField $state.budgets 'maxRepeatedFingerprint' 'budgets' 2
        $compactionIntervalTokens = Get-IntegerField $state.budgets 'compactionIntervalTokens' 'budgets' 1
        if ($compactionIntervalTokens -gt $maxTokens) { Add-ControllerError 'compactionIntervalTokens cannot exceed maxTokens' }
    }

    if (-not (Has-Property $state 'usage')) {
        Add-ControllerError 'usage is required'
    } else {
        $usageIterations = Get-IntegerField $state.usage 'iterations' 'usage' 0
        $usageElapsed = Get-IntegerField $state.usage 'elapsedMinutes' 'usage' 0
        $usageTokens = Get-IntegerField $state.usage 'tokensUsed' 'usage' 0
        $usageNoProgress = Get-IntegerField $state.usage 'consecutiveNoProgress' 'usage' 0
        $usageRepeatedFingerprint = Get-IntegerField $state.usage 'repeatedFingerprintCount' 'usage' 0
        $startedAt = Get-RequiredString $state.usage 'startedAt' 'usage'
        $updatedAt = Get-RequiredString $state.usage 'updatedAt' 'usage'
        Test-DateTimeValue $startedAt 'usage.startedAt'
        Test-DateTimeValue $updatedAt 'usage.updatedAt'
    }

    if (Has-Property $state 'progressLedger') { $ledger = @($state.progressLedger) } else { Add-ControllerError 'progressLedger is required' }
    if ($usageIterations -ne $ledger.Count) { Add-ControllerError 'usage.iterations must equal progressLedger length' }
    $expectedLedgerIteration = 1
    $ledgerTokenTotal = 0L
    $lastLedgerElapsed = 0L
    $derivedNoProgress = 0L
    $derivedRepeatedFingerprint = 0L
    $previousLedgerFingerprint = ''
    foreach ($entry in $ledger) {
        $entryId = Get-RequiredString $entry 'eventId' 'progressLedger'
        if (-not $ledgerEventIds.Add($entryId)) { Add-ControllerError "duplicate progress ledger eventId: $entryId" }
        $entryIteration = Get-IntegerField $entry 'iteration' "progressLedger[$entryId]" 1
        if ($entryIteration -ne $expectedLedgerIteration) { Add-ControllerError "non-contiguous progress ledger iteration: $entryId" }
        $expectedLedgerIteration++
        $ledgerTokenTotal += Get-IntegerField $entry 'tokenDelta' "progressLedger[$entryId]" 0
        $entryElapsed = Get-IntegerField $entry 'elapsedMinutes' "progressLedger[$entryId]" 0
        if ($entryElapsed -lt $lastLedgerElapsed) { Add-ControllerError "progressLedger[$entryId].elapsedMinutes moves backward" }
        $lastLedgerElapsed = $entryElapsed
        [void](Get-RequiredString $entry 'actionSummary' "progressLedger[$entryId]")
        $entryRecordedAt = Get-RequiredString $entry 'recordedAt' "progressLedger[$entryId]"
        Test-DateTimeValue $entryRecordedAt "progressLedger[$entryId].recordedAt"
        if (-not (Has-Property $entry 'changedCriteria') -or -not (Has-Property $entry 'evidenceRefs') -or -not (Has-Property $entry 'compactionHandoffRef')) { Add-ControllerError "progressLedger[$entryId] lacks changedCriteria, evidenceRefs, or compactionHandoffRef" }
        if (-not (Has-Property $entry 'progressMade') -or $entry.progressMade -isnot [bool]) { Add-ControllerError "progressLedger[$entryId].progressMade must be boolean" }
        $fingerprint = Get-RequiredString $entry 'progressFingerprint' "progressLedger[$entryId]"
        if ($fingerprint -notmatch '^[a-f0-9]{64}$') { Add-ControllerError "progressLedger[$entryId].progressFingerprint is invalid" }
        if (Has-Property $entry 'progressMade') { if ([bool]$entry.progressMade) { $derivedNoProgress = 0 } else { $derivedNoProgress++ } }
        $derivedRepeatedFingerprint = if ($fingerprint -eq $previousLedgerFingerprint) { $derivedRepeatedFingerprint + 1 } else { 1 }
        $previousLedgerFingerprint = $fingerprint
    }
    if ($ledgerTokenTotal -ne $usageTokens) { Add-ControllerError 'usage.tokensUsed must equal progressLedger token total' }
    if ($ledger.Count -gt 0 -and $lastLedgerElapsed -ne $usageElapsed) { Add-ControllerError 'usage.elapsedMinutes must equal the latest ledger elapsedMinutes' }
    if ($usageNoProgress -ne $derivedNoProgress) { Add-ControllerError 'usage.consecutiveNoProgress does not replay from progressLedger' }
    if ($usageRepeatedFingerprint -ne $derivedRepeatedFingerprint) { Add-ControllerError 'usage.repeatedFingerprintCount does not replay from progressLedger' }

    if (-not (Has-Property $state 'compaction')) {
        Add-ControllerError 'compaction is required'
    } else {
        if (-not (Has-Property $state.compaction 'required')) { Add-ControllerError 'compaction.required is required' }
        $lastHandoffTokens = Get-IntegerField $state.compaction 'lastHandoffTokens' 'compaction' 0
        if ($lastHandoffTokens -gt $usageTokens) { Add-ControllerError 'compaction.lastHandoffTokens cannot exceed usage.tokensUsed' }
        if (-not (Has-Property $state.compaction 'lastHandoffRef')) { Add-ControllerError 'compaction.lastHandoffRef is required' }
    }

    if (-not (Has-Property $state 'terminal')) {
        Add-ControllerError 'terminal is required'
    } else {
        $terminalStatus = Get-RequiredString $state.terminal 'status' 'terminal'
        if (@('RUNNING', 'TARGET_MET', 'BUDGET_EXHAUSTED', 'DOOM_LOOP', 'BLOCKED', 'ESCALATED', 'CANCELLED') -notcontains $terminalStatus) { Add-ControllerError 'terminal.status is invalid' }
        if (-not (Has-Property $state.terminal 'reason') -or -not (Has-Property $state.terminal 'decidedAt') -or -not (Has-Property $state.terminal 'qvaDecisionRef')) { Add-ControllerError 'terminal reason, decidedAt and qvaDecisionRef are required' }
        if ($terminalStatus -eq 'RUNNING' -and $null -ne $state.terminal.decidedAt) { Add-ControllerError 'RUNNING terminal.decidedAt must be null' }
        if ($terminalStatus -ne 'RUNNING' -and $null -eq $state.terminal.decidedAt) { Add-ControllerError 'terminal.decidedAt is required after loop termination' }
    }
    $nextAction = Get-RequiredString $state 'nextAction' 'controller'
    if (@('RUN_ITERATION', 'WRITE_COMPACTION_HANDOFF', 'REQUEST_QVA_DECISION', 'RESOLVE_BLOCKER', 'ESCALATE_TO_OWNER', 'WAIT_FOR_OWNER', 'NONE') -notcontains $nextAction) { Add-ControllerError 'nextAction is invalid' }
    $allStateTargetsMet = @($criteria | Where-Object { [string]$_.status -ne 'PASS' }).Count -eq 0
    if ($terminalStatus -eq 'RUNNING' -and (Has-Property $state 'compaction') -and (Has-Property $state 'usage')) {
        if ($usageIterations -ge $maxIterations -or $usageElapsed -ge $maxElapsedMinutes -or $usageTokens -ge $maxTokens) { Add-ControllerError 'RUNNING state has already exhausted a budget' }
        if ($usageNoProgress -ge $maxNoProgressIterations -or $usageRepeatedFingerprint -ge $maxRepeatedFingerprint) { Add-ControllerError 'RUNNING state has already reached a doom-loop threshold' }
        $compactionDue = ($usageTokens - [long]$state.compaction.lastHandoffTokens) -ge $compactionIntervalTokens
        if ([bool]$state.compaction.required -ne $compactionDue) { Add-ControllerError 'compaction.required does not match token distance from the last handoff' }
        $expectedRunningAction = if ($compactionDue) { 'WRITE_COMPACTION_HANDOFF' } else { 'RUN_ITERATION' }
        if ($nextAction -ne $expectedRunningAction) { Add-ControllerError "RUNNING nextAction must be $expectedRunningAction" }
        if ($allStateTargetsMet) { Add-ControllerError 'RUNNING state cannot have every target criterion PASS' }
    } elseif ([string]::IsNullOrWhiteSpace([string]$state.terminal.reason)) {
        Add-ControllerError 'terminal reason is required after loop termination'
    }
    if ($terminalStatus -eq 'TARGET_MET' -and (-not $allStateTargetsMet -or $nextAction -ne 'REQUEST_QVA_DECISION')) { Add-ControllerError 'TARGET_MET requires all criteria PASS and nextAction REQUEST_QVA_DECISION' }
    $terminalActionMap = @{ BUDGET_EXHAUSTED = 'ESCALATE_TO_OWNER'; DOOM_LOOP = 'ESCALATE_TO_OWNER'; BLOCKED = 'RESOLVE_BLOCKER'; ESCALATED = 'WAIT_FOR_OWNER'; CANCELLED = 'NONE' }
    if ($terminalActionMap.ContainsKey($terminalStatus) -and $nextAction -ne $terminalActionMap[$terminalStatus]) { Add-ControllerError "$terminalStatus nextAction must be $($terminalActionMap[$terminalStatus])" }
}

$event = $null
$eventId = ''
$eventUpdates = @()
$eventControl = ''
$eventHandoffRef = ''
$eventIteration = 0L
$eventTokenDelta = 0L
$eventElapsed = 0L
$eventRecordedAt = ''
$eventFingerprint = ''
$eventActionSummary = ''

if (-not [string]::IsNullOrWhiteSpace($EventPath)) {
    try { $eventResolved = (Resolve-Path -LiteralPath $EventPath).Path; $event = Get-Content -LiteralPath $eventResolved -Encoding UTF8 -Raw | ConvertFrom-Json } catch { Add-ControllerError "loop event cannot be parsed: $($_.Exception.Message)" }
}

if ($null -ne $event) {
    if (-not (Has-Property $event 'schemaVersion') -or [int]$event.schemaVersion -ne 1) { Add-ControllerError 'event.schemaVersion must be 1' }
    if (-not (Has-Property $event 'eventVersion') -or [string]$event.eventVersion -ne '1.0.0') { Add-ControllerError 'event.eventVersion must be 1.0.0' }
    $eventId = Get-RequiredString $event 'eventId' 'event'
    $eventLoopId = Get-RequiredString $event 'loopId' 'event'
    if ($eventLoopId -ne $loopId) { Add-ControllerError 'event.loopId does not match controller.loopId' }
    $eventIteration = Get-IntegerField $event 'iteration' 'event' 1
    if ($eventIteration -ne ($usageIterations + 1)) { Add-ControllerError "event.iteration must be $($usageIterations + 1)" }
    if ($ledgerEventIds.Contains($eventId)) { Add-ControllerError "eventId already exists in progress ledger: $eventId" }
    $eventActionSummary = Get-RequiredString $event 'actionSummary' 'event'
    $eventFingerprint = Get-RequiredString $event 'progressFingerprint' 'event'
    if ($eventFingerprint -notmatch '^[a-f0-9]{64}$') { Add-ControllerError 'event.progressFingerprint must be a lowercase SHA-256' }
    $eventTokenDelta = Get-IntegerField $event 'tokenDelta' 'event' 0
    $eventElapsed = Get-IntegerField $event 'elapsedMinutes' 'event' 0
    if ($eventElapsed -lt $usageElapsed) { Add-ControllerError 'event.elapsedMinutes cannot move backward' }
    $eventRecordedAt = Get-RequiredString $event 'recordedAt' 'event'
    Test-DateTimeValue $eventRecordedAt 'event.recordedAt'
    $eventControl = Get-RequiredString $event 'control' 'event'
    if (@('CONTINUE', 'BLOCK', 'ESCALATE', 'CANCEL') -notcontains $eventControl) { Add-ControllerError 'event.control is invalid' }
    $controlReason = if ((Has-Property $event 'controlReason') -and $null -ne $event.controlReason) { [string]$event.controlReason } else { '' }
    if ($eventControl -ne 'CONTINUE' -and [string]::IsNullOrWhiteSpace($controlReason)) { Add-ControllerError 'non-CONTINUE event requires controlReason' }
    if ((Has-Property $event 'compactionHandoffRef') -and $null -ne $event.compactionHandoffRef) { $eventHandoffRef = [string]$event.compactionHandoffRef }
    if ($terminalStatus -ne 'RUNNING') { Add-ControllerError "cannot append an event to terminal loop state: $terminalStatus" }
    if ((Has-Property $state 'compaction') -and (Has-Property $state.compaction 'required') -and [bool]$state.compaction.required -and $eventControl -eq 'CONTINUE' -and [string]::IsNullOrWhiteSpace($eventHandoffRef)) { Add-ControllerError 'compaction handoff is required before the next normal iteration' }

    if (Has-Property $event 'criterionUpdates') { $eventUpdates = @($event.criterionUpdates) } else { Add-ControllerError 'event.criterionUpdates is required' }
    $updateIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($update in $eventUpdates) {
        $updateId = Get-RequiredString $update 'criterionId' 'criterionUpdate'
        if (-not $updateIds.Add($updateId)) { Add-ControllerError "duplicate criterion update: $updateId" }
        if (-not $targetById.ContainsKey($updateId)) { Add-ControllerError "criterion update references unknown target: $updateId" }
        $updateStatus = if (Has-Property $update 'status') { [string]$update.status } else { '' }
        if (@('PENDING', 'PASS', 'FAIL') -notcontains $updateStatus) { Add-ControllerError "criterionUpdate[$updateId].status is invalid" }
        $updateEvidence = @()
        if (Has-Property $update 'evidenceRefs') { $updateEvidence = @($update.evidenceRefs) } else { Add-ControllerError "criterionUpdate[$updateId].evidenceRefs is required" }
        foreach ($evidenceRefValue in $updateEvidence) { if ([string]$evidenceRefValue -notmatch '^E-[A-Za-z0-9._-]+$') { Add-ControllerError "criterionUpdate[$updateId] has invalid evidence: $evidenceRefValue" } }
        $updateResultRef = if ((Has-Property $update 'validatorResultRef') -and $null -ne $update.validatorResultRef) { [string]$update.validatorResultRef } else { '' }
        if ($updateStatus -eq 'PASS' -and ($updateEvidence.Count -lt 1 -or [string]::IsNullOrWhiteSpace($updateResultRef))) { Add-ControllerError "criterionUpdate[$updateId] PASS requires evidence and validatorResultRef" }
        if ($updateStatus -eq 'PASS' -and $targetById.ContainsKey($updateId)) { Test-TrustedCriterion $updateEvidence $updateResultRef ([string]$targetById[$updateId].validatorRef) $updateId }
    }
}

if ($errors.Count -eq 0 -and $null -ne $event) {
    $progressMade = $false
    $changedCriteria = New-Object Collections.Generic.List[string]
    $eventEvidenceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($update in $eventUpdates) {
        $criterion = $targetById[[string]$update.criterionId]
        $oldStatus = [string]$criterion.status
        $oldEvidence = @($criterion.evidenceRefs)
        $oldResultRef = if ($null -ne $criterion.validatorResultRef) { [string]$criterion.validatorResultRef } else { '' }
        $newEvidence = @($oldEvidence + @($update.evidenceRefs) | Sort-Object -Unique)
        $newResultRef = if ($null -ne $update.validatorResultRef) { [string]$update.validatorResultRef } else { '' }
        $changed = $oldStatus -ne [string]$update.status -or $newEvidence.Count -ne $oldEvidence.Count -or $oldResultRef -ne $newResultRef
        if ($changed) { [void]$changedCriteria.Add([string]$update.criterionId) }
        if (($oldStatus -ne 'PASS' -and [string]$update.status -eq 'PASS') -or $newEvidence.Count -gt $oldEvidence.Count -or (-not [string]::IsNullOrWhiteSpace($newResultRef) -and $newResultRef -ne $oldResultRef)) { $progressMade = $true }
        $criterion.status = [string]$update.status
        $criterion.evidenceRefs = $newEvidence
        $criterion.validatorResultRef = if ([string]::IsNullOrWhiteSpace($newResultRef)) { $null } else { $newResultRef }
        foreach ($evidenceRefValue in @($update.evidenceRefs)) { [void]$eventEvidenceSet.Add([string]$evidenceRefValue) }
    }

    $newTokenTotal = $usageTokens + $eventTokenDelta
    if (-not [string]::IsNullOrWhiteSpace($eventHandoffRef)) {
        if ([string]$state.compaction.lastHandoffRef -ne $eventHandoffRef) { $progressMade = $true }
        $state.compaction.lastHandoffRef = $eventHandoffRef
        $state.compaction.lastHandoffTokens = $newTokenTotal
        $state.compaction.required = $false
    }

    $previousFingerprint = if ($ledger.Count -gt 0) { [string]$ledger[-1].progressFingerprint } else { '' }
    $state.usage.repeatedFingerprintCount = if ($previousFingerprint -eq $eventFingerprint) { [int]$state.usage.repeatedFingerprintCount + 1 } else { 1 }
    $state.usage.consecutiveNoProgress = if ($progressMade) { 0 } else { [int]$state.usage.consecutiveNoProgress + 1 }
    $state.usage.iterations = $eventIteration
    $state.usage.elapsedMinutes = $eventElapsed
    $state.usage.tokensUsed = $newTokenTotal
    $state.usage.updatedAt = $eventRecordedAt

    $ledgerEntry = [pscustomobject][ordered]@{
        iteration = $eventIteration
        eventId = $eventId
        actionSummary = $eventActionSummary
        changedCriteria = @($changedCriteria.ToArray())
        evidenceRefs = @($eventEvidenceSet | Sort-Object)
        progressMade = [bool]$progressMade
        progressFingerprint = $eventFingerprint
        tokenDelta = $eventTokenDelta
        elapsedMinutes = $eventElapsed
        recordedAt = $eventRecordedAt
        compactionHandoffRef = if ([string]::IsNullOrWhiteSpace($eventHandoffRef)) { $null } else { $eventHandoffRef }
    }
    $state.progressLedger = @($state.progressLedger) + @($ledgerEntry)

    if ($state.terminal.status -eq 'RUNNING' -and ($newTokenTotal - [long]$state.compaction.lastHandoffTokens) -ge $compactionIntervalTokens) { $state.compaction.required = $true }
    $allTargetsMet = @($state.targetCriteria | Where-Object { [string]$_.status -ne 'PASS' }).Count -eq 0

    if ($eventControl -eq 'BLOCK') {
        $state.terminal.status = 'BLOCKED'; $state.terminal.reason = $controlReason; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'RESOLVE_BLOCKER'
    } elseif ($eventControl -eq 'ESCALATE') {
        $state.terminal.status = 'ESCALATED'; $state.terminal.reason = $controlReason; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'WAIT_FOR_OWNER'
    } elseif ($eventControl -eq 'CANCEL') {
        $state.terminal.status = 'CANCELLED'; $state.terminal.reason = $controlReason; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'NONE'
    } elseif ($allTargetsMet) {
        $state.terminal.status = 'TARGET_MET'; $state.terminal.reason = 'All fixed target criteria passed; workflow transition still requires Governance Q/V/A.'; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'REQUEST_QVA_DECISION'; $targetVerificationStatus = 'ADVISORY_UNTRUSTED'; if (Has-Property $state 'targetVerification') { $state.targetVerification.status = $targetVerificationStatus; $state.targetVerification.reason = if ($evidenceVerificationMode -eq 'TRUSTED') { 'Evidence and validator-result hashes are checked; caller-supplied usage has no host receipt and remains advisory.' } else { 'Evidence was not trusted by the loop runner.' } }
    } elseif ([int]$state.usage.consecutiveNoProgress -ge $maxNoProgressIterations -or [int]$state.usage.repeatedFingerprintCount -ge $maxRepeatedFingerprint) {
        $state.terminal.status = 'DOOM_LOOP'; $state.terminal.reason = 'No-progress or repeated-fingerprint budget reached.'; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'ESCALATE_TO_OWNER'
    } elseif ([int]$state.usage.iterations -ge $maxIterations -or [int]$state.usage.elapsedMinutes -ge $maxElapsedMinutes -or [long]$state.usage.tokensUsed -ge $maxTokens) {
        $state.terminal.status = 'BUDGET_EXHAUSTED'; $state.terminal.reason = 'Iteration, elapsed-time, or token budget reached before all target criteria passed.'; $state.terminal.decidedAt = $eventRecordedAt; $state.nextAction = 'ESCALATE_TO_OWNER'
    } elseif ([bool]$state.compaction.required) {
        $state.nextAction = 'WRITE_COMPACTION_HANDOFF'
    } else {
        $state.nextAction = 'RUN_ITERATION'
    }
    $terminalStatus = [string]$state.terminal.status
    if ($terminalStatus -eq 'TARGET_MET') { $targetVerificationStatus = 'ADVISORY_UNTRUSTED' }
}

$operationStatus = if ($errors.Count -eq 0) { 'PASS' } else { 'BLOCK' }
$report = [ordered]@{
    schemaVersion = 1
    contract = 'workflow-loop-controller/1.2.0'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    controllerPath = $controllerResolved
    eventPath = if ([string]::IsNullOrWhiteSpace($EventPath)) { $null } else { $EventPath }
    loopId = $loopId
    eventId = $eventId
    status = $operationStatus
    terminalStatus = $terminalStatus
    evidenceVerificationMode = $evidenceVerificationMode
    targetVerificationStatus = $targetVerificationStatus
    errors = $errors.ToArray()
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) { Write-JsonUtf8 $report $ReportPath }
if ($errors.Count -gt 0) { Write-Output ("WORKFLOW_LOOP status=BLOCK loop={0} event={1} errors={2}" -f $loopId, $eventId, $errors.Count); throw "WORKFLOW_LOOP_BLOCK errors=$($errors.Count)" }

Write-JsonUtf8 $state $OutputPath
Write-Output ("WORKFLOW_LOOP status=PASS loop={0} event={1} terminal={2} next={3}" -f $loopId, $eventId, $state.terminal.status, $state.nextAction)
