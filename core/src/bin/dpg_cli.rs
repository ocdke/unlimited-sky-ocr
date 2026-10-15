//! DPG OCR 命令行工具 — 用于精度/速度基准测试与参数调优
//!
//! 用法:
//!   dpg-cli info  --models <模型根目录> --dll <onnxruntime.dll>
//!   dpg-cli run   --models <dir> --dll <dll> --image <path> [--lang ch] [--noise 1] [--json]
//!   dpg-cli bench --models <dir> --dll <dll> --image <path> [--repeat 5]
//!                 [--det-preset official|rapid] [--cls-preset official|rapid|off]
//!                 [--limit 960] [--threads 8]

use dpg_core::det::DetConfig;
use dpg_core::engine::{EngineConfig, OcrEngine, OcrOptions};
use std::path::PathBuf;
use std::time::Instant;

struct Args {
    cmd: String,
    models: PathBuf,
    dll: Option<PathBuf>,
    image: Option<PathBuf>,
    lang: String,
    /// 噪声过滤档位 0=关闭 1=宽松 2=标准 3=严格
    noise: i32,
    /// 识别批大小 (0 = 用默认)
    batch: usize,
    /// 识别最大宽度 (0 = 用默认)
    max_width: u32,
    json: bool,
    repeat: usize,
    det_preset: String,
    cls_preset: String,
    limit: Option<u32>,
    threads: i32,
    det_only: bool,
    no_det: bool,
    min_height: Option<f32>,
    max_lines: Option<usize>,
    mt_dir: Option<PathBuf>,
    text: Option<String>,
}

