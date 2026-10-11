[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,
    [ValidateRange(1, 8760)]
    [int]$MaxAgeHours = 30
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$VerifyScript = Join-Path $ScriptRoot "verify-codex-backup.ps1"

$DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd("\", "/")
if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
    throw "Backup destination does not exist: $DestinationRoot"
}
if (-not (Test-Path -LiteralPath $VerifyScript -PathType Leaf)) {
    throw "Verification script is missing: $VerifyScript"
}

$runStatePath = Join-Path $DestinationRoot "last-run.json"
if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
    throw "Missing last-run.json. No verified automatic backup has been recorded."
}

try {
    $state = Get-Content -LiteralPath $runStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "last-run.json is not valid JSON."
}
if ([int]$state.schema_version -ne 1) {
    throw "Unsupported last-run schema: $($state.schema_version)"
}
if ([string]$state.status -ne "verified") {
    throw "Latest automatic backup status is not verified: $($state.status)"
}
if ([string]::IsNullOrWhiteSpace([string]$state.backup_path)) {
    throw "last-run.json has no backup_path."
}

try {
    $finishedAt = [datetimeoffset]::Parse([string]$state.finished_at)
} catch {
    throw "last-run.json has an invalid finished_at timestamp."
}
$now = [datetimeoffset]::Now
if ($finishedAt -gt $now.AddMinutes(5)) {
    throw "Latest backup timestamp is unexpectedly in the future."
}
$age = $now - $finishedAt
if ($age.TotalHours -gt $MaxAgeHours) {
    throw ("Latest verified backup is stale: {0:N1} hours old (limit: {1})." -f
        $age.TotalHours, $MaxAgeHours)
}

$backupPath = [System.IO.Path]::GetFullPath([string]$state.backup_path).TrimEnd("\", "/")
$destinationPrefix = $DestinationRoot + [System.IO.Path]::DirectorySeparatorChar
$backupPrefix = $backupPath + [System.IO.Path]::DirectorySeparatorChar
if (-not $backupPrefix.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "last-run.json points outside DestinationRoot."
}
if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
    throw "Latest verified backup directory is missing: $backupPath"
}

$verifyOutput = @(& $VerifyScript -BackupPath $backupPath)
$verifyOutput | Out-Host
$verifiedLine = $verifyOutput |
    Where-Object { [string]$_ -like "VERIFIED_BACKUP=*" } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$verifiedLine)) {
    throw "Independent verification did not return VERIFIED_BACKUP."
}

Write-Host ("Backup health is good. Age: {0:N1} hours" -f $age.TotalHours) -ForegroundColor Green
Write-Output "HEALTHY_BACKUP=$backupPath"
