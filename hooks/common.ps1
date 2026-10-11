Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $script:Utf8NoBom
[Console]::OutputEncoding = $script:Utf8NoBom
$global:OutputEncoding = $script:Utf8NoBom

function Read-HookInput {
    $inputStream = [Console]::OpenStandardInput()
    $buffer = New-Object System.IO.MemoryStream
    try {
        $inputStream.CopyTo($buffer)
        $raw = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray()).TrimStart([char]0xFEFF)
    } finally {
        $buffer.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-SafeId {
    param(
        [AllowNull()]
        [string]$Value,
        [string]$Fallback = "unknown"
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Fallback
    }

    return [regex]::Replace($Value, '[^a-zA-Z0-9._-]', '_')
}

function Get-TurnStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [AllowNull()][string]$SessionId,
        [AllowNull()][string]$TurnId
    )

    $safeSession = Get-SafeId -Value $SessionId -Fallback "session"
    $safeTurn = Get-SafeId -Value $TurnId -Fallback "turn"
    return Join-Path (Join-Path (Join-Path $StateRoot "turns") $safeSession) $safeTurn
}

function Test-CodexBackgroundSuggestionPrompt {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $normalized = $Text.TrimStart()
    if (-not $normalized.StartsWith("# Overview", [System.StringComparison]::Ordinal)) {
        return $false
    }

    $requiredMarkers = @(
        "Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex",
        "Recent Codex tasks in this project:",
        "# Response format"
    )
    foreach ($marker in $requiredMarkers) {
        if ($normalized.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
            return $false
        }
    }

    return $true
}

function Get-JournalIgnoreMarkerPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TurnPath
    )

    return Join-Path $TurnPath "journal-ignore.json"
}

function Set-JournalTurnIgnored {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TurnPath,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $marker = @{
        reason = $Reason
        ignored_at = (Get-Date -Format "o")
    }
    Write-JsonFileAtomic -Path (Get-JournalIgnoreMarkerPath -TurnPath $TurnPath) -Value $marker
}

function Test-JournalTurnIgnored {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TurnPath
    )

    return Test-Path -LiteralPath (Get-JournalIgnoreMarkerPath -TurnPath $TurnPath)
}

function Protect-MemoryText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ""
    }

    $protected = $Text
    $patterns = @(
        '(?i)\b(sk-[a-zA-Z0-9_-]{16,})\b',
        '(?i)\b(gh[pousr]_[a-zA-Z0-9]{20,})\b',
        '(?i)\b(Bearer\s+)[a-zA-Z0-9._~+/-]{16,}=*\b',
        '(?i)\b(api[_-]?key|token|password|passwd|secret)\s*[:=]\s*["'']?([^\s"'']{8,})'
    )

    foreach ($pattern in $patterns) {
        if ($pattern -like '*api*key*' -or $pattern -like '*password*') {
            $protected = [regex]::Replace(
                $protected,
                $pattern,
                '$1=[REDACTED]'
            )
        } elseif ($pattern -like '*Bearer*') {
            $protected = [regex]::Replace(
                $protected,
                $pattern,
                '$1[REDACTED]'
            )
        } else {
            $protected = [regex]::Replace(
                $protected,
                $pattern,
                '[REDACTED]'
            )
        }
    }

    return $protected
}

function Write-HookError {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$HookName,
        [Parameter(Mandatory = $true)][string]$Message
    )

    try {
        if (-not (Test-Path -LiteralPath $StateRoot)) {
            New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
        }
        $line = "{0}`t{1}`t{2}`n" -f (Get-Date -Format "o"), $HookName, $Message
        [System.IO.File]::AppendAllText(
            (Join-Path $StateRoot "hook-errors.log"),
            $line,
            (New-Object System.Text.UTF8Encoding($false))
        )
    } catch {
        # Hook diagnostics must never block the Codex turn.
    }
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText(
        $tempPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}
