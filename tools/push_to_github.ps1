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
Say '=== 检查仓库地址 ===' 'Cyan'

# ---- 0. 地址校验 ----
# 最常见的错误是从浏览器地址栏直接复制，典型形态:
#   https://github.com/用户名?tab=repositories/仓库名.git
# 里面混进了 ?tab=... 这类页面参数, git 会解析成不存在的路径。
if ($Repo -match '\?' -or $Repo -match '/repositories' -or $Repo -match '\s') {
    Say '  ✗ 这个地址不是 git 仓库地址，是从浏览器地址栏复制来的页面链接。' 'Red'
    Say "    你填的: $Repo" 'Red'
    # 顺手猜一个正确的出来
    $guess = $null
    if ($Repo -match 'github\.com/([^/?]+)') { $user = $Matches[1] }
    if ($Repo -match '([^/?]+?)(\.git)?$') { $repoName = $Matches[1] }
    if ($user) {
        Say ''
        Say '    正确格式应该是：「用户名/仓库名」，例如：' 'Yellow'
        Say "      https://github.com/$user/你的仓库名.git" 'Cyan'
    }
    throw '地址不合法'
}

$Repo = $Repo.TrimEnd('/')
if ($Repo -notmatch '\.git$') { $Repo = "$Repo.git" }
if ($Repo -notmatch '^https://') {
    Say '  ✗ 只支持 https:// 开头的地址' 'Red'
    throw '地址不合法'
}
Say "  ✓ 地址格式正常: $Repo" 'Green'

# ---- 0b. 仓库到底存不存在 ----
Say ''
Say '=== 检查远程仓库是否存在 ===' 'Cyan'
Say '  (国内网络访问 GitHub 较慢，最多等 30 秒)' 'DarkGray'
$env:GIT_TERMINAL_PROMPT = '0'
$probe = & $git ls-remote $Repo 2>&1
$probeText = ($probe | Out-String)
if ($LASTEXITCODE -ne 0) {
    if ($probeText -match 'not found|Repository not found|403|401') {
        Say '  ✗ 远程仓库不存在（或你没有权限）。' 'Red'
        Say ''
        Say '  请先在网页上建一个**空仓库**：' 'Yellow'
        Say '    1. 打开 https://github.com/new' 'White'
        Say '    2. Repository name 填仓库名（本仓库建议 unlimited-sky-ocr）' 'White'
        Say '    3. ⚠️ 不要勾选 Add a README / .gitignore / license' 'Red'
        Say '       （本地已经有提交了，勾了会产生冲突）' 'DarkGray'
        Say '    4. 点 Create repository' 'White'
        Say '    5. 然后重新运行本脚本' 'White'
        throw '远程仓库不存在'
    }
    Say "  ! 探测失败（可能是网络问题）: $($probeText.Trim())" 'Yellow'
    $go = Read-Host '  仍然继续推送? (y/N)'
    if ($go -ne 'y') { throw '已取消' }
}
else {
    Say '  ✓ 仓库存在且可访问' 'Green'
}

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
