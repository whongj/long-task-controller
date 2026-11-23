$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('long-task-loop-' + [Guid]::NewGuid())
$runner = Join-Path $PSScriptRoot '../loop/Invoke-WorkflowLoopController.ps1'
Import-Module (Join-Path $PSScriptRoot '../loop/WorkflowLoop.Criteria.psm1') -Force

function Write-Fixture($Value, [string]$Name) {
    $path = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Value -Depth 30))
    return $path
}
function Read-Fixture([string]$Name) {
    return Get-Content -LiteralPath (Join-Path $root $Name) -Raw | ConvertFrom-Json
}
function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected $Expected but got $Actual" }
}
function Invoke-Case($State, $Event, [string]$Name, [string]$ExpectedError = '') {
    $statePath = Write-Fixture $State "$Name.input.json"
    $out = Join-Path $root "$Name.output.json"
    $report = Join-Path $root "$Name.receipt.json"
    $args = @{ Root = $root; ControllerPath = $statePath; OutputPath = $out; ReportPath = $report }
    if ($null -ne $Event) { $args.EventPath = Write-Fixture $Event "$Name.event.json" }
    try {
        & $runner @args | Out-Null
        Assert-Equal $ExpectedError ''
    } catch {
        if (-not $ExpectedError) { if (Test-Path $report) { throw ((Read-Fixture "$Name.receipt.json").errors -join ' | ') }; throw }
        $decision = Read-Fixture "$Name.receipt.json"
        Assert-Equal $decision.status 'BLOCK'
        if (-not (($decision.errors -join ' ').Contains($ExpectedError))) { throw ($decision.errors -join ' ') }
        Assert-Equal (Test-Path $out) $false
        return
    }
    return Read-Fixture "$Name.output.json"
}

try {
    [void](Write-Fixture @{ stages = @('Build') } 'governance/workflow-transitions.json')
    $state = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'base-state.json') -Raw | ConvertFrom-Json
    $state.targetCriteriaSha256 = Get-WorkflowLoopCriteriaSha256 -Criteria $state.targetCriteria
    $init = Invoke-Case $state $null 'init'
    Assert-Equal $init.terminal.status 'RUNNING'
    $changed = Read-Fixture 'init.input.json'
    $changed.targetCriteria[0].description = 'Different criterion'
    Invoke-Case $changed $null 'changed' 'targetCriteria hash mismatch'
    $event = [pscustomobject]@{
        schemaVersion = 1; control = 'CONTINUE'; eventVersion = '1.0.0'; eventId = 'step1'; loopId = 'demo-loop'; iteration = 1
        actionSummary = 'Check local fixture'; recordedAt = '2026-01-01T00:01:00Z'
        tokenDelta = 1; elapsedMinutes = 1; progressFingerprint = ('a' * 64)
        criterionUpdates = @([pscustomobject]@{ criterionId = 'check-one'; status = 'PASS'; evidenceRefs = @(); validatorResultRef = $null })
    }
    Invoke-Case $init $event 'missing-evidence' 'PASS requires evidence'
    $event.criterionUpdates[0].evidenceRefs = @('E-local-evidence')
    $event.criterionUpdates[0].validatorResultRef = 'local-result'
    $passed = Invoke-Case $init $event 'passed'
    Assert-Equal $passed.terminal.status 'TARGET_MET'
    Assert-Equal $passed.targetVerification.status 'ADVISORY_UNTRUSTED'
    Assert-Equal $passed.targetCriteriaSha256 $init.targetCriteriaSha256
    $event.criterionUpdates = @()
    $event.tokenDelta = 100
    $progress = Invoke-Case $init $event 'compact'
    Assert-Equal $progress.nextAction 'WRITE_COMPACTION_HANDOFF'
    $event.eventId = 'step2'
    $event.iteration = 2
    $event.elapsedMinutes = 2
    $event.recordedAt = '2026-01-01T00:02:00Z'
    Invoke-Case $progress $event 'no-handoff' 'compaction handoff is required'
    $event | Add-Member NoteProperty compactionHandoffRef 'handoff.md'
    $event.tokenDelta = 1
    $stalled = Invoke-Case $progress $event 'stall'
    Assert-Equal $stalled.terminal.status 'DOOM_LOOP'
    $target = Write-Fixture @{ schemaVersion = 1 } 'outside-link-target.json'
    $link = Join-Path $root 'link.json'
    New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
    $linked = Read-Fixture 'init.input.json'
    $linked.evidenceVerificationMode = 'TRUSTED'
    $linked.evidenceIndexRef = 'link.json'
    Invoke-Case $linked $null 'linked-evidence-index' 'evidence index contains a link'
    Write-Output 'PORTABLE_LOOP=PASS cases=8'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
