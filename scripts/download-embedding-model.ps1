[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$QmdCache,
    [string]$QmdConfig,
    [switch]$SkipQueryModels,
    [switch]$ConfigureOnly,
    [switch]$PersistUserEnvironment
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
if ([string]::IsNullOrWhiteSpace($QmdCache)) {
    $QmdCache = Join-Path $ProjectRoot ".ai-assistant\qmd\cache"
}
if ([string]::IsNullOrWhiteSpace($QmdConfig)) {
    $QmdConfig = Join-Path $ProjectRoot ".ai-assistant\qmd\config"
}

$QmdCache = [System.IO.Path]::GetFullPath($QmdCache)
$QmdConfig = [System.IO.Path]::GetFullPath($QmdConfig)
$env:XDG_CACHE_HOME = $QmdCache
$env:XDG_CONFIG_HOME = $QmdConfig
$env:QMD_CONFIG_DIR = Join-Path $QmdConfig "qmd"
$env:INDEX_PATH = Join-Path (Join-Path $QmdCache "qmd") "index.sqlite"

$EmbedModel = "hf:Ralriki/multilingual-e5-large-instruct-GGUF/multilingual-e5-large-instruct-q8_0.gguf"

Write-Host "==> AI Assistant Starter — qmd Model Setup" -ForegroundColor Cyan
Write-Host ""
Write-Host "Project: $ProjectRoot"
Write-Host "Embedding: $EmbedModel"
Write-Host "Embedding 模型約 603 MB；完整 qmd 查詢模型合計約 2.5 GB。" -ForegroundColor Yellow
Write-Host ""

# qmd 會在第一次建立 index 時讀取這個值。預設只影響本次程序；
# 使用者必須明確傳入 -PersistUserEnvironment 才會修改 User scope。
$env:QMD_EMBED_MODEL = $EmbedModel
if ($PersistUserEnvironment) {
    Write-Host "==> 寫入使用者層 QMD_EMBED_MODEL..." -ForegroundColor Cyan
    [Environment]::SetEnvironmentVariable("QMD_EMBED_MODEL", $EmbedModel, "User")
    Write-Host "    OK" -ForegroundColor Green
}

# qmd 2.5.3 會把模型寫進 index.yml，而且該設定的優先序高於環境變數。
# 若 collection 已先由 install.ps1 建立，也要同步更新目前 index。
$QmdConfigPath = Join-Path $env:QMD_CONFIG_DIR "index.yml"
if (Test-Path -LiteralPath $QmdConfigPath) {
    Write-Host "==> 同步更新 qmd index 的 embedding 模型..." -ForegroundColor Cyan
    $configText = Get-Content -LiteralPath $QmdConfigPath -Raw -Encoding UTF8

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
        $QmdConfigPath,
        $configText,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Host "    OK: $QmdConfigPath" -ForegroundColor Green
} elseif ($ConfigureOnly) {
    throw "找不到 qmd index 設定：$QmdConfigPath。請先執行 install.ps1 -Scope Project -SkipEmbedding。"
}

if ($ConfigureOnly) {
    Write-Host ""
    Write-Host "模型設定已更新；依照要求略過下載與 embedding。" -ForegroundColor Green
    exit 0
}

$qmd = Get-Command qmd -ErrorAction SilentlyContinue
if (-not $qmd) {
    throw "找不到 qmd。請先安裝：npm install -g @tobilu/qmd@2.5.3"
}
Write-Host "==> qmd found: $($qmd.Source)"

Write-Host ""
Write-Host "==> 檢查 memory-longterm collection..." -ForegroundColor Cyan
$statusOutput = & qmd status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "qmd status 失敗：$($statusOutput | Out-String)"
}
if (($statusOutput | Out-String) -notmatch "memory-longterm") {
    throw "找不到 memory-longterm。請先執行 install.ps1 -Scope Project -SkipEmbedding，再重新執行本腳本。"
}
Write-Host "    OK" -ForegroundColor Green

if (-not $SkipQueryModels) {
    Write-Host ""
    Write-Host "==> 下載完整 qmd 查詢模型（約 2.5 GB）..." -ForegroundColor Cyan
    & qmd pull
    if ($LASTEXITCODE -ne 0) {
        throw "qmd pull 失敗，請檢查網路與磁碟空間後重試。"
    }
} else {
    Write-Host "==> 依照要求略過 query expansion 與 reranker 模型。" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==> 建立 memory-longterm embeddings..." -ForegroundColor Cyan
& qmd embed -c memory-longterm -f
if ($LASTEXITCODE -ne 0) {
    throw "qmd embed 失敗，未完成向量建立。"
}

$verifyOutput = & qmd status 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "qmd status 驗證失敗。"
}
$verifyText = $verifyOutput | Out-String
if ($verifyText -notmatch "Ralriki/multilingual-e5-large-instruct-GGUF") {
    throw "qmd 目前不是使用指定的 multilingual-e5-large-instruct 模型。"
}

Write-Host ""
Write-Host "===== 完成 =====" -ForegroundColor Cyan
Write-Host "Embedding: multilingual-e5-large-instruct (Q8_0)" -ForegroundColor Green
Write-Host "Collection: memory-longterm" -ForegroundColor Green
if ($SkipQueryModels) {
    Write-Host "注意：第一次 qmd query 仍會下載 query expansion 與 reranker 模型。" -ForegroundColor Yellow
}
