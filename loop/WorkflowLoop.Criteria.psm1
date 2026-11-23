Set-StrictMode -Version Latest

function Assert-WorkflowLoopString([object]$Value, [string]$Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "$Name must be a non-empty string" }
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ([char]::IsHighSurrogate($Value[$i])) {
            if ($i + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$i + 1])) { throw "$Name contains an unpaired surrogate" }
            $i++
        } elseif ([char]::IsLowSurrogate($Value[$i])) { throw "$Name contains an unpaired surrogate" }
    }
}

function Get-WorkflowLoopCriteriaCanonical {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Criteria)
    if ($Criteria.Count -eq 0) { throw 'targetCriteria must contain at least one criterion' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $projection = foreach ($criterion in $Criteria) {
        foreach ($field in @('criterionId', 'description', 'validatorRef')) {
            if ($null -eq $criterion -or $null -eq $criterion.PSObject.Properties[$field]) { throw "criterion.$field is required" }
            Assert-WorkflowLoopString $criterion.$field "criterion.$field"
        }
        if (-not $ids.Add($criterion.criterionId)) { throw "duplicate criterionId: $($criterion.criterionId)" }
        [ordered]@{ criterionId = $criterion.criterionId; description = $criterion.description; validatorRef = $criterion.validatorRef }
    }
    # JSON.stringify and ConvertTo-Json differ for these three characters.
    # Keep text as-is (no Unicode normalization), with lower-case JSON escapes.
    $canonical = ConvertTo-Json -InputObject @($projection) -Depth 10 -Compress
    return $canonical.Replace([string][char]0x85, '\u0085').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
}

function Get-WorkflowLoopCriteriaSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Criteria)
    $canonical = Get-WorkflowLoopCriteriaCanonical -Criteria $Criteria
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash([Text.UTF8Encoding]::new($false, $true).GetBytes($canonical))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

Export-ModuleMember -Function Get-WorkflowLoopCriteriaCanonical, Get-WorkflowLoopCriteriaSha256
