[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedOwner,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedGitName,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedGitEmail,
    [string]$ExpectedBranch = "main",
    [string]$CodexHome,
    [string]$UserSkillsRoot,
    [string[]]$ProjectRoot = @()
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupRunner = Join-Path $ScriptRoot "run-codex-backup.ps1"
$Publisher = Join-Path $ScriptRoot "publish-codex-backup.ps1"

if (-not (Test-Path -LiteralPath $BackupRunner -PathType Leaf)) {
    throw "Backup runner is missing: $BackupRunner"
}
if (-not (Test-Path -LiteralPath $Publisher -PathType Leaf)) {
    throw "Backup publisher is missing: $Publisher"
}

$backupArguments = @{
    DestinationRoot = $RepositoryRoot
    ProjectRoot = $ProjectRoot
}
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
    $backupArguments.CodexHome = $CodexHome
}
if (-not [string]::IsNullOrWhiteSpace($UserSkillsRoot)) {
    $backupArguments.UserSkillsRoot = $UserSkillsRoot
}

$backupOutput = @(& $BackupRunner @backupArguments)
$verifiedLine = $backupOutput |
    Where-Object { [string]$_ -like "VERIFIED_BACKUP=*" } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$verifiedLine)) {
    throw "Backup runner did not return VERIFIED_BACKUP."
}
$backupPath = ([string]$verifiedLine).Substring("VERIFIED_BACKUP=".Length)

$publishOutput = @(& $Publisher `
    -RepositoryRoot $RepositoryRoot `
    -BackupPath $backupPath `
    -ExpectedOwner $ExpectedOwner `
    -ExpectedGitName $ExpectedGitName `
    -ExpectedGitEmail $ExpectedGitEmail `
    -ExpectedBranch $ExpectedBranch `
    -Push)
$pushedLine = $publishOutput |
    Where-Object { [string]$_ -like "PUSHED_COMMIT=*" } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$pushedLine)) {
    throw "Backup publisher did not return PUSHED_COMMIT."
}

Write-Host "Automatic backup, verification, commit, push, and remote SHA check completed." -ForegroundColor Green
Write-Output $pushedLine
