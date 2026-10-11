[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,
    [string]$CodexHome,
    [string]$UserSkillsRoot,
    [string[]]$ProjectRoot = @()
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupScript = Join-Path $ScriptRoot "backup-codex-portable.ps1"
$VerifyScript = Join-Path $ScriptRoot "verify-codex-backup.ps1"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $BackupScript -PathType Leaf)) {
    throw "Backup script is missing: $BackupScript"
}
if (-not (Test-Path -LiteralPath $VerifyScript -PathType Leaf)) {
    throw "Verification script is missing: $VerifyScript"
}

$DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd("\", "/")
if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
}
$RunStatePath = Join-Path $DestinationRoot "last-run.json"
$startedAt = Get-Date
$backupPath = $null

function Write-RunState {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Path,
        [string]$ErrorCode
    )
    $state = [ordered]@{
        schema_version = 1
        status = $Status
        started_at = $startedAt.ToString("o")
        finished_at = (Get-Date).ToString("o")
        backup_path = $Path
        error_code = $ErrorCode
    }
    [System.IO.File]::WriteAllText(
        $RunStatePath,
        ($state | ConvertTo-Json -Depth 4),
        $Utf8NoBom
    )
}

try {
    $arguments = @{
        DestinationRoot = $DestinationRoot
        ProjectRoot = $ProjectRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $arguments.CodexHome = $CodexHome
    }
    if (-not [string]::IsNullOrWhiteSpace($UserSkillsRoot)) {
        $arguments.UserSkillsRoot = $UserSkillsRoot
    }

    $backupOutput = @(& $BackupScript @arguments)
    $backupLine = $backupOutput |
        Where-Object { [string]$_ -like "BACKUP_PATH=*" } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace([string]$backupLine)) {
        throw "Backup script did not return BACKUP_PATH."
    }
    $backupPath = ([string]$backupLine).Substring("BACKUP_PATH=".Length)
    if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
        throw "Backup output path does not exist."
    }

    $verifyOutput = @(& $VerifyScript -BackupPath $backupPath)
    $verifyOutput | Out-Host
    $verifiedLine = $verifyOutput |
        Where-Object { [string]$_ -like "VERIFIED_BACKUP=*" } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace([string]$verifiedLine)) {
        throw "Independent verification did not return VERIFIED_BACKUP."
    }

    Write-RunState -Status "verified" -Path $backupPath -ErrorCode $null
    Write-Host "Backup and verification completed: $backupPath" -ForegroundColor Green
    Write-Output "VERIFIED_BACKUP=$backupPath"
} catch {
    $errorCode = $_.Exception.GetType().Name
    try {
        Write-RunState -Status "failed" -Path $backupPath -ErrorCode $errorCode
    } catch {
        # The original backup or verification failure is more important.
    }
    throw
}
