#
# 把仓库推送到 GitHub
#
#   用法:
#     powershell -ExecutionPolicy Bypass -File tools\push_to_github.ps1 -Repo https://github.com/你的用户名/unlimited-sky-ocr.git
#
# 前提:
#   1. 已经在 GitHub 网页上建好**空仓库** (不要勾选 Add README / .gitignore / license)
#   2. 本机 git 已配置好凭据 (第一次会弹窗让你登录)

param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = 'main',

    [string]$Message = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
Set-Location $Root

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) {
    $git = Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'
}
if (-not (Test-Path $git)) { throw '找不到 git，请先安装 Git for Windows' }

if (-not (Test-Path '.git')) { throw '当前目录不是 git 仓库，请先运行 git init' }

Write-Host ''
Say '=== 推送前检查 ===' 'Cyan'

# ---- 1. 工作区是否干净 ----
$dirty = & $git status --porcelain
if ($dirty.Count -gt 0) {
    Say "  有 $($dirty.Count) 个未提交的改动：" 'Yellow'
    $dirty | Select-Object -First 10 | ForEach-Object { Say "    $_" 'DarkGray' }
    if (-not $Message) {
        $Message = Read-Host '  输入提交信息 (留空则取消)'
        if (-not $Message) { throw '已取消' }
    }
    & $git add -A
    & $git commit -q -m $Message
    Say '  已提交' 'Green'
}
else {
    Say '  工作区干净' 'Green'
}

# ---- 2. 确认没有把大文件带进去 ----
Say ''
Say '=== 体积检查 ===' 'Cyan'
$files = & $git ls-files
$big = @()
foreach ($f in $files) {
    if (Test-Path $f) {
        $s = (Get-Item $f).Length
        if ($s -gt 2MB) { $big += [PSCustomObject]@{ Name = $f; Size = $s } }
    }
}
$total = ($files | ForEach-Object { if (Test-Path $_) { (Get-Item $_).Length } } | Measure-Object -Sum).Sum
Say ("  跟踪文件 {0} 个，合计 {1:N1} MB" -f $files.Count, ($total / 1MB)) 'White'
if ($big.Count -gt 0) {
    Say "  警告: 有 $($big.Count) 个文件超过 2MB：" 'Yellow'
    $big | ForEach-Object { Say ("    {0,10:N1} MB  {1}" -f ($_.Size / 1MB), $_.Name) 'Yellow' }
    $ok = Read-Host '  继续推送? (y/N)'
    if ($ok -ne 'y') { throw '已取消' }
}

# ---- 3. 确认模型/运行时没被误提交 ----
Say ''
Say '=== 敏感/大体积目录检查 ===' 'Cyan'
$bad = $files | Where-Object { $_ -match '^(models|runtime|\.tools)/' -or $_ -match '\.(onnx|gguf|dll|exe)$' }
if ($bad) {
    Say '  以下文件不应该入库：' 'Red'
    $bad | Select-Object -First 10 | ForEach-Object { Say "    $_" 'Red' }
    throw '请检查 .gitignore'
}
Say '  ✓ 没有模型 / 运行时 / 二进制' 'Green'

# ---- 4. 推送 ----
Say ''
Say '=== 推送 ===' 'Cyan'
$remotes = & $git remote
if ($remotes -contains 'origin') {
    & $git remote set-url origin $Repo
    Say "  已更新 origin -> $Repo" 'Gray'
}
else {
    & $git remote add origin $Repo
    Say "  已添加 origin -> $Repo" 'Gray'
}

& $git branch -M $Branch
Say "  正在推送 $Branch ..." 'Yellow'
& $git push -u origin $Branch

Write-Host ''
Say '=== 完成 ===' 'Green'
Say "  仓库地址: $($Repo -replace '\.git$','')" 'Cyan'
Say ''
Say '  建议接着做:' 'White'
Say '    1. 仓库 Settings -> About 里填一句简介, 加上 Topics:' 'Gray'
Say '       ocr, translation, flutter, rust, windows, paddleocr, overlay, onnxruntime' 'DarkGray'
Say '    2. Releases -> Draft a new release, tag 填 v1.0.0' 'Gray'
Say '    3. 如果要传安装包, 注意它不含模型 —— 使用者需按 README 自行下载' 'Gray'
Say ''
