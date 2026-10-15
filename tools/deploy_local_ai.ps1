#requires -version 5.1
<#
  本地 AI 翻译 · 一键部署
  ------------------------------------------------------------------
  给「Unlimited sky OCR 全屏实时翻译器」装一个跑在自己显卡上的翻译模型:
    推理后端: Ollama (自动处理 GPU 卸载 / 开机自启)
    翻译模型: 腾讯 Hunyuan-MT-7B  (WMT25 翻译比赛 31 个语向拿了 30 个第一)
    量化档位: Q4_K_M (~4.4GB, 8GB 显存可全量加载)

  全程不需要手动操作, 装完打开软件 → 翻译引擎选「AI 大模型翻译」
  → 点「本机 Ollama · Hunyuan-MT-7B」预设即可。
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------- 可调参数 ----------------
$ModelDir   = 'D:\LLM\models'
$OllamaHome = 'D:\LLM\ollama-models'
$GgufName   = 'Hunyuan-MT-7B.Q4_K_M.gguf'
$GgufUrl    = "https://huggingface.co/mradermacher/Hunyuan-MT-7B-GGUF/resolve/main/$GgufName"
$GgufSha    = '08b4dd8f25002592526194defd2481febcc9008fe37e67accde9bbe29d28cecf'
$GgufBytes  = 4624950272
$OllamaUrl  = 'https://ollama.com/download/OllamaSetup.exe'
$ModelName  = 'hunyuan-mt'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Head($msg) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}

Head '本地 AI 翻译 · 一键部署'

# ============================================================
#  1. 检查显卡
# ============================================================
Say '[1/5] 检查显卡 ...'
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Say '      没有找到 nvidia-smi —— 没装 NVIDIA 驱动?' 'Yellow'
    Say '      仍然可以继续, 但会退化成 CPU 推理, 会非常慢。' 'Yellow'
} else {
    $info = & nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader 2>$null
    Say "      $info" 'Green'
    $vram = [int](($info -split ',')[1] -replace '[^0-9]', '')
    if ($vram -lt 6000) {
        Say "      显存只有 ${vram}MB, 7B 模型可能放不下。" 'Yellow'
        Say '      可以把下面 $GgufName 换成 Q4_K_S (4.2GB) 或 Q3_K_M (3.6GB)。' 'Yellow'
    }
}

# ============================================================
#  2. 安装 Ollama
# ============================================================
Say ''
Say '[2/5] 检查 Ollama ...'
$ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
if (Test-Path $ollamaExe) {
    Say "      已安装: $(& $ollamaExe --version)" 'Green'
} else {
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    Say "      正在下载 Ollama (约 1.5GB) ..." 'Yellow'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $req = [System.Net.HttpWebRequest]::Create($OllamaUrl)
    $req.Timeout = 60000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $rs = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($setup)
    $buf = New-Object byte[] 1048576
    $read = 0; $last = 0
    while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n); $read += $n
        if ($sw.Elapsed.TotalSeconds - $last -ge 10) {
            $last = $sw.Elapsed.TotalSeconds
            $pct = if ($total -gt 0) { $read / $total * 100 } else { 0 }
            Write-Host ("`r      {0:N0} MB / {1:N0} MB ({2:N0}%)" -f `
                    ($read / 1MB), ($total / 1MB), $pct) -NoNewline
        }
    }
    $fs.Close(); $rs.Close(); $resp.Close()
    Write-Host ''
    Say '      正在静默安装 ...' 'Yellow'
    Start-Process -FilePath $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL' -Wait
    Start-Sleep -Seconds 8
    if (-not (Test-Path $ollamaExe)) { throw 'Ollama 安装失败' }
    Say "      安装完成: $(& $ollamaExe --version)" 'Green'
}

# ============================================================
#  3. 下载翻译模型
# ============================================================
Say ''
Say '[3/5] 检查翻译模型 ...'
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
$gguf = Join-Path $ModelDir $GgufName
$needDownload = $true
if (Test-Path $gguf) {
    $sz = (Get-Item $gguf).Length
    if ($sz -eq $GgufBytes) {
        Say '      文件已存在且大小正确, 校验哈希 ...' 'Yellow'
        $h = (Get-FileHash $gguf -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $GgufSha) { Say '      校验通过, 跳过下载' 'Green'; $needDownload = $false }
        else { Say '      哈希不符, 重新下载' 'Yellow' }
    } else {
        Say ("      文件不完整 ({0:N0}/{1:N0} 字节), 重新下载" -f $sz, $GgufBytes) 'Yellow'
    }
}
if ($needDownload) {
    Say "      正在下载 $GgufName (约 4.4GB, 视网速 10-30 分钟) ..." 'Yellow'
    $tmp = "$gguf.part"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $req = [System.Net.HttpWebRequest]::Create($GgufUrl)
    $req.Timeout = 60000; $req.ReadWriteTimeout = 120000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $rs = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($tmp)
    $buf = New-Object byte[] 1048576
    $read = 0; $last = 0
    while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n); $read += $n
        if ($sw.Elapsed.TotalSeconds - $last -ge 10) {
            $last = $sw.Elapsed.TotalSeconds
            $spd = $read / 1MB / $sw.Elapsed.TotalSeconds
            $eta = if ($spd -gt 0) { ($total - $read) / 1MB / $spd / 60 } else { 0 }
            Write-Host ("`r      {0:N0}/{1:N0} MB  {2:N1} MB/s  剩余 {3:N0} 分钟   " -f `
                    ($read / 1MB), ($total / 1MB), $spd, $eta) -NoNewline
        }
    }
    $fs.Close(); $rs.Close(); $resp.Close()
    Write-Host ''
    Move-Item $tmp $gguf -Force
    Say '      下载完成, 校验哈希 ...' 'Yellow'
    $h = (Get-FileHash $gguf -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $GgufSha) { throw "模型哈希校验失败!`n  实际: $h`n  期望: $GgufSha" }
    Say '      ✓ 哈希校验通过' 'Green'
}

