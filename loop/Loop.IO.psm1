Set-StrictMode -Version Latest

function Get-NormalizedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -eq $pathRoot.Length) { return $pathRoot }
    return $full.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function ConvertTo-NativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '^[A-Za-z]:[\\/]' -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe relative path: $RelativePath"
    }
    return $RelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Test-PathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )
    $parentFull = Get-NormalizedPath -Path $Parent
    $childFull = [System.IO.Path]::GetFullPath($Child)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq [char]92) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($childFull.Equals($parentFull, $comparison)) { return $true }
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $prefix = if ($parentFull.EndsWith($separator)) { $parentFull } else { $parentFull + $separator }
    return $childFull.StartsWith($prefix, $comparison)
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}
