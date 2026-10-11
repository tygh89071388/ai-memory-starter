param(
    [string]$MemoryRoot = (Join-Path $env:USERPROFILE ".codex\ai-assistant\memory")
)

$ErrorActionPreference = "SilentlyContinue"
[Console]::In.ReadToEnd() | Out-Null

$todayDate = Get-Date
$today = $todayDate.ToString("yyyy-MM-dd")
$weekdayNames = @("日", "一", "二", "三", "四", "五", "六")
$weekday = $weekdayNames[[int]$todayDate.DayOfWeek]

$output = @("[今日日期] $today (星期$weekday)")

$projectRoot = Join-Path (Join-Path $MemoryRoot "long-term") "專案"
if (Test-Path -LiteralPath $projectRoot) {
    $activeProjects = Get-ChildItem -LiteralPath $projectRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "CAPSULE.md") } |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName "CAPSULE.md")).LastWriteTime } -Descending |
        Select-Object -First 3

    if ($activeProjects) {
        $output += ""
        $output += "[活躍專案 top 3]"
        foreach ($project in $activeProjects) {
            $output += "- $($project.Name)"
        }
    }
}

$output -join "`n" | Write-Output
exit 0
