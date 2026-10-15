//! 统一错误类型

use std::fmt;

pub type Result<T> = std::result::Result<T, DpgError>;

#[derive(Debug)]
pub enum DpgError {
    Io(std::io::Error),
    Image(image::ImageError),
    Json(serde_json::Error),
    /// ONNX Runtime 相关错误 (统一转字符串, 避免 ort::Error 泛型参数带来的耦合)
    Ort(String),
    /// 配置/参数错误
    Config(String),
    /// 运行时错误
    Runtime(String),
}

impl fmt::Display for DpgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DpgError::Io(e) => write!(f, "IO 错误: {e}"),
            DpgError::Image(e) => write!(f, "图像解码错误: {e}"),
            DpgError::Json(e) => write!(f, "JSON 错误: {e}"),
            DpgError::Ort(e) => write!(f, "ONNX Runtime 错误: {e}"),
            DpgError::Config(e) => write!(f, "配置错误: {e}"),
            DpgError::Runtime(e) => write!(f, "运行时错误: {e}"),
        }
    }
}

impl std::error::Error for DpgError {}

impl From<std::io::Error> for DpgError {
    fn from(e: std::io::Error) -> Self {
        DpgError::Io(e)
    }
}
impl From<image::ImageError> for DpgError {
    fn from(e: image::ImageError) -> Self {
        DpgError::Image(e)
    }
}
impl From<serde_json::Error> for DpgError {
    fn from(e: serde_json::Error) -> Self {
        DpgError::Json(e)
    }
}

impl DpgError {
    pub fn ort(e: impl fmt::Display) -> Self {
        DpgError::Ort(e.to_string())
    }
    pub fn cfg(e: impl Into<String>) -> Self {
        DpgError::Config(e.into())
    }
    pub fn rt(e: impl Into<String>) -> Self {
        DpgError::Runtime(e.into())
    }
}

/// 便于把 `ort::Result<T>` 直接 `?` 上来
pub trait OrtExt<T> {
    fn ort_ctx(self, ctx: &str) -> Result<T>;
}

impl<T, E: fmt::Display> OrtExt<T> for std::result::Result<T, E> {
    fn ort_ctx(self, ctx: &str) -> Result<T> {
        self.map_err(|e| DpgError::Ort(format!("{ctx}: {e}")))
    }
}
