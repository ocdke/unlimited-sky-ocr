#
# 下载运行所需的模型与 ONNX Runtime
#
#   用法: powershell -ExecutionPolicy Bypass -File tools\fetch_resources.ps1
#
# 这些文件体积大 (ONNX Runtime 约 17 MB, 模型约 370 MB), 不适合放进 git 仓库,
# 所以单独下载。下完的目录结构见 README 的「资源准备」一节。
#
# 镜像: 国内访问 GitHub / HuggingFace 慢的话, 脚本会自动优先用国内镜像。

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = Split-Path $PSScriptRoot -Parent
$RuntimeDir = Join-Path $Root 'runtime\bin'
$OcrDir = Join-Path $Root 'models\ocr'
$MtDir = Join-Path $Root 'models\translate'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

# 通用下载: 支持断点续传, 带进度
function Get-File($url, $out, $label) {
    if (Test-Path $out) {
        $sz = (Get-Item $out).Length
        if ($sz -gt 1024) { Say ("      已存在, 跳过: {0} ({1:N1} MB)" -f (Split-Path $out -Leaf), ($sz / 1MB)) 'DarkGray'; return }
    }
    $dir = Split-Path $out -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Say "      下载 $label ..." 'Yellow'
    $tmp = "$out.part"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout = 60000; $req.ReadWriteTimeout = 180000; $req.AllowAutoRedirect = $true
    $req.UserAgent = 'Mozilla/5.0'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $rs = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($tmp)
    $buf = New-Object byte[] 1048576
    $read = 0; $last = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n); $read += $n
        if ($sw.Elapsed.TotalSeconds - $last -ge 2) {
            $last = $sw.Elapsed.TotalSeconds
            $spd = $read / 1MB / [Math]::Max($sw.Elapsed.TotalSeconds, 0.01)
            $pct = if ($total -gt 0) { $read / $total * 100 } else { 0 }
            Write-Host ("`r      {0:N1}/{1:N1} MB ({2:N0}%)  {3:N1} MB/s      " -f `
                    ($read / 1MB), ($total / 1MB), $pct, $spd) -NoNewline
        }
    }
    $fs.Close(); $rs.Close(); $resp.Close()
    Write-Host ''
    Move-Item $tmp $out -Force
}

Head '下载运行资源'

# ============================================================
#  1. ONNX Runtime
# ============================================================
Say '[1/3] ONNX Runtime 1.31.0 (win-x64)' 'White'
$ortVer = '1.31.0'
$ortOut = Join-Path $RuntimeDir 'onnxruntime.dll'
if (Test-Path $ortOut) {
    Say '      已存在, 跳过' 'DarkGray'
} else {
    $zip = Join-Path $env:TEMP "onnxruntime-win-x64-$ortVer.zip"
    $urls = @(
        "https://github.com/microsoft/onnxruntime/releases/download/v$ortVer/onnxruntime-win-x64-$ortVer.zip",
        "https://ghproxy.net/https://github.com/microsoft/onnxruntime/releases/download/v$ortVer/onnxruntime-win-x64-$ortVer.zip"
    )
    $ok = $false
    foreach ($u in $urls) {
        try { Get-File $u $zip "onnxruntime-$ortVer.zip"; $ok = $true; break }
        catch { Say "      源失败, 换下一个: $($_.Exception.Message)" 'DarkYellow' }
    }
    if (-not $ok) { throw 'ONNX Runtime 下载失败, 请手动下载并解压到 runtime/bin/' }
    Say '      解压 ...' 'Yellow'
    $tmpDir = Join-Path $env:TEMP "ort_$ortVer"
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
    $dll = Get-ChildItem $tmpDir -Recurse -Filter 'onnxruntime.dll' | Select-Object -First 1
    if (-not $dll) { throw '压缩包里没找到 onnxruntime.dll' }
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    Copy-Item $dll.FullName $ortOut -Force
    Remove-Item $zip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Say ("      完成: {0:N1} MB" -f ((Get-Item $ortOut).Length / 1MB)) 'Green'
}

# ============================================================
#  2. OCR 模型
# ============================================================
Say ''
Say '[2/3] PP-OCRv5 OCR 模型 (检测 / 方向分类 / 12 语种识别)' 'White'
Say '      来源: RapidAI/RapidOCR (ModelScope)' 'DarkGray'

# ModelScope 的直链格式
$msBase = 'https://www.modelscope.cn/api/v1/models/RapidAI/RapidOCR/repo?Revision=master&FilePath='
$files = @(
    @{ p = 'det/ch_PP-OCRv5_det_mobile.onnx'; r = 'onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx' },
    @{ p = 'cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx'; r = 'onnx/PP-OCRv5/cls/ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx' },
    @{ p = 'rec/ch_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/en_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/en_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/korean_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/korean_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/cyrillic_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/cyrillic_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/latin_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/latin_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/arabic_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/arabic_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/devanagari_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/devanagari_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/el_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/el_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/eslav_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/eslav_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/th_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/th_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/ta_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/ta_PP-OCRv5_rec_mobile.onnx' },
    @{ p = 'rec/te_PP-OCRv5_rec_mobile.onnx'; r = 'onnx/PP-OCRv5/rec/te_PP-OCRv5_rec_mobile.onnx' }
)
$fail = 0
foreach ($f in $files) {
    $out = Join-Path $OcrDir $f.p
    try { Get-File ($msBase + $f.r) $out (Split-Path $f.p -Leaf) }
    catch { Say ("      失败: {0} —— {1}" -f $f.p, $_.Exception.Message.Split("`n")[0]) 'Red'; $fail++ }
}
if ($fail -gt 0) {
    Say ''
    Say "      有 $fail 个模型没下下来。" 'Yellow'
    Say '      可以到 https://www.modelscope.cn/models/RapidAI/RapidOCR 手动下载,' 'Yellow'
    Say '      按上面的路径放到 models/ocr/ 下即可。' 'Yellow'
}
Say '      提示: 日语没有独立模型, 用 ch 模型 (字典含完整假名)' 'DarkGray'

# ============================================================
#  3. 离线翻译模型 (可选)
# ============================================================
Say ''
Say '[3/3] OPUS-MT 离线翻译模型 (中↔英, 可选)' 'White'
Say '      不下也能用, 只是断网时没有兜底' 'DarkGray'
$hfMirror = 'https://hf-mirror.com'
$pairs = @(
    @{ d = 'en-zh'; repo = 'Xenova/opus-mt-en-zh'; files = @('encoder_model_quantized.onnx', 'decoder_model_merged_quantized.onnx', 'config.json', 'generation_config.json', 'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'source.spm', 'target.spm') },
    @{ d = 'zh-en'; repo = 'Xenova/opus-mt-zh-en'; files = @('encoder_model_quantized.onnx', 'decoder_model_merged_quantized.onnx', 'config.json', 'generation_config.json', 'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'source.spm', 'target.spm') }
)
foreach ($p in $pairs) {
    foreach ($f in $p.files) {
        $out = Join-Path (Join-Path $MtDir $p.d) $f
        $url = "$hfMirror/$($p.repo)/resolve/main/$f"
        try { Get-File $url $out "$($p.d)/$f" }
        catch { Say ("      跳过 {0}/{1}: {2}" -f $p.d, $f, $_.Exception.Message.Split("`n")[0]) 'DarkYellow' }
    }
}

# ============================================================
#  汇总
# ============================================================
Head '完成'
foreach ($d in @($RuntimeDir, $OcrDir, $MtDir)) {
    if (Test-Path $d) {
        $sz = (Get-ChildItem $d -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $n = (Get-ChildItem $d -Recurse -File).Count
        Say ("  {0,-46} {1,3} 个文件  {2,8:N1} MB" -f $d.Replace($Root, '.'), $n, ($sz / 1MB)) 'White'
    }
}
Say ''
Say '  下一步: powershell -File tools\build_windows.ps1' 'Cyan'
Say ''
