param(
    [string]$MemoryRoot = (Join-Path $env:USERPROFILE ".codex\ai-assistant\memory"),
    [string]$StateRoot = (Join-Path $env:USERPROFILE ".codex\ai-assistant\state")
)

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "common.ps1")

function Get-JournalTitle {
    param([string]$Prompt)

    $firstLine = @($Prompt -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        return "未命名對話"
    }
    $title = $firstLine.Trim()
    if ($title.Length -gt 70) {
        return $title.Substring(0, 70) + "…"
    }
    return $title
}

function ConvertTo-JournalIndentedBlock {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return "    （空白）"
    }

    return (($Text -split "`r?`n", -1) |
        ForEach-Object { "    $_" }) -join "`n"
}

try {
    $inputObject = Read-HookInput
    if ($null -eq $inputObject) {
        Write-Output "{}"
        exit 0
    }

    $sessionId = [string]$inputObject.session_id
    $turnId = [string]$inputObject.turn_id
    $safeSessionId = Get-SafeId -Value $sessionId -Fallback "session"
    $safeTurnId = Get-SafeId -Value $turnId -Fallback "turn"
    $completedDirectory = Join-Path (Join-Path $StateRoot "completed") $safeSessionId
    $completedMarker = Join-Path $completedDirectory "$safeTurnId.done"

    if (Test-Path -LiteralPath $completedMarker) {
        Write-Output "{}"
        exit 0
    }

    $turnPath = Get-TurnStatePath -StateRoot $StateRoot -SessionId $sessionId -TurnId $turnId
    if (Test-JournalTurnIgnored -TurnPath $turnPath) {
        if (-not (Test-Path -LiteralPath $completedDirectory)) {
            New-Item -ItemType Directory -Path $completedDirectory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText(
            $completedMarker,
            (Get-Date -Format "o"),
            (New-Object System.Text.UTF8Encoding($false))
        )
        Remove-Item -LiteralPath $turnPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "{}"
        exit 0
    }

    $promptPath = Join-Path $turnPath "prompt.json"
    $promptRecord = $null
    if (Test-Path -LiteralPath $promptPath) {
        $promptRecord = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    $prompt = if ($null -ne $promptRecord) {
        [string]$promptRecord.prompt
    } else {
        ""
    }
    $assistantMessage = Protect-MemoryText -Text ([string]$inputObject.last_assistant_message)

    if ([string]::IsNullOrWhiteSpace($prompt) -and [string]::IsNullOrWhiteSpace($assistantMessage)) {
        Write-Output "{}"
        exit 0
    }

    $toolNames = @()
    $toolDirectory = Join-Path $turnPath "tools"
    if (Test-Path -LiteralPath $toolDirectory) {
        $toolNames = @(Get-ChildItem -LiteralPath $toolDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).tool_name
                } catch {
                    $null
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
    }

    $entryType = if ($toolNames.Count -gt 0) { "任務" } else { "對話" }
    $now = Get-Date
    $dailyDirectory = Join-Path $MemoryRoot "daily"
    if (-not (Test-Path -LiteralPath $dailyDirectory)) {
        New-Item -ItemType Directory -Path $dailyDirectory -Force | Out-Null
    }

    $journalPath = Join-Path $dailyDirectory "$($now.ToString('yyyy-MM-dd')).md"
    $title = Get-JournalTitle -Prompt $prompt
    $cwd = if ($null -ne $promptRecord) { [string]$promptRecord.cwd } else { [string]$inputObject.cwd }
    $toolsText = if ($toolNames.Count -gt 0) { $toolNames -join ", " } else { "無" }
    $sessionIdText = if ([string]::IsNullOrWhiteSpace($sessionId)) { "未知" } else { $sessionId }
    $turnIdText = if ([string]::IsNullOrWhiteSpace($turnId)) { "未知" } else { $turnId }
    $cwdText = if ([string]::IsNullOrWhiteSpace($cwd)) { "未知" } else { $cwd }
    $rawTranscriptPath = ""
    if ($null -ne $inputObject.PSObject.Properties["transcript_path"]) {
        $rawTranscriptPath = [string]$inputObject.transcript_path
    }
    $transcriptPath = Protect-MemoryText -Text $rawTranscriptPath
    $transcriptText = if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
        "未提供"
    } else {
        $transcriptPath
    }
    $promptBlock = ConvertTo-JournalIndentedBlock -Text $prompt
    $assistantBlock = ConvertTo-JournalIndentedBlock -Text $assistantMessage
    $relativeJournalPath = "memory/daily/$($now.ToString('yyyy-MM-dd')).md"

    $entry = @(
        "",
        "## $($now.ToString('HH:mm:ss')) [$entryType] $title",
        "",
        "- [情境]",
        "  - 來源: Codex",
        "  - session_id: $sessionIdText",
        "  - turn_id: $turnIdText",
        "  - cwd: $cwdText",
        "  - 類型: $entryType",
        "  - 使用者原話:",
        $promptBlock,
        "",
        "- [動作/決策]",
        "  - 使用工具: $toolsText",
        "  - 助理最終回覆:",
        $assistantBlock,
        "",
        "- [結果]",
        "  - 本輪狀態: 已結束",
        "  - 寫入事件: Stop",
        "",
        "- [教訓] 未自動推論；由 memory-organizer 整理事件鏈時判定，避免每輪自動提取污染。",
        "",
        "- [落地]",
        "  - 日記位置: $relativeJournalPath",
        "  - 原始 transcript: $transcriptText",
        "  - 完整工具輸入與輸出: 不寫入 daily；需要時回查 transcript。",
        "",
        "- [召回鍵]",
        "  - 標題: $title",
        "  - turn_id: $turnIdText",
        "  - tools: $toolsText",
        ""
    ) -join "`n"

    $mutexName = "AI_Assistant_Journal_" + [Convert]::ToBase64String(
        (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($journalPath.ToLowerInvariant())
        )
    ).Replace("/", "_").Replace("+", "-").TrimEnd("=")

    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        if (-not $mutex.WaitOne(10000)) {
            throw "Timed out waiting for the journal write lock."
        }
        [System.IO.File]::AppendAllText(
            $journalPath,
            $entry,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } finally {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }

    if (-not (Test-Path -LiteralPath $completedDirectory)) {
        New-Item -ItemType Directory -Path $completedDirectory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText(
        $completedMarker,
        (Get-Date -Format "o"),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Remove-Item -LiteralPath $turnPath -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    Write-HookError -StateRoot $StateRoot -HookName "journal-stop" -Message $_.Exception.Message
}

Write-Output "{}"
exit 0
