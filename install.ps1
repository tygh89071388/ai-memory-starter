[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("Project", "User")]
    [string]$Scope = "Project",
    [string]$ProjectRoot,
    [string]$CodexHome,
    [string]$MemoryRoot,
    [string]$SkillsRoot,
    [switch]$SkipQmd,
    [switch]$SkipEmbedding,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    # Project installs follow the caller's working directory, not the folder
    # that happens to contain this installer.
    $ProjectRoot = (Get-Location).Path
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Join-Path $env:USERPROFILE ".codex"
}

if ($Scope -eq "Project") {
    $InstallRoot = Join-Path $ProjectRoot ".ai-assistant"
    $HookConfigPath = Join-Path (Join-Path $ProjectRoot ".codex") "hooks.json"
    if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
        $MemoryRoot = Join-Path $ProjectRoot "memory"
    }
} else {
    $InstallRoot = Join-Path $CodexHome "ai-assistant"
    $HookConfigPath = Join-Path $CodexHome "hooks.json"
    if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
        $MemoryRoot = Join-Path $InstallRoot "memory"
    }
}

if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    if ($Scope -eq "User") {
        $SkillsRoot = Join-Path $env:USERPROFILE ".agents\skills"
    } else {
        $SkillsRoot = Join-Path $ProjectRoot ".agents\skills"
    }
}

$HookRoot = Join-Path $InstallRoot "hooks"
$StateRoot = Join-Path $InstallRoot "state"
$QmdCache = Join-Path (Join-Path $InstallRoot "qmd") "cache"
$QmdConfig = Join-Path (Join-Path $InstallRoot "qmd") "config"
$CourseTemplateRoot = Join-Path $InstallRoot "templates"
$InstalledScriptRoot = Join-Path $InstallRoot "scripts"
$ManifestPath = Join-Path $InstallRoot "install-manifest.json"
$Marker = "ai-assistant-starter"
$EmbedModel = "hf:Ralriki/multilingual-e5-large-instruct-GGUF/multilingual-e5-large-instruct-q8_0.gguf"

function Convert-ToCommandPath {
    param([string]$Path)
    return $Path.Replace('"', '""')
}

function New-Handler {
    param(
        [string]$ScriptName,
        [string]$Arguments,
        [string]$StatusMessage,
        [int]$Timeout
    )

    $scriptPath = Convert-ToCommandPath -Path (Join-Path $HookRoot $ScriptName)
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $command += " $Arguments"
    }

    return [ordered]@{
        type = "command"
        command = $command
        commandWindows = $command
        statusMessage = $StatusMessage
        timeout = $Timeout
    }
}

function Quote-Argument {
    param([string]$Value)
    return '"' + (Convert-ToCommandPath -Path $Value) + '"'
}

function New-StarterHookGroups {
    $memoryArg = Quote-Argument -Value $MemoryRoot
    $stateArg = Quote-Argument -Value $StateRoot
    $cacheArg = Quote-Argument -Value $QmdCache
    $configArg = Quote-Argument -Value $QmdConfig

    return [ordered]@{
        SessionStart = @(
            [ordered]@{
                matcher = "startup|resume|clear|compact"
                hooks = @(
                    (New-Handler -ScriptName "session-start.ps1" -Arguments "-MemoryRoot $memoryArg" -StatusMessage "Loading recent journal context" -Timeout 15)
                )
            }
        )
        UserPromptSubmit = @(
            [ordered]@{
                hooks = @(
                    (New-Handler -ScriptName "journal-prompt.ps1" -Arguments "-StateRoot $stateArg" -StatusMessage "Preparing journal entry" -Timeout 10),
                    (New-Handler -ScriptName "memory-recall.ps1" -Arguments "-StateRoot $stateArg -QmdCache $cacheArg -QmdConfig $configArg" -StatusMessage "Recalling related memories" -Timeout 60)
                )
            }
        )
        PostToolUse = @(
            [ordered]@{
                matcher = ".*"
                hooks = @(
                    (New-Handler -ScriptName "journal-tool.ps1" -Arguments "-StateRoot $stateArg" -StatusMessage "Recording task activity" -Timeout 10)
                )
            }
        )
        PreToolUse = @(
            [ordered]@{
                matcher = "Bash"
                hooks = @(
                    (New-Handler -ScriptName "danger-guard.ps1" -Arguments "" -StatusMessage "Checking command safety" -Timeout 5)
                )
            }
        )
        Stop = @(
            [ordered]@{
                hooks = @(
                    (New-Handler -ScriptName "journal-stop.ps1" -Arguments "-MemoryRoot $memoryArg -StateRoot $stateArg" -StatusMessage "Writing the daily journal" -Timeout 20)
                )
            }
        )
    }
}

