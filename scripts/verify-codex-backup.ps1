[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath
)

$ErrorActionPreference = "Stop"

function Convert-ToRelativeSlash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace("\", "/")
}

function Test-ForbiddenName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $lower = $Name.ToLowerInvariant()
    if ($lower -in @(
        "auth.json",
        ".env",
        ".env.local",
        ".env.production",
        ".env.development"
    )) {
        return $true
    }
    return $lower -match '\.(pem|key|pfx|p12|keystore)$'
}

function Get-SecretRule {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)
    $textExtensions = @(
        ".md", ".txt", ".json", ".jsonl", ".toml", ".yml", ".yaml",
        ".ps1", ".psm1", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx",
        ".xml", ".ini", ".config"
    )
    if ($File.Extension.ToLowerInvariant() -notin $textExtensions) {
        return $null
    }
    if ($File.Length -gt 10MB) {
        return $null
    }

    $content = [System.IO.File]::ReadAllText($File.FullName)
    $rules = [ordered]@{
        private_key = '-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----'
        github_token = '(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'
        openai_key = '(?:sk-[A-Za-z0-9_-]{20,})'
        aws_access_key = '(?:AKIA[0-9A-Z]{16})'
        bearer_token = '(?i)Authorization\s*[:=]\s*Bearer\s+[A-Za-z0-9._~+/\-=]{16,}'
    }
    foreach ($rule in $rules.GetEnumerator()) {
        if ($content -match $rule.Value) {
            return $rule.Key
        }
    }
    return $null
}

$BackupPath = [System.IO.Path]::GetFullPath($BackupPath).TrimEnd("\", "/")
if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    throw "Backup directory does not exist: $BackupPath"
}

$manifestPath = Join-Path $BackupPath "manifest\manifest.json"
$hashListPath = Join-Path $BackupPath "manifest\hashes.sha256"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Missing manifest: $manifestPath"
}
if (-not (Test-Path -LiteralPath $hashListPath -PathType Leaf)) {
    throw "Missing hash list: $hashListPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$manifest.schema_version -ne 1) {
    throw "Unsupported manifest schema: $($manifest.schema_version)"
}

$expected = @($manifest.entries)
if ($expected.Count -eq 0) {
    throw "Manifest has no payload entries."
}
if (@($expected | Where-Object { $_.relative_path -match '(^|/)memory/' }).Count -eq 0) {
    throw "Manifest contains no memory payload."
}

$expectedByPath = @{}
foreach ($entry in $expected) {
    $relative = [string]$entry.relative_path
    if ([string]::IsNullOrWhiteSpace($relative) -or
        [System.IO.Path]::IsPathRooted($relative) -or
        $relative -match '(^|/)\.\.(/|$)') {
        throw "Unsafe relative path in manifest: $relative"
    }
    if ($expectedByPath.ContainsKey($relative)) {
        throw "Duplicate relative path in manifest: $relative"
    }
    $expectedByPath[$relative] = $entry
}

$payloadFiles = @(
    Get-ChildItem -LiteralPath $BackupPath -Recurse -File -Force |
        Where-Object {
            $_.FullName -notlike (Join-Path $BackupPath "manifest\*")
        }
)
$reparseDirectory = Get-ChildItem -LiteralPath $BackupPath -Recurse -Directory -Force |
    Where-Object {
        ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    } |
    Select-Object -First 1
if ($null -ne $reparseDirectory) {
    throw "Reparse point directory found in backup: $($reparseDirectory.FullName)"
}
$actualByPath = @{}
foreach ($file in $payloadFiles) {
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point found in backup: $($file.FullName)"
    }
    if (Test-ForbiddenName -Name $file.Name) {
        throw "Forbidden credential filename in backup: $($file.FullName)"
    }
    $secretRule = Get-SecretRule -File $file
    if (-not [string]::IsNullOrWhiteSpace($secretRule)) {
        throw "Possible secret ($secretRule) in backup file: $($file.FullName)"
    }
    $relative = Convert-ToRelativeSlash -Path (
        $file.FullName.Substring($BackupPath.Length).TrimStart("\", "/")
    )
    $actualByPath[$relative] = $file
}

$missing = @($expectedByPath.Keys | Where-Object { -not $actualByPath.ContainsKey($_) })
$extra = @($actualByPath.Keys | Where-Object { -not $expectedByPath.ContainsKey($_) })
if ($missing.Count -gt 0) {
    throw "Missing payload file: $($missing[0])"
}
if ($extra.Count -gt 0) {
    throw "Unexpected payload file: $($extra[0])"
}

foreach ($relative in $expectedByPath.Keys) {
    $entry = $expectedByPath[$relative]
    $file = $actualByPath[$relative]
    if ([int64]$entry.size -ne [int64]$file.Length) {
        throw "Size mismatch: $relative"
    }
    $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "SHA-256 mismatch: $relative"
    }
}

$hashLines = @(
    Get-Content -LiteralPath $hashListPath -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($hashLines.Count -ne $expected.Count) {
    throw "hashes.sha256 entry count does not match manifest."
}
foreach ($line in $hashLines) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
        throw "Invalid hashes.sha256 line."
    }
    $hash = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2]
    if (-not $expectedByPath.ContainsKey($relative)) {
        throw "hashes.sha256 contains an unknown path: $relative"
    }
    if ($hash -ne ([string]$expectedByPath[$relative].sha256).ToLowerInvariant()) {
        throw "hashes.sha256 disagrees with manifest: $relative"
    }
}

$hookConfigs = @(
    $payloadFiles | Where-Object { $_.Name -eq "hooks.original.json" }
)
foreach ($hookConfig in $hookConfigs) {
    try {
        Get-Content -LiteralPath $hookConfig.FullName -Raw -Encoding UTF8 |
            ConvertFrom-Json | Out-Null
    } catch {
        throw "Hook configuration is not valid JSON: $($hookConfig.FullName)"
    }
}

Write-Host "Backup verified: $BackupPath" -ForegroundColor Green
Write-Host "Payload files: $($expected.Count)"
Write-Output "VERIFIED_BACKUP=$BackupPath"
