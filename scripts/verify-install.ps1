[CmdletBinding()]
param(
    [ValidateSet("Project", "User")]
    [string]$Scope = "Project",
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [string]$SkillsRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$InstallRoot = if ($Scope -eq "Project") {
    Join-Path $ProjectRoot ".ai-assistant"
} else {
    Join-Path $CodexHome "ai-assistant"
}
$HookConfigPath = if ($Scope -eq "Project") {
    Join-Path (Join-Path $ProjectRoot ".codex") "hooks.json"
} else {
    Join-Path $CodexHome "hooks.json"
}
if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    $SkillsRoot = if ($Scope -eq "Project") {
        Join-Path $ProjectRoot ".agents\skills"
    } else {
        Join-Path $env:USERPROFILE ".agents\skills"
    }
}
$ManifestPath = Join-Path $InstallRoot "install-manifest.json"
$MemoryRoot = if ($Scope -eq "Project") {
    Join-Path $ProjectRoot "memory"
} else {
    Join-Path $InstallRoot "memory"
}
if (Test-Path -LiteralPath $ManifestPath) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [string]::IsNullOrWhiteSpace([string]$manifest.install_root)) {
        $InstallRoot = [string]$manifest.install_root
        $ManifestPath = Join-Path $InstallRoot "install-manifest.json"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$manifest.hook_config)) {
        $HookConfigPath = [string]$manifest.hook_config
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$manifest.memory_root)) {
        $MemoryRoot = [string]$manifest.memory_root
    }
}
$script:Passed = 0
$script:Failed = 0

