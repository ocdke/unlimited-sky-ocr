//! 字符字典 (PP-OCR 系列 `*_dict.txt`)
//!
//! CTC 解码时: logits 索引 0 为 blank, 索引 i (>0) 对应字典第 i-1 项。

use crate::error::Result;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct Dict {
    chars: Vec<String>,
}

impl Dict {
    /// 与 PaddleOCR `get_dict` 完全一致的解析方式:
    /// 按 `\n` 分行, 去掉行尾 `\r`, **保留空格字符**
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let raw = std::fs::read(path)?;
        let text = String::from_utf8_lossy(&raw);
        Ok(Self::from_text(&text))
    }

    /// 从内存中的多行文本构建 (用于读取 ONNX 内嵌字典)
    pub fn from_text(text: &str) -> Self {
        let mut lines: Vec<&str> = text.split('\n').collect();
        if text.ends_with('\n') {
            lines.pop();
        }
        let chars: Vec<String> = lines
            .iter()
            .map(|l| l.strip_suffix('\r').unwrap_or(l).to_string())
            .collect();
        Self { chars }
    }

    /// 从已有的字符列表构建
    pub fn from_lines(lines: Vec<String>) -> Self {
        Self { chars: lines }
    }

    #[inline]
    pub fn get(&self, idx: usize) -> Option<&str> {
        self.chars.get(idx).map(|s| s.as_str())
    }

    /// 字典条目数 (不含 blank)
    #[inline]
    pub fn len(&self) -> usize {
        self.chars.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }

    /// CTC 输出类别数 = 字典条目 + 1 (blank)
    #[inline]
    pub fn num_classes(&self) -> usize {
        self.chars.len() + 1
    }

    pub fn chars(&self) -> &[String] {
        &self.chars
    }
}