fn parse_args() -> Args {
    let mut a = Args {
        cmd: "run".into(),
        models: PathBuf::from("E:\\dpg\\models"),
        dll: None,
        image: None,
        lang: "ch".into(),
    noise: 1,
    batch: 0,
    max_width: 0,
        json: false,
        repeat: 1,
        det_preset: "official".into(),
        cls_preset: "rapid".into(),
        limit: None,
        threads: 0,
        det_only: false,
        no_det: false,
        min_height: None,
        max_lines: None,
        mt_dir: None,
        text: None,
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0usize;
    if !argv.is_empty() && !argv[0].starts_with("--") {
        a.cmd = argv[0].clone();
        i = 1;
    }
    while i < argv.len() {
        let k = argv[i].clone();
        let val = argv.get(i + 1).cloned().unwrap_or_default();
        let has_val = argv.len() > i + 1;
        match k.as_str() {
            "--models" => a.models = PathBuf::from(val),
            "--dll" => a.dll = Some(PathBuf::from(val)),
            "--image" => a.image = Some(PathBuf::from(val)),
            "--lang" => a.lang = val,
            "--noise" => a.noise = val.parse().unwrap_or(1),
            "--batch" => a.batch = val.parse().unwrap_or(0),
            "--max-width" => a.max_width = val.parse().unwrap_or(0),
            "--json" => a.json = true,
            "--repeat" => a.repeat = val.parse().unwrap_or(1),
            "--det-preset" => a.det_preset = val,
            "--cls-preset" => a.cls_preset = val,
            "--limit" => a.limit = val.parse().ok(),
            "--threads" => a.threads = val.parse().unwrap_or(0),
            "--det-only" => a.det_only = true,
            "--no-det" => a.no_det = true,
            "--min-height" => a.min_height = val.parse().ok(),
            "--max-lines" => a.max_lines = val.parse().ok(),
            "--mt-dir" => a.mt_dir = Some(PathBuf::from(val)),
            "--text" => a.text = Some(val),
            _ => {}
        }
        i += if has_val && needs_value(&k) { 2 } else { 1 };
    }
    a
}

fn needs_value(k: &str) -> bool {
    matches!(
        k,
        "--models"
            | "--dll"
            | "--image"
            | "--lang"
            | "--repeat"
            | "--det-preset"
            | "--cls-preset"
            | "--limit"
            | "--threads"
            | "--min-height"
            | "--max-lines"
            | "--mt-dir"
            | "--text"
    )
}

const LANGS: &[&str] = &[
    "ch", "en", "latin", "cyrillic", "korean", "arabic", "devanagari", "el", "eslav", "th", "ta",
    "te",
];

/// 离线翻译测试: 只加载翻译模型, 不加载 OCR
fn run_mt(args: &Args) -> dpg_core::Result<()> {
    let dir = args
        .mt_dir
        .clone()
        .ok_or_else(|| dpg_core::DpgError::cfg("缺少 --mt-dir 参数"))?;
    let pair = dir
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();

    let env = dpg_core::ort_util::init_runtime(args.dll.as_deref(), args.threads)?;
    println!("加载离线翻译模型: {pair} ({})", dir.display());
    let t0 = Instant::now();
    let mut mt = dpg_core::MarianTranslator::from_dir(
        &env,
        &pair,
        &dir,
        args.threads,
        dpg_core::MarianOptions::default(),
    )?;
    println!(
        "加载完成 {:.0} ms  ({} 层, 词表 {})",
        t0.elapsed().as_secs_f64() * 1000.0,
        mt.num_layers(),
        mt.vocab_size()
    );

    let texts: Vec<String> = if let Some(t) = &args.text {
        vec![t.clone()]
    } else {
        vec![
            "Full screen OCR recognition and translation.".to_string(),
            "The application freezes the screen first, then lets you drag to select a region."
                .to_string(),
            "Recognition takes about five hundred milliseconds on a modern CPU.".to_string(),
            "Accuracy and speed are both important for a good user experience.".to_string(),
            "Please press Escape to exit the overlay at any time.".to_string(),
        ]
    };

    let mut total = 0.0f64;
    for (i, s) in texts.iter().enumerate() {
        let t = Instant::now();
        let out = mt.translate(s)?;
        let el = t.elapsed().as_secs_f64() * 1000.0;
        total += el;
        println!("{:>2}. [{:>6.1} ms] {}", i + 1, el, out);
        if args.json {
            println!("      原文: {s}");
        }
    }
    println!(
        "平均 {:.1} ms/句 ({} 句)",
        total / texts.len() as f64,
        texts.len()
    );
    Ok(())
}

fn main() {
    let args = parse_args();
    if let Err(e) = run(args) {
        eprintln!("错误: {e}");
        std::process::exit(1);
    }
}

fn run(args: Args) -> dpg_core::Result<()> {
    // 离线翻译只加载翻译模型; 必须在这里提前分派 —— ONNX Runtime
    // 每个进程只允许创建一个 Environment, 若先建 OCR 引擎就会冲突
    // ("only one environment is allowed per process")。
    if args.cmd == "mt" {
        return run_mt(&args);
    }

    let mut cfg = EngineConfig::standard(&args.models, args.dll.clone(), LANGS);
    cfg.intra_threads = args.threads;

    match args.det_preset.as_str() {
        "rapid" => cfg.det = DetConfig::rapidocr_default(),
        _ => cfg.det = DetConfig::official_v5(),
    }
    match args.cls_preset.as_str() {
        "official" => cfg.cls = dpg_core::ClsConfig::official_v5(),
        "off" => cfg.cls_model = None,
        _ => cfg.cls = dpg_core::ClsConfig::rapidocr_v5(),
    }
    if let Some(l) = args.limit {
        cfg.det.limit_side = l;
    }

    let t0 = Instant::now();
    let mut engine = OcrEngine::new(cfg)?;
    let load_ms = t0.elapsed().as_secs_f64() * 1000.0;

    match args.cmd.as_str() {
        "info" => {
            println!("引擎加载耗时: {load_ms:.1} ms");
            println!("检测模型: {}", engine.has_det());
            println!("方向分类: {}", engine.has_cls());
            println!("可用语言: {:?}", engine.available_langs());
            println!("识别模型类别数 (语言, 类别数, 字典长度, 末尾空格):");
            for (l, c, d, s) in engine.rec_info() {
                println!("  {l:<12} C={c:<7} dict={d:<7} trailing_space={s}");
            }
            Ok(())
        }
        "run" | "bench" => {
            let image = args
                .image
                .clone()
                .ok_or_else(|| dpg_core::DpgError::cfg("缺少 --image 参数"))?;
            let img = dpg_core::image_utils::decode_file(&image)?;
            println!(
                "图片: {} ({}x{}), 引擎加载 {load_ms:.1} ms",
                image.display(),
                img.width(),
                img.height()
            );

            let opts = OcrOptions {
                lang: args.lang.clone(),
                use_det: !args.no_det,
                use_cls: args.cls_preset != "off",
                auto_multilang: args.lang == "auto",
                min_line_height: args.min_height,
                max_lines: args.max_lines,
                noise_level: args.noise,
                ..Default::default()
            };
            if args.no_det {
                // 整图作为一行
            }

            let n = args.repeat.max(1);
            let mut last = None;
            let mut total = 0.0f64;
            for k in 0..n {
                let t = Instant::now();
                let res = engine.run(&img, &opts)?;
                let el = t.elapsed().as_secs_f64() * 1000.0;
                total += el;
                if k == 0 {
                    println!(
                        "首次: det {:.1} ms | cls {:.1} ms | rec {:.1} ms | 合计 {:.1} ms | {} 行",
                        res.det_ms,
                        res.cls_ms,
                        res.rec_ms,
                        res.total_ms,
                        res.lines.len()
                    );
                }
                last = Some(res);
            }
            if n > 1 {
                println!("平均 ({} 次): {:.1} ms/帧  =>  {:.1} FPS", n, total / n as f64, 1000.0 * n as f64 / total);
            }

            let res = last.unwrap();
            if args.json {
                println!("{}", serde_json::to_string_pretty(&res)?);
            } else {
                println!("--- 识别结果 ---");
                for (i, l) in res.lines.iter().enumerate() {
                    let x = l.points[0][0];
                    let y = l.points[0][1];
                    println!(
                        "{:>3}. [{:<8}] {:.3} @({:.0},{:.0}) {}",
                        i + 1,
                        l.lang,
                        l.score,
                        x,
                        y,
                        l.text
                    );
                }
            }
            Ok(())
        }
        other => Err(dpg_core::DpgError::cfg(format!("未知子命令: {other}"))),
    }
}
