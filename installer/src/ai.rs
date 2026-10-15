//! 本地 AI 翻译的自动部署
//!
//! 装一个 7B 翻译模型到用户机器上, 全程不需要用户操作:
//!   1. 下载并静默安装 Ollama (推理后端)
//!   2. 按显存选量化档, 下载 Hunyuan-MT-7B 模型
//!   3. 生成 Modelfile 并导入
//!   4. 校验 + 自检
//!
//! 安装程序本身没有 HTTP 依赖, 所以下载和导入交给一个内嵌的 PowerShell
//! 脚本来做 —— 系统自带, 不用引第三方库, 而且脚本会按行回吐进度,
//! Rust 侧解析后就能驱动进度条。

use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct AiOptions {
    /// 模型存哪儿 (和 OCR 模型同一个根目录下的 ai 子目录)
    pub root: PathBuf,
    pub vram_mb: u32,
}

pub struct AiProgress<'a> {
    /// 0-100, 只覆盖整个安装流程里 AI 这一段
    pub report: &'a dyn Fn(u32, String),
}

/// 模型文件名 / 下载直链 (HF 上 mradermacher 的仓库, 量化档齐全)
fn model_url(quant: &str) -> String {
    format!(
        "https://huggingface.co/mradermacher/Hunyuan-MT-7B-GGUF/resolve/main/Hunyuan-MT-7B.{quant}.gguf"
    )
}

