//! DPG OCR 推理内核
//!
//! 一套代码同时服务 Windows 与 Android:
//!   * `det`     PP-OCRv5 DB 文本检测
//!   * `cls`     PP-LCNet 文本行方向分类 (0/180)
//!   * `rec`     PP-OCRv5 CTC 多语种识别
//!   * `engine`  引擎编排 + 多语种自动重试
//!   * `ffi`     C ABI, 供 Flutter / Dart FFI 调用
//!   * `capture_win`  Windows GDI 截屏

pub mod capture_win;
pub mod cls;
pub mod contours;
pub mod det;
pub mod dict;
pub mod engine;
pub mod error;
pub mod ffi;
pub mod geometry;
pub mod filter;
pub mod image_utils;
pub mod mt_engine;
pub mod ort_util;
pub mod platform;
pub mod filedlg;
pub mod rec;
pub mod translate;

pub use cls::{ClsConfig, ClsNorm, ClsOutput, TextAngleClassifier};
pub use det::{DetBox, DetConfig, DetOutput, DetResizeMode, DbDetector, LimitType};
pub use engine::{EngineConfig, OcrEngine, OcrLine, OcrOptions, OcrResult, RecModelSpec};
pub use error::{DpgError, Result};
pub use geometry::Pt;
pub use mt_engine::{pair_name, split_pair, MtConfig, MtEngine};
pub use rec::{RecConfig, RecOutput, TextRecognizer};
pub use translate::{MarianOptions, MarianTranslator, TranslateModelSpec};

/// 便捷入口: 用标准模型目录建引擎 (Windows/Linux/macOS CLI 与测试用)
pub fn build_standard_engine(
    model_root: &std::path::Path,
    onnxruntime_dll: Option<std::path::PathBuf>,
    threads: i32,
) -> Result<OcrEngine> {
    const LANGS: &[&str] = &[
        "ch", "en", "latin", "cyrillic", "korean", "arabic", "devanagari", "el", "eslav", "th",
        "ta", "te",
    ];
    let mut cfg = EngineConfig::standard(model_root, onnxruntime_dll, LANGS);
    cfg.intra_threads = threads;
    OcrEngine::new(cfg)
}
