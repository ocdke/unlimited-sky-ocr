# ============================================================
#  DPG OCR 模型下载脚本
#  源: ModelScope RapidAI/RapidOCR (国内直连, 无需翻墙)
#  产物: E:\dpg\models\...
# ============================================================
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$RepoRoot = 'E:\dpg'
$ModelDir = Join-Path $RepoRoot 'models'
$Base     = 'https://www.modelscope.cn/api/v1/models/RapidAI/RapidOCR/repo?Revision=master&FilePath='

# ---- PP-OCRv5 多语种识别模型 (mobile, 速度快精度高) ----
$RecLangs = @('ch','en','latin','cyrillic','korean','arabic','devanagari','el','eslav','th','ta','te')

$manifest = [ordered]@{
  # --- 检测模型: PP-OCRv5 det mobile, 多语种通用, 4.6MB ---
  'onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx'                      = 'ocr/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx'
  # --- 方向分类: 0/180 度文本行纠正, 0.97MB ---
  'onnx/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx'   = 'ocr/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx'
  # --- 配置文件 (含预处理参数) ---
  'paddle/PP-OCRv5/det/ch_PP-OCRv5_det_mobile/inference.yml'           = 'ocr/PP-OCRv5/det/inference.yml'
  'paddle/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile/inference.yml' = 'ocr/PP-OCRv5/cls/inference.yml'
  'paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/inference.yml'           = 'ocr/PP-OCRv5/rec/inference.yml'
  # --- PP-OCRv6 (最新, 用于精度对比测试) ---
  'onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx'                          = 'ocr/PP-OCRv6/det/PP-OCRv6_det_small.onnx'
  'onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx'                          = 'ocr/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx'
  'paddle/PP-OCRv6/rec/PP-OCRv6_rec_small/ppocrv6_dict.txt'            = 'ocr/PP-OCRv6/rec/ppocrv6_dict.txt'
  'paddle/PP-OCRv6/rec/PP-OCRv6_rec_small/inference.yml'               = 'ocr/PP-OCRv6/rec/inference.yml'
  # --- 基准测试图片 ---
  'resources/test_files/ch_en_num.jpg'                                 = 'bench/ch_en_num.jpg'
  'resources/test_files/long.jpeg'                                     = 'bench/long.jpeg'
  'resources/test_files/test.png'                                      = 'bench/test.png'
}

# 各语种识别模型 + 字典
foreach ($lang in $RecLangs) {
  $manifest["onnx/PP-OCRv5/rec/${lang}_PP-OCRv5_rec_mobile.onnx"] = "ocr/PP-OCRv5/rec/${lang}_PP-OCRv5_rec_mobile.onnx"
  $dictName = if ($lang -eq 'ch') { 'ppocrv5_dict.txt' } else { "ppocrv5_${lang}_dict.txt" }
  $manifest["paddle/PP-OCRv5/rec/${lang}_PP-OCRv5_rec_mobile/${dictName}"] = "ocr/PP-OCRv5/rec/dicts/${lang}.txt"
}

$total = $manifest.Count
$i = 0
$fail = @()
$bytes = 0

foreach ($kv in $manifest.GetEnumerator()) {
  $i++
  $src = $kv.Key
  $dst = Join-Path $ModelDir ($kv.Value -replace '/', '\')
  $dir = Split-Path $dst -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  if ((Test-Path $dst) -and ((Get-Item $dst).Length -gt 0)) {
    Write-Output ("[{0,2}/{1}] 已存在, 跳过  {2}" -f $i, $total, $kv.Value)
    $bytes += (Get-Item $dst).Length
    continue
  }

  $url = $Base + [uri]::EscapeDataString($src)
  Write-Output ("[{0,2}/{1}] 下载 {2}" -f $i, $total, $kv.Value)
  $ok = $false
  for ($try = 1; $try -le 3 -and -not $ok; $try++) {
    & curl.exe -s -L --fail --retry 2 --max-time 600 -o $dst $url
    if ((Test-Path $dst) -and ((Get-Item $dst).Length -gt 0)) { $ok = $true }
    else { Start-Sleep -Seconds 2 }
  }
  if ($ok) { $bytes += (Get-Item $dst).Length }
  else { $fail += $kv.Value; Write-Output "         !! 失败: $($kv.Value)" }
}

Write-Output ""
Write-Output "=========================================="
Write-Output ("下载完成: {0}/{1} 个文件, 共 {2:N1} MB" -f ($total - $fail.Count), $total, ($bytes / 1MB))
if ($fail.Count -gt 0) {
  Write-Output "失败列表:"
  $fail | ForEach-Object { Write-Output "  - $_" }
  exit 1
}
Write-Output "模型目录: $ModelDir"
