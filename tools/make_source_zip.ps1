# ============================================================
#  把源码打包成压缩包放到桌面
#
#  排除构建产物、SDK、模型等大件, 只留能重建整个工程的源码。
#  用法: powershell -File tools\make_source_zip.ps1
# ============================================================
param(
  [string]$OutDir = "$env:USERPROFILE\Desktop"
)

$ErrorActionPreference = 'Stop'
$Root = 'E:\dpg'
$Stamp = Get-Date -Format 'yyyyMMdd'
$Name = "UnlimitedSky_源码_$Stamp.zip"
$Out = Join-Path $OutDir $Name

# 需要排除的目录/文件 (相对 $Root)
$excludeDirs = @(
  'app\build', 'app\.dart_tool', 'app\windows\flutter\ephemeral',
  'app\android\.gradle', 'app\android\app\build', 'app\android\.cxx',
  'app\android\app\src\main\jniLibs',
  'core\target', 'installer\target',
  '.tools', 'runtime', 'models',
  'docs\android',
  'app\build\app'
)
$excludeFiles = @('*.log', '*.zip', '*.apk', '*.exe', '*.dll', '*.so', '*.onnx', '*.pdb')
# 注意: 上面排除 dll/exe 是为了不带二进制; 但 Flutter 的 CMake 配置是源码, 不受影响

$temp = Join-Path $env:TEMP ("skysrc_" + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temp 'UnlimitedSky'
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Write-Host "=== 收集源码 ===" -ForegroundColor Cyan
$count = 0
$total = 0L
Get-ChildItem $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
  $rel = $_.FullName.Substring($Root.Length + 1)
  # 排除目录
  $skip = $false
  foreach ($d in $excludeDirs) {
    if ($rel -like "$d\*" -or $rel -eq $d) { $skip = $true; break }
  }
  if ($skip) { return }
  # 排除文件类型
  foreach ($pat in $excludeFiles) {
    if ($_.Name -like $pat) { $skip = $true; break }
  }
  if ($skip) { return }
  # 排除过大的单文件 (>2MB 基本是二进制)
  if ($_.Length -gt 2MB) { return }

  $dst = Join-Path $stage $rel
  $dir = Split-Path $dst -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Copy-Item $_.FullName $dst -Force
  $count++
  $total += $_.Length
}
Write-Host ("  文件数: {0}  总计: {1:N1} MB" -f $count, ($total / 1MB))

# 附一份构建说明
$readme = @'
# Unlimited sky OCR 全屏实时翻译器 —— 源码

## 目录结构

    core/       Rust 推理内核 (OCR + 离线翻译), 编译成 dpg_core.dll
    app/        Flutter 界面 (Windows)
    installer/  Rust 写的图形安装程序 + 卸载程序
    tools/      构建 / 打包 / 下载模型的脚本
    assets/     图标等素材
    docs/       文档与截图

## 需要自己准备的东西 (体积太大, 没有打进压缩包)

1. **Flutter SDK** 3.47+          https://flutter.dev
2. **Rust** 1.80+ (MSVC 工具链)   https://rustup.rs
3. **Visual Studio Build Tools** (含 C++ 桌面开发 + Windows SDK)
4. **ONNX Runtime 1.31.0** (Windows x64)
   下载后把 `onnxruntime.dll` 放到 `runtime\bin\`
5. **OCR 模型** 运行 `tools\download_models.ps1` 拉取
   (PaddleOCR PP-OCRv5, 12 个语种的检测 + 方向分类 + 识别)
6. **离线翻译模型** (可选, 约 228 MB)
   从 HuggingFace 取 Xenova/opus-mt-en-zh 与 opus-mt-zh-en 的量化版,
   放到 `models\translate\<src>-<tgt>\{encoder.onnx,decoder.onnx,tokenizer.json,config.json}`

## 构建

    # 环境变量 (按需修改)
    powershell -File tools\env.ps1

    # 下载模型
    powershell -File tools\download_models.ps1

    # 一条龙: 编译内核 + 编译界面 + 拷贝依赖
    powershell -File tools\build_windows.ps1

    # 打包安装程序 -> 桌面
    powershell -File tools\make_installer.ps1

## 关键设计

* **ONNX Runtime 每进程只允许一个 Environment** —— OCR 与翻译引擎共用
  进程级单例 (`core/src/ort_util.rs`)。
* **实时翻译的三档策略** (`app/lib/app_controller.dart`)：
  画面没变就跳过；只有几行变了就复用上一轮的框、跳过检测只做识别
  (`dpg_rec_rects_bgra`)；大面积变化才完整检测。
* **覆盖层是透明的**：框选和实时翻译都直接看你面前的真实屏幕,
  不做"截图->贴图"。窗口用 `WDA_EXCLUDEFROMCAPTURE` 排除自身捕获,
  否则会把自己的译文再识别一遍。
* **噪声过滤** 在 `core/src/filter.rs`, 按文本规则剔除图标碎片、纯符号、重复字符。

## 已知限制

* 桌面总有零星动画时, 帧差检测可能频繁触发重识别 (已加噪声判据缓解)
* 内存占用偏高 (实时模式跑一段时间 800MB~1GB)
* `Window.setEffect(transparent)` 在 Windows 上不返回, 已用超时兜住;
  实际透明度来自 `setBackgroundColor(Colors.transparent)`
'@
[System.IO.File]::WriteAllText((Join-Path $stage '源码说明.md'), $readme, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "=== 压缩 ===" -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Force }
Compress-Archive -Path $stage -DestinationPath $Out -CompressionLevel Optimal
Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue

$size = (Get-Item $Out).Length
Write-Host ""
Write-Host ("源码包: {0}" -f $Out) -ForegroundColor Green
Write-Host ("大小:   {0:N1} MB" -f ($size / 1MB)) -ForegroundColor Green
