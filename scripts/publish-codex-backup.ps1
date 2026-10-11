[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedOwner,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedGitName,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedGitEmail,
    [string]$ExpectedBranch = "main",
    [switch]$Push
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$VerifyScript = Join-Path $ScriptRoot "verify-codex-backup.ps1"

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )
    $previousLocation = Get-Location
    $previousPreference = $ErrorActionPreference
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Set-Location -LiteralPath $WorkingDirectory
        }
        $ErrorActionPreference = "Continue"
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Set-Location -LiteralPath $previousLocation
    }
    if ($exitCode -ne 0) {
        $summary = [string](($output | Select-Object -First 5) -join " ")
        throw "$Command failed with exit code $exitCode. $summary"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-StatusPath {
    param([Parameter(Mandatory = $true)][string]$Line)
    if ($Line.Length -lt 4) {
        throw "Unexpected git status line."
    }
    $path = $Line.Substring(3).Trim()
    if ($path.StartsWith('"') -and $path.EndsWith('"')) {
        throw "Quoted git paths are not supported by this safety check: $path"
    }
    if ($path -match ' -> ') {
        throw "Renames are not allowed in the backup repository preflight."
    }
    return $path.Replace("\", "/")
}

$RepositoryRoot = Get-FullPath -Path $RepositoryRoot
$BackupPath = Get-FullPath -Path $BackupPath
if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "RepositoryRoot does not exist: $RepositoryRoot"
}
if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    throw "BackupPath does not exist: $BackupPath"
}
if ((Split-Path -Parent $BackupPath) -ne $RepositoryRoot) {
    throw "BackupPath must be a direct child of RepositoryRoot."
}
if (-not (Test-Path -LiteralPath $VerifyScript -PathType Leaf)) {
    throw "Verification script is missing: $VerifyScript"
}
foreach ($commandName in @("git", "gh")) {
    if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw "Required command is missing: $commandName"
    }
}

$verifyOutput = @(& $VerifyScript -BackupPath $BackupPath)
$verifiedLine = $verifyOutput |
    Where-Object { [string]$_ -like "VERIFIED_BACKUP=*" } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$verifiedLine)) {
    throw "Backup verification did not return VERIFIED_BACKUP."
}

$runStatePath = Join-Path $RepositoryRoot "last-run.json"
if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
    throw "Missing last-run.json."
}
$runState = Get-Content -LiteralPath $runStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$runState.status -ne "verified") {
    throw "last-run.json is not verified."
}
if ((Get-FullPath -Path ([string]$runState.backup_path)) -ne $BackupPath) {
    throw "last-run.json does not point to BackupPath."
}

$gitTop = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "rev-parse", "--show-toplevel"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
if ((Get-FullPath -Path $gitTop) -ne $RepositoryRoot) {
    throw "RepositoryRoot is not the Git top-level directory."
}

$branch = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "branch", "--show-current"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
if ($branch -ne $ExpectedBranch) {
    throw "Unexpected branch. Expected $ExpectedBranch, got $branch."
}

