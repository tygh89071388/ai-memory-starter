[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,
    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,
    [string]$PortableRoot = "user/memory",
    [string[]]$RelativePath = @(),
    [switch]$Apply,
    [switch]$ReplaceExisting
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$VerifyScript = Join-Path $ScriptRoot "verify-codex-backup.ps1"

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Convert-ToSlash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace("\", "/").Trim("/")
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = Convert-ToSlash -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [System.IO.Path]::IsPathRooted($normalized) -or
        $normalized -match '(^|/)\.\.(/|$)') {
        throw "Unsafe relative path: $Path"
    }
    return $normalized
}

function Test-IsInsideOrEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidateFull = Get-FullPath -Path $Candidate
    $parentFull = Get-FullPath -Path $Parent
    if ($candidateFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return ($candidateFull + [System.IO.Path]::DirectorySeparatorChar).StartsWith(
        $parentFull + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

$BackupPath = Get-FullPath -Path $BackupPath
$DestinationRoot = Get-FullPath -Path $DestinationRoot
$PortableRoot = Assert-SafeRelativePath -Path $PortableRoot

if (-not (Test-Path -LiteralPath $BackupPath -PathType Container)) {
    throw "Backup directory does not exist: $BackupPath"
}
if (-not (Test-Path -LiteralPath $VerifyScript -PathType Leaf)) {
    $bundledVerifier = Join-Path $BackupPath "user\migration-tools\verify-codex-backup.ps1"
    if (Test-Path -LiteralPath $bundledVerifier -PathType Leaf) {
        $VerifyScript = $bundledVerifier
    } else {
        throw "Verification script is missing."
    }
}
if (Test-IsInsideOrEqual -Candidate $DestinationRoot -Parent $BackupPath) {
    throw "DestinationRoot must not be inside the backup bundle."
}
if (Test-Path -LiteralPath $DestinationRoot) {
    $destinationItem = Get-Item -LiteralPath $DestinationRoot -Force
    if (-not $destinationItem.PSIsContainer) {
        throw "DestinationRoot is not a directory: $DestinationRoot"
    }
    if (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "DestinationRoot must not be a reparse point."
    }
}

$verifyOutput = @(& $VerifyScript -BackupPath $BackupPath)
$verifiedLine = $verifyOutput |
    Where-Object { [string]$_ -like "VERIFIED_BACKUP=*" } |
    Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace([string]$verifiedLine)) {
    throw "Backup verification did not return VERIFIED_BACKUP."
}

$manifest = Get-Content -LiteralPath (
    Join-Path $BackupPath "manifest\manifest.json"
) -Raw -Encoding UTF8 | ConvertFrom-Json
$portablePrefix = $PortableRoot.TrimEnd("/") + "/"
$portableEntries = @(
    $manifest.entries |
        Where-Object { ([string]$_.relative_path).StartsWith(
            $portablePrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        ) }
)
if ($portableEntries.Count -eq 0) {
    throw "PortableRoot contains no files in this backup: $PortableRoot"
}

$requested = @(
    $RelativePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Assert-SafeRelativePath -Path $_ } |
        Select-Object -Unique
)
if ($requested.Count -gt 0) {
    $portableEntries = @(
        $portableEntries | Where-Object {
            $entryRelative = ([string]$_.relative_path).Substring($portablePrefix.Length)
            $requested -contains $entryRelative
        }
    )
    if ($portableEntries.Count -ne $requested.Count) {
        $found = @(
            $portableEntries | ForEach-Object {
                ([string]$_.relative_path).Substring($portablePrefix.Length)
            }
        )
        $missing = @($requested | Where-Object { $_ -notin $found })
        throw "Requested backup file was not found: $($missing[0])"
    }
}

$plan = New-Object System.Collections.Generic.List[object]
foreach ($entry in $portableEntries) {
    $entryRelative = ([string]$entry.relative_path).Substring($portablePrefix.Length)
    $source = Join-Path $BackupPath ([string]$entry.relative_path).Replace("/", "\")
    $destination = Join-Path $DestinationRoot $entryRelative.Replace("/", "\")
    if (-not (Test-IsInsideOrEqual -Candidate $destination -Parent $DestinationRoot)) {
        throw "Restore path escapes DestinationRoot: $entryRelative"
    }

    $status = "create"
    $currentHash = $null
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $currentHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -eq ([string]$entry.sha256).ToLowerInvariant()) {
            $status = "same"
        } else {
            $status = "conflict"
        }
    } elseif (Test-Path -LiteralPath $destination) {
        throw "Restore destination is not a file: $destination"
    }

    $plan.Add([pscustomobject]@{
        relative_path = $entryRelative
        source = $source
        destination = $destination
        expected_sha256 = ([string]$entry.sha256).ToLowerInvariant()
        current_sha256 = $currentHash
        action = $status
    })
}