function Read-HookConfig {
    if (-not (Test-Path -LiteralPath $HookConfigPath)) {
        return [ordered]@{
            description = "Codex user hooks"
            hooks = [ordered]@{}
        }
    }

    $parsed = Get-Content -LiteralPath $HookConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config = [ordered]@{}
    foreach ($property in $parsed.PSObject.Properties) {
        $config[$property.Name] = $property.Value
    }
    if (-not $config.Contains("hooks") -or $null -eq $config.hooks) {
        $config.hooks = [ordered]@{}
    }
    return $config
}

function Get-HookEventsAsMap {
    param([object]$HooksObject)

    $map = [ordered]@{}
    if ($HooksObject -is [System.Collections.IDictionary]) {
        foreach ($key in $HooksObject.Keys) {
            $map[$key] = @($HooksObject[$key])
        }
    } else {
        foreach ($property in $HooksObject.PSObject.Properties) {
            $map[$property.Name] = @($property.Value)
        }
    }
    return $map
}

function Test-IsStarterGroup {
    param([object]$Group)

    foreach ($handler in @($Group.hooks)) {
        $commandText = ([string]$handler.command) + " " + ([string]$handler.commandWindows)
        if ($commandText -like "*$HookRoot*") {
            return $true
        }
    }
    return $false
}

function Write-HookConfig {
    param([object]$Config)

    $parent = Split-Path -Parent $HookConfigPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText(
        $HookConfigPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Merge-StarterHooks {
    $config = Read-HookConfig
    $eventMap = Get-HookEventsAsMap -HooksObject $config.hooks
    $starterGroups = New-StarterHookGroups

    foreach ($eventName in $starterGroups.Keys) {
        $existing = @()
        if ($eventMap.Contains($eventName)) {
            $existing = @($eventMap[$eventName] | Where-Object { -not (Test-IsStarterGroup -Group $_) })
        }
        $eventMap[$eventName] = @($existing) + @($starterGroups[$eventName])
    }

    $config.hooks = $eventMap
    Write-HookConfig -Config $config
}

function Remove-StarterHooks {
    if (-not (Test-Path -LiteralPath $HookConfigPath)) {
        return
    }

    $config = Read-HookConfig
    $eventMap = Get-HookEventsAsMap -HooksObject $config.hooks
    foreach ($eventName in @($eventMap.Keys)) {
        $remaining = @($eventMap[$eventName] | Where-Object { -not (Test-IsStarterGroup -Group $_) })
        if ($remaining.Count -eq 0) {
            $eventMap.Remove($eventName)
        } else {
            $eventMap[$eventName] = $remaining
        }
    }
    $config.hooks = $eventMap
    Write-HookConfig -Config $config
}

function Copy-MissingTree {
    param(
        [string]$Source,
        [string]$Destination
    )

    Get-ChildItem -LiteralPath $Source -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart("\", "/")
        $target = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $target)) {
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $target
        }
    }
}

function Set-QmdEmbedModelConfig {
    $configPath = Join-Path (Join-Path $QmdConfig "qmd") "index.yml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return
    }

    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    if ($configText -match '(?m)^(\s*)embed:\s*.*$') {
        $configText = [regex]::Replace(
            $configText,
            '(?m)^(\s*)embed:\s*.*$',
            ('${1}embed: ' + $EmbedModel),
            1
        )
    } elseif ($configText -match '(?m)^models:\s*$') {
        $configText = [regex]::Replace(
            $configText,
            '(?m)^models:\s*$',
            ("models:`r`n  embed: " + $EmbedModel),
            1
        )
    } else {
        $configText = $configText.TrimEnd() + "`r`nmodels:`r`n  embed: $EmbedModel`r`n"
    }

    [System.IO.File]::WriteAllText(
        $configPath,
        $configText,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-QmdChecked {
    param([string[]]$Arguments)

    & qmd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "qmd command failed: qmd $($Arguments -join ' ')"
    }
}

function Initialize-Qmd {
    if ($SkipQmd) { return }

    $qmd = Get-Command qmd -ErrorAction SilentlyContinue
    if ($null -eq $qmd) {
        Write-Warning "qmd was not found. Install the pinned teaching version with: npm install -g @tobilu/qmd@2.5.3"
        return
    }

    $env:XDG_CACHE_HOME = $QmdCache
    $env:XDG_CONFIG_HOME = $QmdConfig
    $env:QMD_CONFIG_DIR = Join-Path $QmdConfig "qmd"
    $env:INDEX_PATH = Join-Path (Join-Path $QmdCache "qmd") "index.sqlite"
    $env:QMD_EMBED_MODEL = $EmbedModel

    $version = (& qmd --version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read qmd version."
    }
    if ($version -notmatch '2\.5\.3') {
        Write-Warning "This course is tested with qmd 2.5.3; detected: $version"
    }

    $collections = (& qmd collection list 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list qmd collections."
    }
    $longTermPath = Join-Path $MemoryRoot "long-term"

    if ($collections -notmatch '(?m)\bmemory-longterm\b') {
        Invoke-QmdChecked -Arguments @(
            "collection", "add", $longTermPath,
            "--name", "memory-longterm",
            "--mask", "**/*.md"
        )
    }

    Set-QmdEmbedModelConfig
    Invoke-QmdChecked -Arguments @(
        "context", "add",
        "qmd://memory-longterm",
        "Curated, durable personal memory"
    )
    Invoke-QmdChecked -Arguments @("update")
    if (-not $SkipEmbedding) {
        Write-Host "Downloading qmd models and building long-term embeddings. The first run may take several minutes."
        Invoke-QmdChecked -Arguments @("pull")
        Invoke-QmdChecked -Arguments @("embed", "-c", "memory-longterm")
    }
}