/// 部署本地 AI。返回 Err(说明) 表示失败, 但**不影响主程序已经装好**。
pub fn deploy(opt: &AiOptions, prog: &AiProgress) -> Result<(), String> {
    let quant = crate::hw::pick_quant(opt.vram_mb).1;
    let ollama_dir = opt.root.join("ollama");
    let models_dir = opt.root.join("models");
    let model_dir = opt.root.join("files");
    std::fs::create_dir_all(&models_dir).map_err(|e| format!("建目录失败: {e}"))?;
    std::fs::create_dir_all(&model_dir).map_err(|e| format!("建目录失败: {e}"))?;

    let script = write_script(opt, quant, &models_dir, &model_dir)?;

    (prog.report)(0, "正在准备本地 AI 环境…".into());

    let mut child = Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-NonInteractive",
            "-File",
        ])
        .arg(&script)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("启动部署进程失败: {e}"))?;

    let stdout = child.stdout.take().ok_or("拿不到输出流")?;
    // stderr 必须一起排空。ollama 会往 stderr 狂打 ANSI 进度条,
    // 只读 stdout 的话管道缓冲区(64KB)很快写满, 子进程会直接卡住。
    let stderr = child.stderr.take();
    let err_buf = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    if let Some(se) = stderr {
        let eb = err_buf.clone();
        std::thread::spawn(move || {
            let r = BufReader::new(se);
            for line in r.lines().map_while(Result::ok) {
                if let Ok(mut g) = eb.lock() {
                    if g.len() < 8000 {
                        g.push_str(&line);
                        g.push('\n');
                    }
                }
            }
        });
    }
    let reader = BufReader::new(stdout);
    let mut last_err = String::new();

    for line in reader.lines().map_while(Result::ok) {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("SKYAI ") {
            // 格式: SKYAI <百分比> <说明>
            let mut it = rest.splitn(2, ' ');
            let pct: u32 = it.next().unwrap_or("0").parse().unwrap_or(0);
            let msg = it.next().unwrap_or("").to_string();
            (prog.report)(pct.min(100), msg);
        } else if let Some(e) = line.strip_prefix("SKYERR ") {
            last_err = e.to_string();
        }
    }

    let status = child.wait().map_err(|e| format!("等待部署进程失败: {e}"))?;
    let _ = std::fs::remove_file(&script);

    if !status.success() {
        let tail = err_buf
            .lock()
            .map(|g| {
                let t: String = g.chars().rev().take(600).collect();
                t.chars().rev().collect::<String>()
            })
            .unwrap_or_default();
        std::thread::sleep(std::time::Duration::from_millis(200));
        let detail = if last_err.is_empty() {
            format!("本地 AI 部署脚本失败 (退出码 {:?})", status.code())
        } else {
            last_err
        };
        return Err(if tail.trim().is_empty() {
            detail
        } else {
            format!("{detail}\n---\n{}", tail.trim())
        });
    }

    // 记下路径, 主程序要用来找 Ollama
    let cfg = format!(
        "{{\n  \"ollamaDir\": {},\n  \"modelsDir\": {},\n  \"model\": \"hunyuan-mt\",\n  \"quant\": \"{}\"\n}}\n",
        json_str(&ollama_dir.display().to_string()),
        json_str(&models_dir.display().to_string()),
        quant
    );
    let _ = std::fs::write(opt.root.join("ai_config.json"), cfg);

    (prog.report)(100, "本地 AI 翻译已就绪".into());
    Ok(())
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// 生成部署脚本。这个脚本是整件事的执行体:
/// 装 Ollama -> 下载模型 -> 导入 -> 自检, 每步都打印 SKYAI 进度行。
fn write_script(
    opt: &AiOptions,
    quant: &str,
    models_dir: &PathBuf,
    model_dir: &PathBuf,
) -> Result<PathBuf, String> {
    let url = model_url(quant);
    let gguf_name = format!("Hunyuan-MT-7B.{quant}.gguf");
    let gguf = model_dir.join(&gguf_name);
    let mf = opt.root.join("Modelfile");

    let script = format!(
        r#"$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say($pct, $msg) {{ Write-Output "SKYAI $pct $msg" }}
function Fail($msg) {{ Write-Output "SKYERR $msg"; exit 1 }}

$ModelsDir = '{models}'
$ModelDir  = '{mdir}'
$Gguf      = '{gguf}'
$Url       = '{url}'
$Modelfile = '{mf}'
$ModelName = 'hunyuan-mt'

New-Item -ItemType Directory -Force -Path $ModelsDir, $ModelDir | Out-Null

# ---------- 1. Ollama ----------
try {{
  $ollamaExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
  if (Test-Path $ollamaExe) {{
    Say 6 'Ollama 已安装，跳过'
  }} else {{
    Say 2 '正在下载 Ollama 推理引擎（约 1.5 GB）…'
    $setup = Join-Path $env:TEMP 'OllamaSetup_sky.exe'
    $req = [System.Net.HttpWebRequest]::Create('https://ollama.com/download/OllamaSetup.exe')
    $req.Timeout = 60000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse(); $total = $resp.ContentLength
    $rs = $resp.GetResponseStream(); $fs = [System.IO.File]::Create($setup)
    $buf = New-Object byte[] 1048576; $read = 0; $last = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {{
      $fs.Write($buf, 0, $n); $read += $n
      if ($sw.Elapsed.TotalSeconds - $last -ge 2) {{
        $last = $sw.Elapsed.TotalSeconds
        $pct = if ($total -gt 0) {{ [int](2 + 8.0 * $read / $total) }} else {{ 5 }}
        Say $pct ('正在下载 Ollama 推理引擎  {{0:N0}}/{{1:N0}} MB' -f ($read/1MB), ($total/1MB))
      }}
    }}
    $fs.Close(); $rs.Close(); $resp.Close()
    Say 10 '正在安装 Ollama…'
    Start-Process -FilePath $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOCANCEL' -Wait
    Remove-Item $setup -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    if (-not (Test-Path $ollamaExe)) {{ Fail 'Ollama 安装后找不到 ollama.exe' }}
  }}
}} catch {{ Fail "Ollama 安装失败: $($_.Exception.Message)" }}

# ---------- 2. 模型 ----------
try {{
  $needDl = $true
  if (Test-Path $Gguf) {{
    $sz = (Get-Item $Gguf).Length
    if ($sz -gt 3GB) {{ Say 62 '模型文件已存在，跳过下载'; $needDl = $false }}
  }}
  if ($needDl) {{
    Say 12 '正在下载翻译模型 Hunyuan-MT-7B（约 4.4 GB，视网速 10-30 分钟）…'
    $tmp = "$Gguf.part"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 60000; $req.ReadWriteTimeout = 180000; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse(); $total = $resp.ContentLength
    if ($total -le 0) {{ Fail '无法获取模型大小，下载源可能不可达' }}
    $rs = $resp.GetResponseStream(); $fs = [System.IO.File]::Create($tmp)
    $buf = New-Object byte[] 1048576; $read = 0; $last = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {{
      $fs.Write($buf, 0, $n); $read += $n
      if ($sw.Elapsed.TotalSeconds - $last -ge 2) {{
        $last = $sw.Elapsed.TotalSeconds
        $spd = $read / 1MB / [Math]::Max($sw.Elapsed.TotalSeconds, 0.01)
        $eta = [int](($total - $read) / 1MB / [Math]::Max($spd, 0.01) / 60)
        $pct = [int](12 + 50.0 * $read / $total)
        Say $pct ('正在下载翻译模型  {{0:N0}}/{{1:N0}} MB  {{2:N1}} MB/s  剩余约 {{3}} 分钟' -f `
                  ($read/1MB), ($total/1MB), $spd, $eta)
      }}
    }}
    $fs.Close(); $rs.Close(); $resp.Close()
    Move-Item $tmp $Gguf -Force
  }}
}} catch {{ Fail "模型下载失败: $($_.Exception.Message)" }}

# ---------- 3. 导入 ----------
try {{
  Say 64 '正在配置 Ollama 运行参数…'
  [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $ModelsDir, 'User')
  [Environment]::SetEnvironmentVariable('OLLAMA_FLASH_ATTENTION', '1', 'User')
  [Environment]::SetEnvironmentVariable('OLLAMA_KV_CACHE_TYPE', 'q8_0', 'User')
  [Environment]::SetEnvironmentVariable('OLLAMA_KEEP_ALIVE', '10m', 'User')
  [Environment]::SetEnvironmentVariable('OLLAMA_MAX_LOADED_MODELS', '1', 'User')
  $env:OLLAMA_MODELS = $ModelsDir

  # 停掉旧进程让新环境变量生效
  Get-Process | Where-Object {{ $_.ProcessName -like '*ollama*' }} | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden
  Say 68 '正在启动推理服务…'
  $ok = $false
  for ($i = 0; $i -lt 25; $i++) {{
    Start-Sleep -Seconds 2
    try {{ Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 4 | Out-Null; $ok = $true; break }} catch {{ }}
  }}
  if (-not $ok) {{ Fail 'Ollama 服务启动超时，请手动运行 ollama serve 后重试' }}

  $mfText = @"
FROM $Gguf
PARAMETER temperature 0.7
PARAMETER top_p 0.6
PARAMETER top_k 20
PARAMETER repeat_penalty 1.05
PARAMETER num_ctx 4096
PARAMETER num_predict 2048
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"
"@
  Set-Content -Path $Modelfile -Value $mfText -Encoding UTF8

  Say 72 '正在导入模型（要复制一份 4.4GB，约 1-2 分钟）…'
  # 不要看 $LASTEXITCODE: ollama 把进度写到 stderr, PowerShell 会把
  # 原生命令的 stderr 当成 NativeCommandError, 退出码会被污染成 -1,
  # 明明导入成功也会误判失败。改成把两个流都落到文件, 最后**以
  # ollama list 的实际结果为准**。
  $ocOut = Join-Path $env:TEMP 'sky_ollama_create.out'
  $ocErr = Join-Path $env:TEMP 'sky_ollama_create.err'
  Remove-Item $ocOut, $ocErr -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = 'Continue'
  Start-Process -FilePath $ollamaExe `
    -ArgumentList @('create', $ModelName, '-f', $Modelfile) `
    -Wait -NoNewWindow -RedirectStandardOutput $ocOut -RedirectStandardError $ocErr
  $ErrorActionPreference = 'Stop'

  $lst = ''
  try {{ $lst = (& $ollamaExe list 2>$null | Out-String) }} catch {{ }}
  if ($lst -notmatch [regex]::Escape($ModelName)) {{
    $tail = ''
    foreach ($f in @($ocErr, $ocOut)) {{
      if (Test-Path $f) {{
        $tail += ((Get-Content $f -Tail 4 -ErrorAction SilentlyContinue) -join ' / ')
      }}
    }}
    Fail "模型导入失败: $tail"
  }}

  Say 92 '正在自检（首次要把模型读进显存，约 20 秒）…'
  $body = @{{
    model = $ModelName
    prompt = "把下面的文本翻译成中文，不要额外解释。`n`nHello, this is a test."
    stream = $false
    options = @{{ temperature = 0.7; top_p = 0.6; top_k = 20; repeat_penalty = 1.05 }}
  }} | ConvertTo-Json -Depth 5 -Compress
  $r = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post `
       -Body $body -ContentType 'application/json' -TimeoutSec 300
  if (-not $r.response) {{ Fail '模型自检没有返回结果' }}
  Say 98 ('自检通过：' + $r.response.Trim())
}} catch {{ Fail "模型导入失败: $($_.Exception.Message)" }}

Say 100 '本地 AI 翻译部署完成'
exit 0
"#,
        models = models_dir.display(),
        mdir = model_dir.display(),
        gguf = gguf.display(),
        url = url,
        mf = mf.display(),
    );

    let path = std::env::temp_dir().join("sky_ai_deploy.ps1");
    // PowerShell 5.1 读无 BOM 的 UTF-8 会当 GBK, 中文全乱 —— 必须带 BOM
    let mut bytes: Vec<u8> = vec![0xEF, 0xBB, 0xBF];
    bytes.extend_from_slice(script.as_bytes());
    std::fs::write(&path, bytes).map_err(|e| format!("写部署脚本失败: {e}"))?;
    Ok(path)
}

use std::os::windows::process::CommandExt;
