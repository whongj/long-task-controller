[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ControllerPath,
    [string]$InitialControllerPath = '',
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Loop.IO.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'WorkflowLoop.Criteria.psm1') -Force

function Read-State([string]$Path) { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Assert-Initial($State) {
    if ([int]$State.schemaVersion -ne 1 -or [string]$State.controllerVersion -ne '1.1.1') { throw 'initial snapshot must be schema 1 controller 1.1.1' }
    foreach ($name in @('iterations', 'elapsedMinutes', 'tokensUsed', 'consecutiveNoProgress', 'repeatedFingerprintCount')) {
        if ($State.usage.$name -isnot [long] -and $State.usage.$name -isnot [int]) { throw "initial usage.$name must be integer zero" }
        if ([long]$State.usage.$name -ne 0) { throw "initial usage.$name must be zero" }
    }
    if (@($State.progressLedger).Count -ne 0 -or [string]$State.terminal.status -ne 'RUNNING') { throw 'initial snapshot must be unstarted and RUNNING' }
    foreach ($criterion in @($State.targetCriteria)) {
        if ([string]$criterion.status -ne 'PENDING' -or @($criterion.evidenceRefs).Count -ne 0 -or $null -ne $criterion.validatorResultRef) { throw 'initial target criteria must be PENDING without progress evidence' }
    }
    $legacyCanonical = ConvertTo-Json -InputObject @($State.targetCriteria) -Depth 50 -Compress
    if ((Get-StringSha256 -Value $legacyCanonical) -cne [string]$State.targetCriteriaSha256) { throw 'initial legacy targetCriteria hash mismatch' }
}
function Write-NewJson($Value, [string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes((ConvertTo-Json -InputObject $Value -Depth 50) + "`n"); $stream.Write($bytes); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

$rootResolved = (Resolve-Path -LiteralPath $Root).Path
$currentResolved = (Resolve-Path -LiteralPath $ControllerPath).Path
$outputResolved = [IO.Path]::GetFullPath($OutputPath)
$reportResolved = [IO.Path]::GetFullPath($ReportPath)
# Reserve no destination until both are checked. CreateNew also rejects a race.
foreach ($destination in @($outputResolved, $reportResolved)) {
    if (Test-Path -LiteralPath $destination) { throw "migration destination already exists: $destination" }
    if ($destination -eq $currentResolved) { throw 'migration destination must differ from input' }
}
if ($outputResolved -eq $reportResolved) { throw 'migration output and report must differ' }
$initialResolved = ''
if (-not [string]::IsNullOrWhiteSpace($InitialControllerPath)) {
    $initialResolved = (Resolve-Path -LiteralPath $InitialControllerPath).Path
    if (@($outputResolved, $reportResolved) -contains $initialResolved) { throw 'migration destination must differ from initial snapshot' }
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workflow-loop-migration-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$report = [ordered]@{
    schemaVersion = 1; operation = 'WORKFLOW_LOOP_MIGRATION'; fromVersion = '1.1.1'; toVersion = '1.2.0'
    generatedAt = [DateTime]::UtcNow.ToString('o'); status = 'BLOCK'
    controllerPath = $currentResolved; controllerSha256 = (Get-FileSha256 -LiteralPath $currentResolved)
    initialControllerPath = $null; initialControllerSha256 = $null
    outputPath = $outputResolved; outputSha256 = $null; preservedProgress = $false; errors = @()
}
try {
    $state = Read-State $currentResolved
    if ([int]$state.schemaVersion -ne 1 -or [string]$state.controllerVersion -ne '1.1.1') { throw 'migration supports schema 1 controller 1.1.1 only' }
    if ([long]$state.usage.iterations -gt 0 -or @($state.progressLedger).Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($initialResolved)) { throw 'progressed legacy state requires its original initialization snapshot' }
    } elseif ([string]::IsNullOrWhiteSpace($initialResolved)) { $initialResolved = $currentResolved }
    $initial = Read-State $initialResolved
    Assert-Initial $initial
    $report.initialControllerPath = $initialResolved
    $report.initialControllerSha256 = Get-FileSha256 -LiteralPath $initialResolved
    foreach ($field in @('loopId', 'projectId', 'workflowStage', 'objective', 'evidenceIndexRef', 'evidenceIndexSha256', 'targetCriteriaSha256')) {
        if ([string]$state.$field -cne [string]$initial.$field) { throw "legacy state identity/baseline mismatch: $field" }
    }
    $initialCanonical = Get-WorkflowLoopCriteriaCanonical -Criteria @($initial.targetCriteria)
    if ((Get-WorkflowLoopCriteriaCanonical -Criteria @($state.targetCriteria)) -cne $initialCanonical) { throw 'legacy state fixed target definition drift' }
    foreach ($field in @('maxIterations','maxElapsedMinutes','maxTokens','maxNoProgressIterations','maxRepeatedFingerprint','compactionIntervalTokens')) {
        if ($state.budgets.$field -ne $initial.budgets.$field) { throw "legacy state budget differs from initialization: $field" }
    }
    $state.controllerVersion = '1.2.0'
    $state.targetCriteriaSha256 = Get-WorkflowLoopCriteriaSha256 -Criteria @($state.targetCriteria)
    $candidate = Join-Path $tempRoot 'candidate.json'
    Write-NewJson $state $candidate
    $validated = Join-Path $tempRoot 'validated.json'
    $validationReport = Join-Path $tempRoot 'validation-report.json'
    try {
        & (Join-Path $PSScriptRoot 'Invoke-WorkflowLoopController.ps1') -Root $rootResolved -ControllerPath $candidate -OutputPath $validated -ReportPath $validationReport | Out-Null
    } catch {
        if (Test-Path -LiteralPath $validationReport) { $validation = Read-State $validationReport; throw ('migrated state validation failed: ' + (@($validation.errors) -join '; ')) }
        throw
    }
    $validatedState = Read-State $validated
    Write-NewJson $validatedState $outputResolved
    $report.outputSha256 = Get-FileSha256 -LiteralPath $outputResolved
    $report.preservedProgress = $true
    $report.status = 'PASS'
    Write-NewJson $report $reportResolved
    Write-Output 'WORKFLOW_LOOP_MIGRATION=PASS; version=1.2.0; progress=preserved'
} catch {
    $report.errors = @($_.Exception.Message)
    if (-not (Test-Path -LiteralPath $reportResolved)) { Write-NewJson $report $reportResolved }
    throw
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
