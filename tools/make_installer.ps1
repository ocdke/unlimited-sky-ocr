# ============================================================
#  打包安装程序 -> 桌面
#
#  1. 编译 Rust 安装器 (dpg-setup.exe)
#  2. 把发布目录打成载荷 (索引 + 数据) 追加到安装器尾部
#  3. 输出到桌面
#
#  用法: powershell -File tools\make_installer.ps1 [-OutDir <目录>] [-SkipBuild]
# ============================================================
param(
  [string]$OutDir = "$env:USERPROFILE\Desktop",
  [switch]$SkipBuild,
  [string]$ReleaseDir = 'E:\dpg\app\build\windows\x64\runner\Release',
  # 是否把离线翻译模型 (约 228MB) 一起打进去
  [bool]$WithOfflineModels = $true
)

$ErrorActionPreference = 'Stop'
$Root = 'E:\dpg'
$InstallerDir = Join-Path $Root 'installer'
$Name = 'Unlimited sky OCR 全屏实时翻译器_安装程序.exe'

function Step($n, $t) { Write-Host "`n=== [$n] $t ===" -ForegroundColor Cyan }

if (-not (Test-Path $ReleaseDir)) { throw "发布目录不存在: $ReleaseDir" }

# 把卸载器放进发布目录, 一起打包 (软件里的「卸载软件」按钮要用它)
$uninstaller = Join-Path $InstallerDir 'target\release\sky_uninstall.exe'
if (Test-Path $uninstaller) {
  Copy-Item $uninstaller (Join-Path $ReleaseDir 'sky_uninstall.exe') -Force
  Write-Host "已放入卸载器 sky_uninstall.exe"
} else {
  Write-Warning "未找到 sky_uninstall.exe, 请先编译 installer"
}

# ---------- 1. 编译安装器 ----------
if (-not $SkipBuild) {
  Step 1 '编译安装器'
  $env:PATH = (Join-Path $env:USERPROFILE '.cargo\bin') + ';' + $env:PATH
  Push-Location $InstallerDir
  & cargo build --release --message-format short 2>&1 |
    Select-String -Pattern '^error|error\[|Finished' | ForEach-Object { $_.Line }
  Pop-Location
}
$setup = Join-Path $InstallerDir 'target\release\dpg-setup.exe'
if (-not (Test-Path $setup)) { throw "安装器编译失败: $setup" }
Write-Host ("安装器: {0:N0} KB" -f ((Get-Item $setup).Length / 1KB))

# ---------- 2. 收集文件 ----------
Step 2 '收集发布文件'
$skip = @()
if (-not $WithOfflineModels) { $skip += 'models\translate' }

$files = @()
foreach ($f in Get-ChildItem $ReleaseDir -Recurse -File) {
  $rel = $f.FullName.Substring($ReleaseDir.Length + 1)
  $skipIt = $false
  foreach ($s in $skip) { if ($rel.StartsWith($s)) { $skipIt = $true } }
  if ($skipIt) { continue }
  # 注意: `data\` 是 Flutter 的必需资源 (icudtl.dat + flutter_assets),
  # 千万不能跳过 —— 少了它应用启动后立刻退出, 而且没有任何报错。
  if ($rel -like '*.log') { continue }
  $files += [pscustomobject]@{ Rel = $rel; Full = $f.FullName; Len = $f.Length }
}
$total = ($files | Measure-Object -Property Len -Sum).Sum
Write-Host ("文件数: {0}  总计: {1:N1} MB" -f $files.Count, ($total / 1MB))

# ---------- 3. 追加载荷 ----------
Step 3 '生成自解压安装包'
$out = Join-Path $OutDir $Name
$tmp = Join-Path $env:TEMP ("dpg_payload_" + [guid]::NewGuid().ToString('N') + ".bin")

$setupBytes = [System.IO.File]::ReadAllBytes($setup)
$fs = [System.IO.File]::Create($tmp)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write($setupBytes)

$index = New-Object System.Collections.Generic.List[object]
$offset = [int64]$setupBytes.Length
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$done = 0
foreach ($f in $files) {
  $bytes = [System.IO.File]::ReadAllBytes($f.Full)
  $bw.Write($bytes)
  $index.Add([pscustomobject]@{ p = $f.Rel.Replace('\', '/'); o = $offset; l = [int64]$bytes.Length })
  $offset += $bytes.Length
  $done += $bytes.Length
  if ($sw.ElapsedMilliseconds -gt 400) {
    Write-Host ("`r  写入 {0:N0}%  ({1:N0}/{2:N0} MB)" -f ($done * 100 / $total), ($done / 1MB), ($total / 1MB)) -NoNewline
    $sw.Restart()
  }
}
Write-Host ("`r  写入 100%  ({0:N0} MB)          " -f ($total / 1MB))

$json = $index | ConvertTo-Json -Compress -Depth 3
$jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$bw.Write($jsonBytes)
$bw.Write([int64]$jsonBytes.Length)
$bw.Write([System.Text.Encoding]::ASCII.GetBytes('SKYSETUP1'))
$bw.Flush(); $bw.Close(); $fs.Close()

Move-Item $tmp $out -Force
$size = (Get-Item $out).Length
Write-Host ""
Write-Host ("安装包: {0}" -f $out) -ForegroundColor Green
Write-Host ("大小:   {0:N1} MB" -f ($size / 1MB)) -ForegroundColor Green
Write-Host ""
Write-Host "双击即可安装 (装到 %LOCALAPPDATA%\Programs\DPG, 自动建桌面和开始菜单快捷方式)"
