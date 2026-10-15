# ============================================================
#  DPG 开发环境变量 (在当前 shell 中 dot-source 即可)
#    . .\tools\env.ps1
# ============================================================

$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL           = 'https://pub.flutter-io.cn'

$dpgRoot  = 'E:\dpg'
$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
$flutterBin = Join-Path $dpgRoot '.tools\flutter\bin'

# 让 ONNX Runtime 能被 CLI 直接加载
$env:ORT_DYLIB_PATH = Join-Path $dpgRoot 'runtime\bin\onnxruntime.dll'

foreach ($p in @($cargoBin, $flutterBin)) {
  if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
    $env:PATH = "$p;$env:PATH"
  }
}

Write-Host "DPG 开发环境已就绪" -ForegroundColor Green
Write-Host "  rustc  : $(if (Get-Command rustc -EA SilentlyContinue) { (rustc --version) } else { '未安装' })"
Write-Host "  flutter: $(if (Get-Command flutter -EA SilentlyContinue) { 'OK' } else { '未安装' })"
Write-Host "  ORT    : $env:ORT_DYLIB_PATH"
Write-Host ""
Write-Host "常用命令:" -ForegroundColor Cyan
Write-Host "  内核基准测试: cd $dpgRoot\core; cargo run --release --bin dpg-cli -- bench --models $dpgRoot\models --dll $dpgRoot\runtime\bin\onnxruntime.dll --image $dpgRoot\models\bench\ch_en_num.jpg --repeat 5"
Write-Host "  重新打包    : pwsh -File $dpgRoot\tools\build_windows.ps1"
