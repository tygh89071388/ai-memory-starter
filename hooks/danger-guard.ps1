$ErrorActionPreference = "SilentlyContinue"
$inputObject = $null

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $inputObject = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$command = [string]$inputObject.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

$dangerPatterns = @(
    '(?i)\brm\s+(?:-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*)\s+(?:/|~|\*|\.)(?:\s|$)',
    '(?i)\bRemove-Item\b(?=[^\r\n]*-Recurse\b)(?=[^\r\n]*-Force\b)(?=[^\r\n]*(?:\$env:USERPROFILE|%USERPROFILE%|[A-Za-z]:\\|[/~]))',
    '(?i)\bformat(?:\.com)?\s+[a-z]:',
    '(?i)\bdel\b(?=[^\r\n]*/[fs])(?=[^\r\n]*/q)[^\r\n]*[a-z]:\\',
    ':\(\)\s*\{\s*:\|:',
    '(?i)>\s*/dev/(?:sd[a-z]|nvme\d+n\d+)',
    '(?i)\bdd\s+[^\r\n]*\bof=/dev/(?:sd[a-z]|nvme\d+n\d+)',
    '(?i)\bmkfs(?:\.[a-z0-9_-]+)?\b',
    '(?i)\bshutdown\s+(?:/[srp]|-[hPr])',
    '(?i)\b(?:Stop-Computer|Restart-Computer)\b'
)

$matchedPattern = $null
foreach ($pattern in $dangerPatterns) {
    if ($command -match $pattern) {
        $matchedPattern = $pattern
        break
    }
}

if ($null -eq $matchedPattern) { exit 0 }

$payload = @{
    hookSpecificOutput = @{
        hookEventName = "PreToolUse"
        permissionDecision = "deny"
        permissionDecisionReason = "danger-guard blocked a high-risk command. Test the hook with simulated JSON; do not run destructive commands to verify it."
    }
} | ConvertTo-Json -Depth 5 -Compress

Write-Output $payload
exit 0