Invoke-NativeChecked -Command "gh" -Arguments @(
    "auth", "status", "--active", "--hostname", "github.com"
) -WorkingDirectory $RepositoryRoot | Out-Null
$activeAccount = [string]((Invoke-NativeChecked -Command "gh" -Arguments @(
    "api", "user", "--jq", ".login"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
if ($activeAccount -ne $ExpectedOwner) {
    throw "Active GitHub account mismatch. Expected $ExpectedOwner, got $activeAccount."
}

$repoJson = [string]((Invoke-NativeChecked -Command "gh" -Arguments @(
    "repo", "view", "--json", "nameWithOwner,visibility,isPrivate,owner,url"
) -WorkingDirectory $RepositoryRoot) -join "`n")
$repoInfo = $repoJson | ConvertFrom-Json
if (-not [bool]$repoInfo.isPrivate -or [string]$repoInfo.visibility -ne "PRIVATE") {
    throw "Backup repository must be Private."
}
if ([string]$repoInfo.owner.login -ne $ExpectedOwner) {
    throw "Repository owner mismatch. Expected $ExpectedOwner, got $($repoInfo.owner.login)."
}
if (-not ([string]$repoInfo.nameWithOwner).StartsWith(
    "$ExpectedOwner/",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Repository is not owned by the expected account."
}

$gitName = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "config", "user.name"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
$gitEmail = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "config", "user.email"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
if ($gitName -ne $ExpectedGitName -or $gitEmail -ne $ExpectedGitEmail) {
    throw "Git author mismatch. Expected '$ExpectedGitName <$ExpectedGitEmail>', got '$gitName <$gitEmail>'."
}

$preExistingStaged = @(
    Invoke-NativeChecked -Command "git" -Arguments @(
        "diff", "--cached", "--name-only"
    ) -WorkingDirectory $RepositoryRoot |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($preExistingStaged.Count -gt 0) {
    throw "Backup repository already has staged changes. Refusing to mix them into an automatic commit."
}

Invoke-NativeChecked -Command "git" -Arguments @(
    "fetch", "--quiet", "origin", $ExpectedBranch
) -WorkingDirectory $RepositoryRoot | Out-Null
$syncCounts = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "rev-list", "--left-right", "--count", "origin/$ExpectedBranch...HEAD"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
$syncParts = @($syncCounts -split '\s+')
if ($syncParts.Count -lt 2 -or $syncParts[0] -ne "0" -or $syncParts[1] -ne "0") {
    throw "Local backup repository is not synchronized with origin/$ExpectedBranch. Refusing automatic merge, pull, reset, or force-push."
}

$bundleName = Split-Path -Leaf $BackupPath
$allowedPrefix = "$bundleName/"
$statusLines = @(
    Invoke-NativeChecked -Command "git" -Arguments @(
        "-c", "core.quotepath=false",
        "status", "--porcelain=v1", "--untracked-files=all"
    ) -WorkingDirectory $RepositoryRoot |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($statusLines.Count -eq 0) {
    throw "There are no backup changes to publish."
}

$changedPaths = New-Object System.Collections.Generic.List[string]
foreach ($line in $statusLines) {
    $path = Get-StatusPath -Line $line
    if ($path -ne "last-run.json" -and
        -not $path.StartsWith($allowedPrefix, [System.StringComparison]::Ordinal)) {
        throw "Unrelated change in backup repository: $path"
    }
    $changedPaths.Add($path)
}

Write-Host "GitHub account: $activeAccount"
Write-Host "Repository: $($repoInfo.nameWithOwner)"
Write-Host "Visibility: $($repoInfo.visibility)"
Write-Host "Branch: $branch"
Write-Host "Author: $gitName <$gitEmail>"
Write-Host "Verified bundle: $bundleName"
Write-Host "Pending paths:"
$changedPaths | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }

if (-not $Push) {
    Write-Host "Preview only. Nothing was staged, committed, or pushed." -ForegroundColor Yellow
    Write-Output "PUBLISH_PREVIEW=$BackupPath"
    exit 0
}

Invoke-NativeChecked -Command "git" -Arguments @(
    "add", "--", "last-run.json", $bundleName
) -WorkingDirectory $RepositoryRoot | Out-Null

$stagedPaths = @(
    Invoke-NativeChecked -Command "git" -Arguments @(
        "-c", "core.quotepath=false",
        "diff", "--cached", "--name-only"
    ) -WorkingDirectory $RepositoryRoot |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
if ($stagedPaths.Count -eq 0) {
    throw "Explicit staging produced no changes."
}
foreach ($path in $stagedPaths) {
    $normalized = $path.Replace("\", "/")
    if ($normalized -ne "last-run.json" -and
        -not $normalized.StartsWith($allowedPrefix, [System.StringComparison]::Ordinal)) {
        throw "Unexpected staged path: $normalized"
    }
}
$commitMessage = "Codex portable backup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Invoke-NativeChecked -Command "git" -Arguments @(
    "commit", "-m", $commitMessage
) -WorkingDirectory $RepositoryRoot | Out-Null
$localSha = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "rev-parse", "HEAD"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))

Invoke-NativeChecked -Command "git" -Arguments @(
    "push", "origin", "HEAD:refs/heads/$ExpectedBranch"
) -WorkingDirectory $RepositoryRoot | Out-Null
$remoteLine = [string]((Invoke-NativeChecked -Command "git" -Arguments @(
    "ls-remote", "origin", "refs/heads/$ExpectedBranch"
) -WorkingDirectory $RepositoryRoot | Select-Object -First 1))
$remoteSha = @($remoteLine -split '\s+')[0]
if ($remoteSha -ne $localSha) {
    throw "Remote SHA does not match the local commit."
}

Write-Host "Backup pushed and verified on origin: $localSha" -ForegroundColor Green
Write-Output "PUSHED_COMMIT=$localSha"
