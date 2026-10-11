[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,
    [string]$CodexHome,
    [string]$UserSkillsRoot,
    [string[]]$ProjectRoot = @()
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $CodexHome = $env:CODEX_HOME
    } else {
        $CodexHome = Join-Path $env:USERPROFILE ".codex"
    }
}
if ([string]::IsNullOrWhiteSpace($UserSkillsRoot)) {
    $UserSkillsRoot = Join-Path $env:USERPROFILE ".agents\skills"
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-IsInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidateFull = (Get-FullPath -Path $Candidate) + [System.IO.Path]::DirectorySeparatorChar
    $parentFull = (Get-FullPath -Path $Parent) + [System.IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)
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

function Convert-ToRelativeSlash {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace("\", "/")
}

function Get-HookCommandStrings {
    param([object]$Value)
    $results = New-Object System.Collections.Generic.List[string]

    function Visit-HookValue {
        param([object]$Current)
        if ($null -eq $Current) {
            return
        }
        if ($Current -is [string]) {
            $script:hookStringResults.Add([string]$Current)
            return
        }
        if ($Current -is [System.Collections.IDictionary]) {
            foreach ($key in $Current.Keys) {
                Visit-HookValue -Current $Current[$key]
            }
            return
        }
        if ($Current -is [System.Collections.IEnumerable] -and
            -not ($Current -is [System.Management.Automation.PSCustomObject])) {
            foreach ($item in $Current) {
                Visit-HookValue -Current $item
            }
            return
        }
        foreach ($property in $Current.PSObject.Properties) {
            Visit-HookValue -Current $property.Value
        }
    }

    $previousResults = $script:hookStringResults
    $script:hookStringResults = $results
    try {
        Visit-HookValue -Current $Value
        return @($results | ForEach-Object { $_ })
    } finally {
        $script:hookStringResults = $previousResults
    }
}

function Get-ReferencedHookScripts {
    param([Parameter(Mandatory = $true)][string]$HookConfig)
    try {
        $hookObject = Get-Content -LiteralPath $HookConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Hook configuration is not valid JSON: $HookConfig"
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $patterns = @(
        '(?i)"([A-Za-z]:\\[^"]+\.(?:ps1|py|js|mjs|cjs))"',
        "(?i)'([A-Za-z]:\\[^']+\.(?:ps1|py|js|mjs|cjs))'",
        '(?i)([A-Za-z]:\\[^\s"]+\.(?:ps1|py|js|mjs|cjs))'
    )
    foreach ($value in (Get-HookCommandStrings -Value $hookObject)) {
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($value, $pattern)) {
                $candidate = $match.Groups[1].Value
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $paths.Add((Get-FullPath -Path $candidate))
                }
            }
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Add-ReferencedHookHandlers {
    param(
        [Parameter(Mandatory = $true)][string]$HookConfig,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$KnownHandlerRoot
    )
    if (-not (Test-Path -LiteralPath $HookConfig -PathType Leaf)) {
        return
    }
    $knownRootExists = -not [string]::IsNullOrWhiteSpace($KnownHandlerRoot) -and
        (Test-Path -LiteralPath $KnownHandlerRoot -PathType Container)
    $referenceIndex = 0
    foreach ($handlerPath in (Get-ReferencedHookScripts -HookConfig $HookConfig)) {
        if (-not (Test-Path -LiteralPath $handlerPath -PathType Leaf)) {
            throw "Hook references a missing handler: $handlerPath"
        }
        if ($knownRootExists -and (Test-IsInside -Candidate $handlerPath -Parent $KnownHandlerRoot)) {
            continue
        }
        $referenceIndex++
        $targetName = "{0:d2}-{1}" -f $referenceIndex, (Split-Path -Leaf $handlerPath)
        Add-PortableSource `
            -Source $handlerPath `
            -Target "$TargetRoot/referenced/$targetName" `
            -Category "hook_handler_reference"
    }
}

$CodexHome = Get-FullPath -Path $CodexHome
$UserSkillsRoot = Get-FullPath -Path $UserSkillsRoot
$DestinationRoot = Get-FullPath -Path $DestinationRoot
$normalizedProjects = @(
    $ProjectRoot |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Get-FullPath -Path $_ } |
        Select-Object -Unique
)

$sourceRoots = @($CodexHome, $UserSkillsRoot) + $normalizedProjects
foreach ($source in $sourceRoots) {
    if (Test-IsInside -Candidate $DestinationRoot -Parent $source) {
        throw "DestinationRoot must not be inside a source root: $source"
    }
}

if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
}
if (-not (Get-Item -LiteralPath $DestinationRoot).PSIsContainer) {
    throw "DestinationRoot is not a directory: $DestinationRoot"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
$bundleName = "codex-portable-$timestamp-$suffix"
$stagingPath = Join-Path $DestinationRoot ".$bundleName.staging"
$finalPath = Join-Path $DestinationRoot $bundleName

$candidates = New-Object System.Collections.Generic.List[object]
$sourceMap = New-Object System.Collections.Generic.List[object]
$memorySourceCount = 0
$memoryFileCount = 0

function Add-PortableSource {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Category
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        return
    }

    $sourceItem = Get-Item -LiteralPath $Source -Force
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not copied automatically: $Source"
    }

    $script:sourceMap.Add([pscustomobject]@{
        category = $Category
        source = $sourceItem.FullName
        target = Convert-ToRelativeSlash -Path $Target
    })

    if ($Category -eq "memory") {
        $script:memorySourceCount++
    }

    $files = if ($sourceItem.PSIsContainer) {
        $reparseDirectory = Get-ChildItem -LiteralPath $sourceItem.FullName -Recurse -Directory -Force |
            Where-Object {
                ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            } |
            Select-Object -First 1
        if ($null -ne $reparseDirectory) {
            throw "Reparse point directories are not copied automatically: $($reparseDirectory.FullName)"
        }
        @(Get-ChildItem -LiteralPath $sourceItem.FullName -Recurse -File -Force)
    } else {
        @($sourceItem)
    }

    foreach ($file in $files) {
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not copied automatically: $($file.FullName)"
        }
        if (Test-ForbiddenName -Name $file.Name) {
            throw "Forbidden credential filename in portable source: $($file.FullName)"
        }
        $secretRule = Get-SecretRule -File $file
        if (-not [string]::IsNullOrWhiteSpace($secretRule)) {
            throw "Possible secret ($secretRule) in portable source: $($file.FullName)"
        }

        $relative = if ($sourceItem.PSIsContainer) {
            $file.FullName.Substring($sourceItem.FullName.Length).TrimStart("\", "/")
        } else {
            $file.Name
        }
        $targetRelative = if ($sourceItem.PSIsContainer) {
            Join-Path $Target $relative
        } else {
            $Target
        }
        $script:candidates.Add([pscustomobject]@{
            source = $file.FullName
            relative_path = Convert-ToRelativeSlash -Path $targetRelative
            category = $Category
        })
        if ($Category -eq "memory") {
            $script:memoryFileCount++
        }
    }
}

try {
    Add-PortableSource -Source (Join-Path $CodexHome "AGENTS.md") -Target "user/AGENTS.md" -Category "agents_guidance"
    Add-PortableSource -Source (Join-Path $CodexHome "config.toml") -Target "user/config/config.toml" -Category "config"
    Get-ChildItem -LiteralPath $CodexHome -Filter "*.config.toml" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Add-PortableSource -Source $_.FullName -Target ("user/config/" + $_.Name) -Category "config_profile"
        }
    Add-PortableSource -Source (Join-Path $CodexHome "agents") -Target "user/agents" -Category "custom_agents"
    Add-PortableSource -Source $UserSkillsRoot -Target "user/skills" -Category "skills"
    Add-PortableSource -Source (Join-Path $CodexHome "hooks.json") -Target "user/hooks/hooks.original.json" -Category "hooks_config"
    Add-PortableSource -Source (Join-Path $CodexHome "ai-assistant\hooks") -Target "user/hooks/handlers" -Category "hook_handlers"
    Add-PortableSource -Source (Join-Path $CodexHome "ai-assistant\scripts") -Target "user/migration-tools" -Category "migration_tools"
    Add-ReferencedHookHandlers `
        -HookConfig (Join-Path $CodexHome "hooks.json") `
        -TargetRoot "user/hooks" `
        -KnownHandlerRoot (Join-Path $CodexHome "ai-assistant\hooks")
    Add-PortableSource -Source (Join-Path $CodexHome "ai-assistant\memory") -Target "user/memory" -Category "memory"

    for ($index = 0; $index -lt $normalizedProjects.Count; $index++) {
        $project = $normalizedProjects[$index]
        if (-not (Test-Path -LiteralPath $project -PathType Container)) {
            throw "ProjectRoot does not exist: $project"
        }
        $targetRoot = "projects/project-{0:d2}" -f ($index + 1)
        Add-PortableSource -Source (Join-Path $project "AGENTS.md") -Target "$targetRoot/AGENTS.md" -Category "agents_guidance"
        Add-PortableSource -Source (Join-Path $project ".agents\skills") -Target "$targetRoot/skills" -Category "skills"
        Add-PortableSource -Source (Join-Path $project ".codex\config.toml") -Target "$targetRoot/codex-config/config.toml" -Category "config"
        Add-PortableSource -Source (Join-Path $project ".codex\hooks.json") -Target "$targetRoot/hooks/hooks.original.json" -Category "hooks_config"
        Add-PortableSource -Source (Join-Path $project ".ai-assistant\hooks") -Target "$targetRoot/hooks/handlers" -Category "hook_handlers"
        Add-PortableSource -Source (Join-Path $project ".ai-assistant\scripts") -Target "$targetRoot/migration-tools" -Category "migration_tools"
        Add-ReferencedHookHandlers `
            -HookConfig (Join-Path $project ".codex\hooks.json") `
            -TargetRoot "$targetRoot/hooks" `
            -KnownHandlerRoot (Join-Path $project ".ai-assistant\hooks")
        Add-PortableSource -Source (Join-Path $project "memory") -Target "$targetRoot/memory" -Category "memory"
    }

    if ($memorySourceCount -eq 0) {
        throw "No User or Project memory directory was found. Nothing useful to back up."
    }
    if ($memoryFileCount -eq 0) {
        throw "Memory directories exist, but they contain no files."
    }
    if ($candidates.Count -eq 0) {
        throw "No portable files were found."
    }

    $duplicateTargets = @(
        $candidates |
            Group-Object -Property relative_path |
            Where-Object { $_.Count -gt 1 }
    )
    if ($duplicateTargets.Count -gt 0) {
        throw "Two source files map to the same portable path: $($duplicateTargets[0].Name)"
    }

    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    foreach ($candidate in $candidates) {
        $destination = Join-Path $stagingPath $candidate.relative_path.Replace("/", "\")
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $candidate.source -Destination $destination
    }

    $restoreReadme = @"
# Codex portable backup

Created: $(Get-Date -Format "o")

This bundle contains portable user-owned Codex files. It intentionally excludes
authentication, credential stores, SQLite state, caches, logs, qmd indexes,
models, plugin caches, sessions, and worktrees.

Restore into a new test location first. Merge config files, rebuild absolute
hook paths, reinstall external tools, rebuild qmd, and review/trust hooks again.
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $stagingPath "README-RESTORE.md"),
        $restoreReadme,
        $Utf8NoBom
    )

    $payloadFiles = @(
        Get-ChildItem -LiteralPath $stagingPath -Recurse -File -Force |
            Where-Object {
                $_.FullName -notlike (Join-Path $stagingPath "manifest\*")
            } |
            Sort-Object -Property FullName
    )
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in $payloadFiles) {
        $relative = Convert-ToRelativeSlash -Path (
            $file.FullName.Substring($stagingPath.Length).TrimStart("\", "/")
        )
        $entries.Add([pscustomobject]@{
            relative_path = $relative
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }

    $manifestRoot = Join-Path $stagingPath "manifest"
    New-Item -ItemType Directory -Path $manifestRoot | Out-Null
    $manifest = [ordered]@{
        schema_version = 1
        created_at = (Get-Date -Format "o")
        bundle_name = $bundleName
        source_codex_home = $CodexHome
        source_user_skills = $UserSkillsRoot
        project_roots = $normalizedProjects
        source_map = @($sourceMap | ForEach-Object { $_ })
        entries = @($entries | ForEach-Object { $_ })
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $manifestRoot "manifest.json"),
        ($manifest | ConvertTo-Json -Depth 8),
        $Utf8NoBom
    )

    $hashLines = @(
        $entries | ForEach-Object { "$($_.sha256)  $($_.relative_path)" }
    )
    [System.IO.File]::WriteAllLines(
        (Join-Path $manifestRoot "hashes.sha256"),
        $hashLines,
        $Utf8NoBom
    )

    $versionLines = New-Object System.Collections.Generic.List[string]
    foreach ($commandName in @("codex", "qmd", "node", "git", "powershell")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            $versionLines.Add("$commandName`tNOT_FOUND")
            continue
        }
        try {
            $versionOutput = if ($commandName -eq "powershell") {
                & $command.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            } else {
                & $command.Source --version 2>$null
            }
            $versionLines.Add("$commandName`t$([string]($versionOutput | Select-Object -First 1))")
        } catch {
            $versionLines.Add("$commandName`tVERSION_CHECK_FAILED")
        }
    }
    [System.IO.File]::WriteAllLines(
        (Join-Path $manifestRoot "versions.txt"),
        $versionLines,
        $Utf8NoBom
    )

    $pluginRoot = Join-Path $CodexHome "plugins"
    $pluginLines = if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
        @(
            Get-ChildItem -LiteralPath $pluginRoot -Directory -Force |
                Select-Object -ExpandProperty Name |
                Sort-Object
        )
    } else {
        @("NONE_FOUND")
    }
    [System.IO.File]::WriteAllLines(
        (Join-Path $manifestRoot "plugins.txt"),
        $pluginLines,
        $Utf8NoBom
    )

    $environmentNames = @(
        Get-ChildItem Env: |
            Where-Object {
                $_.Name -match '^(CODEX|QMD|XDG_|INDEX_PATH|OPENAI|GITHUB|GH_)'
            } |
            Select-Object -ExpandProperty Name |
            Sort-Object -Unique
    )
    [System.IO.File]::WriteAllLines(
        (Join-Path $manifestRoot "environment-variable-names.txt"),
        $environmentNames,
        $Utf8NoBom
    )

    Move-Item -LiteralPath $stagingPath -Destination $finalPath
    Write-Host "Portable backup created: $finalPath" -ForegroundColor Green
    Write-Output "BACKUP_PATH=$finalPath"
} catch {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
