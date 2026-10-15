//! ONNX Runtime 环境与 Session 构建辅助

use crate::error::{OrtExt, Result};
use ort::environment::Environment;
use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use std::path::Path;
use std::sync::OnceLock;

/// 进程级唯一的 ONNX Runtime 环境。
///
/// ONNX Runtime 限制**每个进程只能创建一个 Environment**, 因此 OCR 引擎与
/// 离线翻译引擎必须共用同一个 —— 否则第二个会报
/// "only one environment is allowed per process"。
static GLOBAL_ENV: OnceLock<Environment> = OnceLock::new();

/// 初始化 (或复用) 全局 ONNX Runtime 环境
///
/// `dylib` 为 `onnxruntime.dll` / `libonnxruntime.so` 的路径 (load-dynamic 模式)。
/// 首次调用决定动态库位置, 之后忽略该参数。
pub fn global_env(dylib: Option<&Path>) -> Result<&'static Environment> {
    if let Some(e) = GLOBAL_ENV.get() {
        return Ok(e);
    }
    let builder = match dylib {
        Some(p) => ort::init_from(p).ort_ctx("加载 onnxruntime 动态库")?,
        None => ort::init(),
    };
    let env = builder
        .with_name("dpg-ocr")
        .build()
        .ort_ctx("创建 ONNX Runtime 环境")?;
    // 并发首次调用时 set 可能失败, 此时用已有的那个
    let _ = GLOBAL_ENV.set(env);
    GLOBAL_ENV
        .get()
        .ok_or_else(|| crate::error::DpgError::rt("全局 ONNX Runtime 环境初始化失败"))
}

/// 兼容旧签名
pub fn init_runtime(dylib: Option<&Path>, _intra_threads: i32) -> Result<&'static Environment> {
    global_env(dylib)
}

/// 构建一个 Session
///
/// * `threads` ONNX Runtime intra-op 线程数 (<=0 表示交给 ORT 自行决定)
pub fn build_session(env: &Environment, path: &Path, threads: i32) -> Result<Session> {    if !path.exists() {
        return Err(crate::error::DpgError::cfg(format!(
            "模型文件不存在: {}",
            path.display()
        )));
    }
    let mut b = Session::builder(env).ort_ctx("创建 SessionBuilder")?;
    b = b
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .ort_ctx("设置图优化级别")?;
    if threads > 0 {
        b = b.with_intra_threads(threads as usize).ort_ctx("设置 intra 线程数")?;
    }
    b.commit_from_file(path)
        .ort_ctx(&format!("加载模型 {}", path.display()))
}

/// 取 Session 的第一个输入名 (PP-OCR 系列模型都是单输入)
pub fn first_input_name(session: &Session) -> Result<String> {
    session
        .inputs()
        .first()
        .map(|o| o.name().to_string())
        .ok_or_else(|| crate::error::DpgError::rt("模型没有输入节点"))
}

/// 输出张量的形状描述, 便于诊断
pub fn shape_to_string(shape: &ort::value::Shape) -> String {
    let dims: Vec<String> = shape.iter().map(|d| d.to_string()).collect();
    format!("[{}]", dims.join(", "))
}
