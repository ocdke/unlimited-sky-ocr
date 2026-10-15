# ============================================================
#  DPG 一键构建 (Android)
#    1. 交叉编译 Rust 内核 -> libdpg_core.so
#    2. 放置 ONNX Runtime 的 libonnxruntime.so
#    3. 把模型复制进 Flutter assets
#    4. flutter build apk
#
#  用法:
#    powershell -File tools\build_android.ps1                    # arm64-v8a release
#    powershell -File tools\build_android.ps1 -Abi armeabi-v7a
#    powershell -File tools\build_android.ps1 -SkipApk           # 只交叉编译内核
# ============================================================
param(
  [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64')]
  [string]$Abi = 'arm64-v8a',
  [switch]$SkipCore,
  [switch]$SkipApk,
  [switch]$BundleAllModels,
  # 一并打包离线翻译模型 (每个语言对约 108 MB)
  [switch]$BundleOfflineModels
)

$ErrorActionPreference = 'Stop'
$Root  = 'E:\dpg'
$Core  = Join-Path $Root 'core'
$App   = Join-Path $Root 'app'
$Cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$Flutter = Join-Path $Root '.tools\flutter\bin\flutter.bat'
$Sdk   = Join-Path $Root '.tools\android\sdk'

$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL           = 'https://pub.flutter-io.cn'
$env:ANDROID_HOME             = $Sdk
$env:ANDROID_SDK_ROOT         = $Sdk
$env:JAVA_HOME                = 'C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot'

# ---------- 定位 NDK ----------
$ndkDir = Get-ChildItem (Join-Path $Sdk 'ndk') -Directory -ErrorAction SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $ndkDir) { throw "未找到 NDK, 请先执行: sdkmanager `"ndk;28.2.13676358`"" }
$Ndk = $ndkDir.FullName
$Toolchain = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
if (-not (Test-Path $Toolchain)) { throw "NDK 工具链缺失: $Toolchain" }
Write-Host "NDK: $Ndk" -ForegroundColor Cyan

# ---------- ABI 映射 ----------
$api = 24   # Android 7.0, 覆盖 99% 设备
$map = @{
  'arm64-v8a'   = @{ rust = 'aarch64-linux-android';   cc = "aarch64-linux-android$api-clang.cmd";   flutter = 'android-arm64' }
  'armeabi-v7a' = @{ rust = 'armv7-linux-androideabi'; cc = "armv7a-linux-androideabi$api-clang.cmd"; flutter = 'android-arm' }
  'x86_64'      = @{ rust = 'x86_64-linux-android';    cc = "x86_64-linux-android$api-clang.cmd";    flutter = 'android-x64' }
}
$m = $map[$Abi]
$cc = Join-Path $Toolchain $m.cc
if (-not (Test-Path $cc)) { throw "找不到编译器: $cc" }
$ar = Join-Path $Toolchain 'llvm-ar.exe'
if (-not (Test-Path $ar)) { throw "找不到 llvm-ar: $ar" }

# 链接器通过 core\.cargo\config.toml 指定 (见该文件)。
# 通过环境变量 CARGO_TARGET_<T>_LINKER 传参在部分 PowerShell 版本下会被忽略,
# 导致链接阶段报 "linker `cc` not found"。
$cfgFile = Join-Path $Core '.cargo\config.toml'
if (-not (Test-Path $cfgFile)) {
  throw "缺少 $cfgFile —— 该文件指定了各 Android target 的 NDK 链接器路径"
}
if (-not (Select-String -Path $cfgFile -SimpleMatch (Split-Path $cc -Leaf) -Quiet)) {
  Write-Host "警告: config.toml 中的链接器与当前 NDK 不一致" -ForegroundColor Yellow
  Write-Host "      期望包含: $cc" -ForegroundColor Yellow
}
Write-Host "本次目标: $Abi -> $($m.rust)" -ForegroundColor Cyan

# ---------- 1. Rust 内核 ----------
$soSrc = Join-Path $Core "target\$($m.rust)\release\libdpg_core.so"
if (-not $SkipCore) {
  Write-Host "`n=== [1/4] 交叉编译 Rust 内核 -> $($m.rust) ===" -ForegroundColor Cyan
  Push-Location $Core
  try {
    & $Cargo build --release --target $m.rust
    if ($LASTEXITCODE -ne 0) { throw "cargo build 失败" }
  } finally { Pop-Location }
}
if (-not (Test-Path $soSrc)) { throw "未找到内核产物: $soSrc" }
Write-Host ("内核: {0:N2} MB" -f ((Get-Item $soSrc).Length / 1MB)) -ForegroundColor Green

