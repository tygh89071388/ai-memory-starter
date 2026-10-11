param(
    [string]$StateRoot = (Join-Path $env:USERPROFILE ".codex\ai-assistant\state")
)

$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "common.ps1")

try {
    $inputObject = Read-HookInput
    if ($null -eq $inputObject) { exit 0 }

    $turnPath = Get-TurnStatePath `
        -StateRoot $StateRoot `
        -SessionId ([string]$inputObject.session_id) `
        -TurnId ([string]$inputObject.turn_id)

    $rawPrompt = [string]$inputObject.prompt
    if (Test-CodexBackgroundSuggestionPrompt -Text $rawPrompt) {
        Set-JournalTurnIgnored `
            -TurnPath $turnPath `
            -Reason "codex-background-suggestions"
        exit 0
    }

    $promptPath = Join-Path $turnPath "prompt.json"
    $promptParts = @()
    if (Test-Path -LiteralPath $promptPath) {
        try {
            $previous = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $previous.prompts) {
                $promptParts = @($previous.prompts | ForEach-Object { [string]$_ })
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$previous.prompt)) {
                $promptParts = @([string]$previous.prompt)
            }
        } catch {
            $promptParts = @()
        }
    }

    $newPrompt = Protect-MemoryText -Text $rawPrompt
    if (-not [string]::IsNullOrWhiteSpace($newPrompt)) {
        if ($promptParts.Count -eq 0 -or $promptParts[-1] -ne $newPrompt) {
            $promptParts += $newPrompt
        }
    }

    $pending = @{
        session_id = [string]$inputObject.session_id
        turn_id = [string]$inputObject.turn_id
        cwd = [string]$inputObject.cwd
        prompt = $promptParts -join "`n`n--- 追加訊息 ---`n`n"
        prompts = $promptParts
        captured_at = (Get-Date -Format "o")
    }

    Write-JsonFileAtomic -Path $promptPath -Value $pending
} catch {
    Write-HookError -StateRoot $StateRoot -HookName "journal-prompt" -Message $_.Exception.Message
}

exit 0
