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

    if (Test-JournalTurnIgnored -TurnPath $turnPath) {
        exit 0
    }

    $toolDirectory = Join-Path $turnPath "tools"
    $toolUseId = Get-SafeId -Value ([string]$inputObject.tool_use_id) -Fallback ([guid]::NewGuid().ToString("N"))
    $marker = @{
        tool_use_id = [string]$inputObject.tool_use_id
        tool_name = [string]$inputObject.tool_name
        recorded_at = (Get-Date -Format "o")
    }

    Write-JsonFileAtomic -Path (Join-Path $toolDirectory "$toolUseId.json") -Value $marker
} catch {
    Write-HookError -StateRoot $StateRoot -HookName "journal-tool" -Message $_.Exception.Message
}

exit 0