# ============================================================
#  4. 导入模型
# ============================================================
Say ''
Say '[4/5] 把模型导入 Ollama ...'

# 让 Ollama 把模型存到大盘上
[Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $OllamaHome, 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_FLASH_ATTENTION', '1', 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', 'q8_0', 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_KEEP_ALIVE', '10m', 'User')
[Environment]::SetEnvironmentVariable('OLLAMA_MAX_LOADED_MODELS', '1', 'User')
$env:OLLAMA_MODELS = $OllamaHome
New-Item -ItemType Directory -Force -Path $OllamaHome | Out-Null

# 停掉旧的 serve 以便新环境变量生效
Get-Process | Where-Object { $_.ProcessName -like '*ollama*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden
Say '      等待服务启动 ...' 'Yellow'
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    try { Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 5 | Out-Null; $ok = $true; break } catch { }
}
if (-not $ok) { throw 'Ollama 服务起不来, 请手动运行: ollama serve' }
Say '      服务已就绪' 'Green'

# 生成 Modelfile (官方推荐推理参数)
$mf = Join-Path (Split-Path $ModelDir -Parent) 'Modelfile'
@"
FROM $gguf

# 腾讯混元翻译模型官方推荐推理参数
# top_k=20, top_p=0.6, repetition_penalty=1.05, temperature=0.7
# 该模型没有默认 system prompt, 所以这里也不设 SYSTEM。
PARAMETER temperature 0.7
PARAMETER top_p 0.6
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 4096
PARAMETER num_predict 2048
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"
"@ | Set-Content -Path $mf -Encoding UTF8

Say '      正在导入 (要复制 4.4GB, 约 1 分钟) ...' 'Yellow'
& $ollamaExe create $ModelName -f $mf 2>&1 | Out-Null
Say ''
& $ollamaExe list

# ============================================================
#  5. 自检
# ============================================================
Say ''
Say '[5/5] 自检 (第一次要把模型读进显存, 约 20 秒) ...'
$body = @{
    model   = $ModelName
    prompt  = "把下面的文本翻译成中文，不要额外解释。`n`nHello, this is a translation test."
    stream  = $false
    options = @{ temperature = 0.7; top_p = 0.6; top_k = 20; repeat_penalty = 1.05 }
} | ConvertTo-Json -Depth 5 -Compress
try {
    $t0 = Get-Date
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 300
    $dt = ((Get-Date) - $t0).TotalSeconds
    $tps = if ($r.eval_duration -gt 0) { $r.eval_count / ($r.eval_duration / 1e9) } else { 0 }
    Say "      译文: $($r.response.Trim())" 'White'
    Say ("      耗时 {0:N2}s, {1:N1} tok/s" -f $dt, $tps) 'Green'
} catch {
    Say "      自检失败: $($_.Exception.Message)" 'Red'
}

Say ''
& nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader | ForEach-Object { Say "      显存: $_" 'Gray' }

Head '部署完成'
Say '  打开「Unlimited sky OCR 全屏实时翻译器」:' 'White'
Say '    1. 翻译引擎 → 选「AI 大模型翻译」' 'White'
Say '    2. 点预设按钮「本机 Ollama · Hunyuan-MT-7B」' 'White'
Say '    3. 看到绿色「本地 AI 就绪」即可开始使用' 'White'
Say ''
Say '  模型地址: ' -NoNewline; Say 'http://127.0.0.1:11434/v1' 'Cyan'
Say '  模型名称: ' -NoNewline; Say $ModelName 'Cyan'
Say '  API Key : ' -NoNewline; Say '随便填 (本地不需要真 Key)' 'Cyan'
Say ''
Say '  不想用了? 卸载: 设置 → 应用 → Ollama, 再删掉 D:\LLM 即可。' 'DarkGray'
Say ''
Read-Host '按回车退出'
