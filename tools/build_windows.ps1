# ============================================================
#  DPG 一键构建 (Windows)
#    1. 编译 Rust 推理内核 -> dpg_core.dll
#    2. 编译 Flutter Windows 应用
#    3. 把 DLL / onnxruntime / 模型 拷进发布目录
#
#  用法:
#    pwsh -File tools\build_windows.ps1                # Release
#    pwsh -File tools\build_windows.ps1 -Debug         # Debug
# ============================================================
param(
  [switch]$Debug,
  [switch]$SkipCore,
  [switch]$SkipApp,
  # 一并打包离线翻译模型 (每个语言对约 108 MB, 默认不带)
  [switch]$WithOfflineModels
)

$ErrorActionPreference = 'Stop'
$Root   = 'E:\dpg'
$Core   = Join-Path $Root 'core'
$App    = Join-Path $Root 'app'
$Flutter= Join-Path $Root '.tools\flutter\bin\flutter.bat'
$Cargo  = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$RtBin  = Join-Path $Root 'runtime\bin'
$Models = Join-Path $Root 'models'

$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL           = 'https://pub.flutter-io.cn'

$buildProfile = if ($Debug) { 'debug' } else { 'release' }

# ---------- 1. Rust 内核 ----------
if (-not $SkipCore) {
  Write-Host "`n=== [1/3] 编译 Rust 内核 ($buildProfile) ===" -ForegroundColor Cyan
  Push-Location $Core
  try {
    if ($Debug) { & $Cargo build } else { & $Cargo build --release }
    if ($LASTEXITCODE -ne 0) { throw "cargo build 失败" }
  } finally { Pop-Location }
}

$coreDll = Join-Path $Core "target\$buildProfile\dpg_core.dll"
if (-not (Test-Path $coreDll)) {
  throw "未找到内核产物: $coreDll (先执行 cargo build)"
}
Write-Host ("内核: {0:N2} MB" -f ((Get-Item $coreDll).Length / 1MB)) -ForegroundColor Green

# ---------- 2. Flutter 应用 ----------
if (-not $SkipApp) {
  Write-Host "`n=== [2/3] 编译 Flutter Windows 应用 ===" -ForegroundColor Cyan
  Push-Location $App
  try {
    $fargs = @('build', 'windows', '--release')
    if ($Debug) { $fargs = @('build', 'windows', '--debug') }
    & $Flutter @fargs
    if ($LASTEXITCODE -ne 0) { throw "flutter build 失败" }
  } finally { Pop-Location }
}

$outDir = Join-Path $App 'build\windows\x64\runner\Release'
if ($Debug) { $outDir = Join-Path $App 'build\windows\x64\runner\Debug' }
if (-not (Test-Path $outDir)) { throw "未找到 Flutter 产物目录: $outDir" }

# ---------- 3. 组装运行时 ----------
Write-Host "`n=== [3/3] 组装运行时 ===" -ForegroundColor Cyan
Copy-Item $coreDll (Join-Path $outDir 'dpg_core.dll') -Force
Copy-Item (Join-Path $RtBin 'onnxruntime.dll') $outDir -Force

$modelDst = Join-Path $outDir 'models'
if (Test-Path $modelDst) { Remove-Item $modelDst -Recurse -Force }
New-Item -ItemType Directory -Force -Path $modelDst | Out-Null
Copy-Item (Join-Path $Models 'ocr') $modelDst -Recurse -Force

# 离线翻译模型 (可选): 每个语言对一个子目录
if ($WithOfflineModels) {
  $mtSrc = Join-Path $Models 'translate'
  if (Test-Path $mtSrc) {
    Copy-Item $mtSrc (Join-Path $modelDst 'translate') -Recurse -Force
    $mtSize = (Get-ChildItem (Join-Path $modelDst 'translate') -Recurse -File |
               Measure-Object -Property Length -Sum).Sum
    Write-Host ("离线翻译模型: {0:N1} MB" -f ($mtSize / 1MB)) -ForegroundColor Green
  } else {
    Write-Host "警告: 未找到 $mtSrc, 跳过离线翻译模型" -ForegroundColor Yellow
  }
}

Write-Host "`n发布目录: $outDir" -ForegroundColor Green
Write-Host "可执行文件: $(Join-Path $outDir 'UnlimitedSky.exe')" -ForegroundColor Green

$size = (Get-ChildItem $outDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("总计: {0:N1} MB" -f ($size / 1MB)) -ForegroundColor Green

Write-Host "`n--- 内容 ---"
Get-ChildItem $outDir | ForEach-Object {
  if ($_.PSIsContainer) {
    $s = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
    "{0,-24} <DIR>  {1,9:N1} MB" -f $_.Name, ($s / 1MB)
  } else {
    "{0,-24}        {1,9:N2} MB" -f $_.Name, ($_.Length / 1MB)
  }
}