$createCount = @($plan | Where-Object { $_.action -eq "create" }).Count
$sameCount = @($plan | Where-Object { $_.action -eq "same" }).Count
$conflictCount = @($plan | Where-Object { $_.action -eq "conflict" }).Count

Write-Host "Restore source: $BackupPath"
Write-Host "Portable root: $PortableRoot"
Write-Host "Destination: $DestinationRoot"
Write-Host "Create: $createCount; Same: $sameCount; Conflict: $conflictCount"
$plan | Select-Object relative_path, action | Format-Table -AutoSize | Out-Host

if (-not $Apply) {
    Write-Host "Preview only. No destination files were changed." -ForegroundColor Yellow
    Write-Output "RESTORE_PREVIEW=$DestinationRoot"
    exit 0
}
if ($conflictCount -gt 0 -and -not $ReplaceExisting) {
    throw "Restore has conflicting files. Review the preview, then use -ReplaceExisting only for confirmed damaged files."
}

$rollbackRoot = $null
$createdFiles = New-Object System.Collections.Generic.List[string]
$replacedFiles = New-Object System.Collections.Generic.List[object]
try {
    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }
    if ($conflictCount -gt 0) {
        $destinationParent = Split-Path -Parent $DestinationRoot
        $destinationName = Split-Path -Leaf $DestinationRoot
        $rollbackName = "{0}-restore-rollback-{1}-{2}" -f
            $destinationName,
            (Get-Date -Format "yyyyMMdd-HHmmss"),
            ([guid]::NewGuid().ToString("N").Substring(0, 8))
        $rollbackRoot = Join-Path $destinationParent $rollbackName
        New-Item -ItemType Directory -Path $rollbackRoot | Out-Null
    }

    foreach ($item in $plan) {
        if ($item.action -eq "same") {
            continue
        }
        $destinationParent = Split-Path -Parent $item.destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }

        if ($item.action -eq "conflict") {
            $rollbackFile = Join-Path $rollbackRoot $item.relative_path.Replace("/", "\")
            $rollbackParent = Split-Path -Parent $rollbackFile
            if (-not (Test-Path -LiteralPath $rollbackParent)) {
                New-Item -ItemType Directory -Path $rollbackParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.destination -Destination $rollbackFile
            $replacedFiles.Add([pscustomobject]@{
                destination = $item.destination
                rollback = $rollbackFile
            })
        } else {
            $createdFiles.Add($item.destination)
        }

        $temporaryFile = "$($item.destination).restore-$([guid]::NewGuid().ToString('N')).tmp"
        Copy-Item -LiteralPath $item.source -Destination $temporaryFile
        $temporaryHash = (Get-FileHash -LiteralPath $temporaryFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($temporaryHash -ne $item.expected_sha256) {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
            throw "Temporary restore hash mismatch: $($item.relative_path)"
        }
        Move-Item -LiteralPath $temporaryFile -Destination $item.destination -Force
    }

    foreach ($item in $plan) {
        $actualHash = (Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $item.expected_sha256) {
            throw "Post-restore SHA-256 mismatch: $($item.relative_path)"
        }
    }

    Write-Host "Restore completed and verified." -ForegroundColor Green
    Write-Output "RESTORED_FILES=$($createCount + $conflictCount)"
    if (-not [string]::IsNullOrWhiteSpace($rollbackRoot)) {
        Write-Output "ROLLBACK_PATH=$rollbackRoot"
    }
} catch {
    foreach ($createdFile in $createdFiles) {
        if (Test-Path -LiteralPath $createdFile -PathType Leaf) {
            Remove-Item -LiteralPath $createdFile -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($replaced in $replacedFiles) {
        if (Test-Path -LiteralPath $replaced.rollback -PathType Leaf) {
            Copy-Item -LiteralPath $replaced.rollback -Destination $replaced.destination -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}
