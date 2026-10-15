# ============================================================
#  DPG Android 冒烟测试
#    1. 创建/启动模拟器
#    2. 安装 APK
#    3. 启动应用, 截图
#    4. 触发框选翻译 (含 MediaProjection 授权), 截图
#
#  用法: powershell -File tools\android_smoke_test.ps1 [-SkipBoot]
# ============================================================
param(
  [switch]$SkipBoot,       # 模拟器已启动, 跳过启动步骤
  [switch]$KeepRunning,    # 结束后不关闭模拟器
  [switch]$NoDrive,        # 只做到启动+截图, 不模拟点击
  [string]$Tap = ''        # 手动点击序列, 形如 "540,720;540,1600"
)

$ErrorActionPreference = 'Continue'
$Root   = 'E:\dpg'
$Sdk    = Join-Path $Root '.tools\android\sdk'
$Adb    = Join-Path $Sdk 'platform-tools\adb.exe'
$Emu    = Join-Path $Sdk 'emulator\emulator.exe'
$AvdMgr = Join-Path $Sdk 'cmdline-tools\latest\bin\avdmanager.bat'
$Apk    = Join-Path $Root 'app\build\app\outputs\flutter-apk\app-release.apk'
$AvdName = 'dpg_test'
$ShotDir = Join-Path $Root 'docs\android'
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

$env:JAVA_HOME = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot'
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk

function Adb { & $Adb @args 2>&1 }
function Shot($name) {
  $remote = "/sdcard/$name.png"
  $local = Join-Path $ShotDir "$name.png"
  & $Adb shell screencap -p $remote | Out-Null
  & $Adb pull $remote $local 2>&1 | Out-Null
  & $Adb shell rm $remote | Out-Null
  if (Test-Path $local) { Write-Host ("  截图: {0} ({1:N0} KB)" -f $local, ((Get-Item $local).Length / 1KB)) }
  else { Write-Host "  截图失败: $name" }
}

# ---------- 1. 模拟器 ----------
if (-not $SkipBoot) {
  Write-Host "`n=== [1/5] 准备模拟器 ===" -ForegroundColor Cyan
  $avds = & $AvdMgr list avd 2>&1 | Out-String
  if ($avds -notmatch $AvdName) {
    Write-Host "创建 AVD: $AvdName"
    "no" | & $AvdMgr create avd -n $AvdName -k "system-images;android-36;google_apis;x86_64" -d pixel_6 --force 2>&1 | Select-Object -Last 5 | Out-String | Write-Host
  } else { Write-Host "AVD 已存在: $AvdName" }

  Write-Host "启动模拟器 (软件渲染, 无音频, 无快照) ..."
  Start-Process -FilePath $Emu -ArgumentList @(
    '-avd', $AvdName, '-no-audio', '-no-boot-anim', '-no-snapshot',
    '-gpu', 'swiftshader_indirect', '-memory', '4096', '-cores', '4'
  ) | Out-Null

  Write-Host "等待设备上线 ..."
  & $Adb wait-for-device 2>&1 | Out-Null
  $deadline = (Get-Date).AddMinutes(6)
  do {
    Start-Sleep -Seconds 5
    $b = (& $Adb shell getprop sys.boot_completed 2>&1 | Out-String).Trim()
    Write-Host "  boot_completed=$b"
  } while ($b -ne '1' -and (Get-Date) -lt $deadline)
  if ($b -ne '1') { Write-Host "模拟器启动超时" -ForegroundColor Red; exit 1 }
  Write-Host "模拟器已就绪" -ForegroundColor Green
}

# ---------- 2. 设备信息 ----------
Write-Host "`n=== [2/5] 设备信息 ===" -ForegroundColor Cyan
$devices = Adb devices
Write-Host ($devices -join "`n")
Write-Host ("Android 版本: " + ((Adb shell getprop ro.build.version.release) -join ''))
Write-Host ("ABI       : " + ((Adb shell getprop ro.product.cpu.abi) -join ''))
Write-Host ("分辨率    : " + ((Adb shell wm size) -join ''))

# ---------- 3. 安装 ----------
Write-Host "`n=== [3/5] 安装 APK ===" -ForegroundColor Cyan
if (-not (Test-Path $Apk)) { Write-Host "APK 不存在: $Apk" -ForegroundColor Red; exit 1 }
Write-Host ("APK: {0:N1} MB" -f ((Get-Item $Apk).Length / 1MB))
Adb install -r -t $Apk | Write-Host

