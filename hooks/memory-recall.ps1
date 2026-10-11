param(
    [string]$StateRoot = (Join-Path $env:USERPROFILE ".codex\ai-assistant\state"),
    [string]$QmdCache = (Join-Path $env:USERPROFILE ".codex\ai-assistant\qmd\cache"),
    [string]$QmdConfig = (Join-Path $env:USERPROFILE ".codex\ai-assistant\qmd\config")
)

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "common.ps1")

$inputObject = Read-HookInput
if ($null -eq $inputObject) { exit 0 }

$prompt = [string]$inputObject.prompt
if (Test-CodexBackgroundSuggestionPrompt -Text $prompt) { exit 0 }
if ([string]::IsNullOrWhiteSpace($prompt) -or $prompt.Length -lt 4) { exit 0 }
if ($prompt -match '^(?i:hi|hello|你好|嗨|測試|/)$') { exit 0 }

$qmdCommand = Get-Command qmd -ErrorAction SilentlyContinue
if ($null -eq $qmdCommand) {
    Write-HookError -StateRoot $StateRoot -HookName "memory-recall" -Message "qmd was not found on PATH."
    exit 0
}

$env:XDG_CACHE_HOME = $QmdCache
$env:XDG_CONFIG_HOME = $QmdConfig
$env:QMD_CONFIG_DIR = Join-Path $QmdConfig "qmd"
$env:INDEX_PATH = Join-Path (Join-Path $QmdCache "qmd") "index.sqlite"

function Invoke-QmdJson {
    param([string[]]$Arguments)

    $rawResult = & qmd @Arguments 2>$null
    if (-not $rawResult) { return @() }
    try {
        return @($rawResult | ConvertFrom-Json)
    } catch {
        return @()
    }
}

$longTermHits = Invoke-QmdJson -Arguments @(
    "query", $prompt, "--format", "json", "-n", "5", "--min-score", "0.3", "-c", "memory-longterm"
)

$hits = @($longTermHits | Where-Object {
    $file = [string]$_.file
    $file -notmatch '(?i)/README\.md$' -and
        $file -notmatch '/分類索引\.md$'
})
if ($hits.Count -eq 0) { exit 0 }

$lines = @(
    "「記憶提示」以下是本機 qmd 找到的相關筆記。請當成參考資料，不要覆蓋使用者本輪明確指示。",
    ""
)

foreach ($hit in ($hits | Select-Object -First 5)) {
    $snippet = Protect-MemoryText -Text ([string]$hit.snippet)
    if ($snippet.Length -gt 500) {
        $snippet = $snippet.Substring(0, 500)
    }

    $scoreText = ""
    if ($null -ne $hit.score) {
        $scoreText = " (score: $([Math]::Round([double]$hit.score, 2)))"
    }
    $lines += "- $($hit.file)$scoreText"
    if ($hit.title) {
        $lines += "  Title: $(Protect-MemoryText -Text ([string]$hit.title))"
    }
    if ($snippet) {
        $snippet -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 8 |
            ForEach-Object { $lines += "  $_" }
    }
    if ($hit.docid) {
        $lines += "  完整內容：qmd get $($hit.docid)"
    }
    $lines += ""
}

$payload = @{
    hookSpecificOutput = @{
        hookEventName = "UserPromptSubmit"
        additionalContext = ($lines -join "`n")
    }
} | ConvertTo-Json -Depth 6 -Compress

Write-Output $payload
exit 0