# ---------- 2. 放置 .so ----------
Write-Host "`n=== [2/4] 放置动态库到 jniLibs ===" -ForegroundColor Cyan
$jni = Join-Path $App "android\app\src\main\jniLibs\$Abi"
New-Item -ItemType Directory -Force -Path $jni | Out-Null
Copy-Item $soSrc (Join-Path $jni 'libdpg_core.so') -Force

$ortSo = Join-Path $Root "runtime\android\jni\$Abi\libonnxruntime.so"
if (-not (Test-Path $ortSo)) { throw "缺少 ONNX Runtime 的 $Abi 动态库: $ortSo" }
Copy-Item $ortSo (Join-Path $jni 'libonnxruntime.so') -Force
Get-ChildItem $jni | ForEach-Object { "  {0,-28} {1,8:N2} MB" -f $_.Name, ($_.Length / 1MB) }

# ---------- 3. 模型进原生 assets ----------
# 放在 android/app/src/main/assets 下 (不是 Flutter 的 assets),
# 由 Kotlin 侧首次启动解包到 filesDir, 这样 Windows 构建不必也打包模型。
Write-Host "`n=== [3/4] 复制模型到原生 assets ===" -ForegroundColor Cyan
$assetsRoot = Join-Path $App 'android\app\src\main\assets\models'
if (Test-Path $assetsRoot) { Remove-Item $assetsRoot -Recurse -Force }
# 必须保持 ocr\PP-OCRv5 这层结构, 与 Rust 侧 EngineConfig::standard 的
# 目录约定一致 (<modelRoot>/ocr/PP-OCRv5/{det,cls,rec})
$assetsModels = Join-Path $assetsRoot 'ocr\PP-OCRv5'
New-Item -ItemType Directory -Force -Path $assetsModels | Out-Null

$v5 = Join-Path $Root 'models\ocr\PP-OCRv5'
Copy-Item (Join-Path $v5 'det') $assetsModels -Recurse -Force
Copy-Item (Join-Path $v5 'cls') $assetsModels -Recurse -Force
New-Item -ItemType Directory -Force -Path (Join-Path $assetsModels 'rec') | Out-Null

# 默认只带中/英/拉丁/韩/西里尔, 控制 APK 体积; -BundleAllModels 全带
$langs = if ($BundleAllModels) {
  @('ch','en','latin','cyrillic','korean','arabic','devanagari','el','eslav','th','ta','te')
} else {
  @('ch','en','latin','cyrillic','korean')
}
foreach ($l in $langs) {
  $src = Join-Path $v5 "rec\${l}_PP-OCRv5_rec_mobile.onnx"
  if (Test-Path $src) { Copy-Item $src (Join-Path $assetsModels 'rec') -Force }
}
Copy-Item (Join-Path $v5 'rec\dicts') (Join-Path $assetsModels 'rec') -Recurse -Force

# 离线翻译模型 (可选): 每个语言对约 108 MB, 会显著增大 APK
if ($BundleOfflineModels) {
  $mtSrc = Join-Path $Root 'models\translate'
  if (Test-Path $mtSrc) {
    $mtDst = Join-Path $assetsRoot 'translate'
    Copy-Item $mtSrc $mtDst -Recurse -Force
    $mtSize = (Get-ChildItem $mtDst -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ("离线翻译模型: {0:N1} MB" -f ($mtSize / 1MB)) -ForegroundColor Green
  } else {
    Write-Host "警告: 未找到 $mtSrc, 跳过离线翻译模型" -ForegroundColor Yellow
  }
}

$size = (Get-ChildItem $assetsModels -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("assets 模型: {0:N1} MB ({1} 个语种)" -f ($size / 1MB), $langs.Count) -ForegroundColor Green

# ---------- 4. 打包 APK ----------
if (-not $SkipApk) {
  Write-Host "`n=== [4/4] 构建 APK ===" -ForegroundColor Cyan
  Push-Location $App
  try {
    & $Flutter build apk --release --target-platform $m.flutter
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk 失败" }
  } finally { Pop-Location }
  $apk = Join-Path $App "build\app\outputs\flutter-apk\app-release.apk"
  if (Test-Path $apk) {
    Write-Host ("`nAPK: {0}  ({1:N1} MB)" -f $apk, ((Get-Item $apk).Length / 1MB)) -ForegroundColor Green
  }
}