function Test-Check {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        $script:Passed++
        Write-Host "PASS: $Message" -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Get-MajorVersion {
    param([string]$Text)
    if ($Text -match '(\d+)\.') {
        return [int]$Matches[1]
    }
    return 0
}

try {
    Write-Host "Scope: $Scope" -ForegroundColor Cyan
    Write-Host "Project: $ProjectRoot"
    Write-Host "Install root: $InstallRoot"
    Write-Host "Memory root: $MemoryRoot"

    $nodeText = (& node --version 2>$null | Out-String).Trim()
    Test-Check ((Get-MajorVersion $nodeText) -ge 22) "Node.js is version 22 or newer ($nodeText)"

    $qmdText = (& qmd --version 2>$null | Out-String).Trim()
    Test-Check ($qmdText -match '2\.5\.3') "qmd is the tested version 2.5.3 ($qmdText)"

    $requiredPaths = @(
        @{ Label = "hook config"; Path = $HookConfigPath },
        @{ Label = "install manifest"; Path = $ManifestPath },
        @{ Label = "journal-stop.ps1"; Path = (Join-Path $InstallRoot "hooks\journal-stop.ps1") },
        @{ Label = "AGENTS.example.md"; Path = (Join-Path $InstallRoot "templates\AGENTS.example.md") },
        @{ Label = "portable backup runner"; Path = (Join-Path $InstallRoot "scripts\run-codex-backup.ps1") },
        @{ Label = "backup verifier"; Path = (Join-Path $InstallRoot "scripts\verify-codex-backup.ps1") },
        @{ Label = "safe restore tool"; Path = (Join-Path $InstallRoot "scripts\restore-codex-backup.ps1") },
        @{ Label = "automatic backup publisher"; Path = (Join-Path $InstallRoot "scripts\run-and-publish-codex-backup.ps1") },
        @{ Label = "memory-organizer skill"; Path = (Join-Path $SkillsRoot "memory-organizer\SKILL.md") },
        @{ Label = "student-profile-interview skill"; Path = (Join-Path $SkillsRoot "student-profile-interview\SKILL.md") },
        @{ Label = "project-capsule skill"; Path = (Join-Path $SkillsRoot "project-capsule\SKILL.md") },
        @{ Label = "memory classification index"; Path = (Join-Path $MemoryRoot "long-term\分類索引.md") }
    )
    foreach ($item in $requiredPaths) {
        Test-Check (Test-Path -LiteralPath $item.Path) "$($item.Label) exists"
    }

    if (Test-Path -LiteralPath $HookConfigPath) {
        $hookConfig = Get-Content -LiteralPath $HookConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $handlerCount = 0
        $pathsAreLocal = $true
        foreach ($event in $hookConfig.hooks.PSObject.Properties) {
            foreach ($group in @($event.Value)) {
                foreach ($hook in @($group.hooks)) {
                    $handlerCount++
                    if (-not ([string]$hook.command).Contains((Join-Path $InstallRoot "hooks"))) {
                        $pathsAreLocal = $false
                    }
                }
            }
        }
        Test-Check ($handlerCount -eq 6) "hook config contains six command handlers"
        Test-Check $pathsAreLocal "all hook commands point to the selected scope's installed hook directory"
    }

    $runtime = Join-Path $InstallRoot "qmd"
    $env:XDG_CACHE_HOME = Join-Path $runtime "cache"
    $env:XDG_CONFIG_HOME = Join-Path $runtime "config"
    $env:QMD_CONFIG_DIR = Join-Path (Join-Path $runtime "config") "qmd"
    $env:INDEX_PATH = Join-Path (Join-Path (Join-Path $runtime "cache") "qmd") "index.sqlite"

    $status = (& qmd status 2>&1 | Out-String)
    Test-Check ($LASTEXITCODE -eq 0) "qmd status completes"
    Test-Check ($status -match 'memory-longterm') "qmd status lists memory-longterm"
    Test-Check ($status -match 'Vectors:\s+[1-9]\d*') "qmd has at least one vector"
    Test-Check ($status -match 'multilingual-e5-large-instruct') "qmd uses multilingual-e5-large-instruct"

    $testRoot = Join-Path $env:TEMP ("ai-assistant-installed-check-" + [guid]::NewGuid().ToString("N"))
    $testState = Join-Path $testRoot "state"
    $testMemory = Join-Path $testRoot "memory"
    $hookRoot = Join-Path $InstallRoot "hooks"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $previousEncoding = $global:OutputEncoding
    $global:OutputEncoding = $utf8
    try {
        @{
            session_id = "verify-session"
            turn_id = "verify-turn"
            cwd = $ProjectRoot
            prompt = "主題一中文驗收"
        } | ConvertTo-Json -Compress |
            powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $hookRoot "journal-prompt.ps1") `
                -StateRoot $testState

        @{
            session_id = "verify-session"
            turn_id = "verify-turn"
            tool_name = "Bash"
            tool_use_id = "verify-tool"
        } | ConvertTo-Json -Compress |
            powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $hookRoot "journal-tool.ps1") `
                -StateRoot $testState

        $stopOutput = @{
            session_id = "verify-session"
            turn_id = "verify-turn"
            cwd = $ProjectRoot
            last_assistant_message = "主題一驗收完成。"
        } | ConvertTo-Json -Compress |
            powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $hookRoot "journal-stop.ps1") `
                -MemoryRoot $testMemory `
                -StateRoot $testState
    } finally {
        $global:OutputEncoding = $previousEncoding
    }

    $dailyPath = Join-Path (Join-Path $testMemory "daily") "$(Get-Date -Format 'yyyy-MM-dd').md"
    $dailyText = if (Test-Path -LiteralPath $dailyPath) {
        Get-Content -LiteralPath $dailyPath -Raw -Encoding UTF8
    } else {
        ""
    }
    Test-Check (($stopOutput | Out-String).Trim() -eq "{}") "Stop hook returns valid empty JSON"
    Test-Check ($dailyText -match '主題一中文驗收') "installed hooks preserve Chinese prompt text"
    Test-Check ($dailyText -match 'tools: Bash') "installed hooks record tool names"
} catch {
    $script:Failed++
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($testRoot -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "INSTALL CHECK: $script:Passed passed, $script:Failed failed" -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