# ---------- 4. 启动 + 初始截图 ----------
Write-Host "`n=== [4/5] 启动应用 ===" -ForegroundColor Cyan
Adb shell am force-stop com.dpg.dpg_app | Out-Null
Adb shell am start -n com.dpg.dpg_app/.MainActivity | Write-Host
Write-Host "等待引擎加载与模型解包 (首次约 20-40 秒) ..."
Start-Sleep -Seconds 40
Shot '01_launch'

Write-Host "`n--- 应用日志 (最近 40 行) ---"
Adb logcat -d -t 40 | Select-String -Pattern 'dpg|DPG|flutter|AndroidRuntime|FATAL' | Select-Object -Last 25 | ForEach-Object { $_.Line }

# ---------- 5. 触发框选翻译 ----------
if ($NoDrive) {
  Write-Host "`n=== [5/5] 跳过点击 (NoDrive) ===" -ForegroundColor Cyan
  Write-Host "截图输出目录: $ShotDir" -ForegroundColor Green
  if (-not $KeepRunning) { Write-Host "关闭模拟器"; Adb emu kill | Out-Null }
  exit 0
}

Write-Host "`n=== [5/5] 触发框选翻译 ===" -ForegroundColor Cyan

# 支持手动指定点击序列
if ($Tap -ne '') {
  foreach ($pair in $Tap.Split(';')) {
    $p = $pair.Split(',')
    if ($p.Count -ne 2) { continue }
    Write-Host ("点击 ({0}, {1})" -f $p[0], $p[1])
    Adb shell input tap ([int]$p[0]) ([int]$p[1]) | Out-Null
    Start-Sleep -Seconds 3
  }
  Start-Sleep -Seconds 10
  Shot 'manual_result'
  Write-Host "`n--- 前台 Activity ---"
  Adb shell dumpsys activity activities | Select-String -Pattern 'topResumedActivity' | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() }
  Write-Host "`n--- 应用日志 ---"
  Adb logcat -d -t 80 | Select-String -Pattern 'dpg|DPG|MediaProjection|flutter|FATAL' | Select-Object -Last 25 | ForEach-Object { $_.Line }
  Write-Host "`n截图输出目录: $ShotDir" -ForegroundColor Green
  if (-not $KeepRunning) { Write-Host "关闭模拟器"; Adb emu kill | Out-Null }
  exit 0
}

# 应用内「框选翻译」按钮: 从应用截图看大约在 (170, 470) 附近, 按屏幕比例换算
$sizeOut = (Adb shell wm size) -join ''
if ($sizeOut -match '(\d+)x(\d+)') {
  $sw = [int]$Matches[1]; $sh = [int]$Matches[2]
} else { $sw = 1080; $sh = 2400 }
Write-Host "屏幕: ${sw}x${sh}"

# 面板是竖排布局, 按钮大致在屏幕上方 30% 处
$btnY = [int]($sh * 0.30)
$btnX = [int]($sw * 0.30)
Write-Host "点击「框选翻译」按钮 ($btnX, $btnY)"
Adb shell input tap $btnX $btnY | Out-Null
Start-Sleep -Seconds 6
Shot '02_permission_prompt'

Write-Host "`n--- 当前前台 Activity ---"
Adb shell dumpsys activity activities | Select-String -Pattern 'topResumedActivity|mResumedActivity' | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() }

Write-Host "尝试点击 MediaProjection 授权对话框的确认按钮 ..."
# 对话框按钮通常在屏幕中下部; 先试常见位置
foreach ($y in @(0.62, 0.66, 0.70)) {
  $ty = [int]($sh * $y)
  Adb shell input tap ([int]($sw * 0.5)) $ty | Out-Null
  Start-Sleep -Seconds 3
}
Start-Sleep -Seconds 8
Shot '03_after_grant'

Write-Host "`n--- 应用日志尾部 ---"
Adb logcat -d -t 60 | Select-String -Pattern 'dpg|Dpg|MediaProjection|flutter' | Select-Object -Last 20 | ForEach-Object { $_.Line }

Write-Host "`n截图输出目录: $ShotDir" -ForegroundColor Green
if (-not $KeepRunning) {
  Write-Host "关闭模拟器"
  Adb emu kill | Out-Null
}