if ($Uninstall) {
    if ($PSCmdlet.ShouldProcess($HookConfigPath, "Remove AI Assistant Starter Kit hooks")) {
        Remove-StarterHooks
    }
    if ($PSCmdlet.ShouldProcess($InstallRoot, "Remove installed hook code and transient state")) {
        if (Test-Path -LiteralPath $HookRoot) {
            Remove-Item -LiteralPath $HookRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $StateRoot) {
            Remove-Item -LiteralPath $StateRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $ManifestPath) {
            Remove-Item -LiteralPath $ManifestPath -Force
        }
    }
    Write-Host "Uninstalled hook code. Memory was preserved at: $MemoryRoot" -ForegroundColor Green
    exit 0
}

if ($PSCmdlet.ShouldProcess($InstallRoot, "Install AI Assistant Starter Kit")) {
    foreach ($directory in @(
        $HookRoot,
        $StateRoot,
        $QmdCache,
        $QmdConfig,
        $CourseTemplateRoot,
        $InstalledScriptRoot,
        (Join-Path $QmdCache "qmd"),
        (Join-Path $QmdConfig "qmd"),
        (Join-Path $MemoryRoot "daily"),
        (Join-Path $MemoryRoot "long-term"),
        (Join-Path $MemoryRoot "inbox"),
        (Join-Path $MemoryRoot "archive")
    )) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    Copy-Item -Path (Join-Path $KitRoot "hooks\*.ps1") -Destination $HookRoot -Force
    Copy-Item -LiteralPath (Join-Path $KitRoot "templates\persona-template.md") -Destination $CourseTemplateRoot -Force
    Copy-Item -LiteralPath (Join-Path $KitRoot "templates\AGENTS.example.md") -Destination $CourseTemplateRoot -Force
    foreach ($scriptName in @(
        "verify-install.ps1",
        "backup-codex-portable.ps1",
        "verify-codex-backup.ps1",
        "run-codex-backup.ps1",
        "check-codex-backup-health.ps1",
        "restore-codex-backup.ps1",
        "publish-codex-backup.ps1",
        "run-and-publish-codex-backup.ps1"
    )) {
        Copy-Item -LiteralPath (Join-Path $KitRoot "scripts\$scriptName") -Destination $InstalledScriptRoot -Force
    }
    Copy-MissingTree -Source (Join-Path $KitRoot "templates\memory") -Destination $MemoryRoot

    $skillsSourceRoot = Join-Path $KitRoot ".agents\skills"
    Get-ChildItem -LiteralPath $skillsSourceRoot -Directory | ForEach-Object {
        $skillSource = $_.FullName
        $skillTarget = Join-Path $SkillsRoot $_.Name
        if (-not (Test-Path -LiteralPath $skillTarget)) {
            New-Item -ItemType Directory -Path $skillTarget -Force | Out-Null
        }
        if ([System.IO.Path]::GetFullPath($skillSource).TrimEnd("\") -ne [System.IO.Path]::GetFullPath($skillTarget).TrimEnd("\")) {
            Copy-Item -Path (Join-Path $skillSource "*") -Destination $skillTarget -Recurse -Force
        }
    }

    if (Test-Path -LiteralPath $HookConfigPath) {
        $backupPath = "$HookConfigPath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $HookConfigPath -Destination $backupPath
    }
    Merge-StarterHooks

    $manifest = [ordered]@{
        marker = $Marker
        installed_at = (Get-Date -Format "o")
        scope = $Scope
        install_root = $InstallRoot
        memory_root = $MemoryRoot
        hook_config = $HookConfigPath
        installed_skills = @(
            Get-ChildItem -LiteralPath $skillsSourceRoot -Directory | Select-Object -ExpandProperty Name
        )
    }
    [System.IO.File]::WriteAllText(
        $ManifestPath,
        ($manifest | ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false))
    )

    Initialize-Qmd
}

Write-Host ""
if ($WhatIfPreference) {
    Write-Host "AI Assistant Starter Kit preview completed. No changes were made." -ForegroundColor Yellow
    exit 0
}

Write-Host "AI Assistant Starter Kit installed." -ForegroundColor Green
Write-Host "Scope:       $Scope"
Write-Host "Hooks:       $HookConfigPath"
Write-Host "Memory:      $MemoryRoot"
Write-Host "Hook code:   $HookRoot"
Write-Host ""
Write-Host "Next: reopen this project in the Codex desktop app, review the hook trust prompt, and click trust for each handler you approve."
