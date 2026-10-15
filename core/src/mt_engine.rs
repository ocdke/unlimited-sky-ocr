//! 离线翻译引擎: 按语言对管理 Marian 模型
//!
//! 模型按需加载 —— 启动时只扫描有哪些语言对可用, 真正用到某个方向时才把
//! 该方向的 encoder/decoder 载入内存 (单个方向约 108 MB)。

use crate::error::{DpgError, Result};
use crate::ort_util::global_env;
use crate::translate::{MarianOptions, MarianTranslator};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MtConfig {
    /// 语言对模型根目录, 其下每个子目录是一个语言对 (如 en-zh)
    pub model_root: PathBuf,
    #[serde(default)]
    pub onnxruntime_dll: Option<PathBuf>,
    #[serde(default)]
    pub threads: i32,
    #[serde(default)]
    pub options: MarianOptions,
}

pub struct MtEngine {
    root: PathBuf,
    threads: i32,
    opts: MarianOptions,
    loaded: HashMap<String, MarianTranslator>,
}

impl MtEngine {
    pub fn new(cfg: MtConfig) -> Result<Self> {
        if !cfg.model_root.exists() {
            return Err(DpgError::cfg(format!(
                "离线翻译模型目录不存在: {}",
                cfg.model_root.display()
            )));
        }
        // 复用进程级唯一环境
        let _ = global_env(cfg.onnxruntime_dll.as_deref())?;
        Ok(Self {
            root: cfg.model_root,
            threads: cfg.threads,
            opts: cfg.options,
            loaded: HashMap::new(),
        })
    }

    /// 扫描根目录下可用的语言对 (子目录名, 如 "en-zh")
    pub fn available_pairs(&self) -> Vec<String> {
        let mut v = Vec::new();
        if let Ok(rd) = std::fs::read_dir(&self.root) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() && p.join("encoder.onnx").exists() && p.join("decoder.onnx").exists()
                {
                    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                        v.push(name.to_string());
                    }
                }
            }
        }
        v.sort();
        v
    }

    pub fn is_loaded(&self, pair: &str) -> bool {
        self.loaded.contains_key(pair)
    }

    /// 按需加载某个语言对
    fn ensure_loaded(&mut self, pair: &str) -> Result<()> {
        if self.loaded.contains_key(pair) {
            return Ok(());
        }
        let dir = self.root.join(pair);
        if !dir.exists() {
            return Err(DpgError::cfg(format!(
                "没有 {pair} 方向的离线模型 (查找路径: {})",
                dir.display()
            )));
        }
        let env = global_env(None)?;
        let t = MarianTranslator::from_dir(env, pair, &dir, self.threads, self.opts.clone())?;
        self.loaded.insert(pair.to_string(), t);
        Ok(())
    }

    /// 翻译单句
    pub fn translate(&mut self, pair: &str, text: &str) -> Result<String> {
        self.ensure_loaded(pair)?;
        let t = self
            .loaded
            .get_mut(pair)
            .ok_or_else(|| DpgError::rt("语言对加载失败"))?;
        t.translate(text)
    }

    /// 批量翻译: 模型只加载一次, 逐句解码
    pub fn translate_batch(&mut self, pair: &str, texts: &[String]) -> Result<Vec<String>> {
        self.ensure_loaded(pair)?;
        let t = self
            .loaded
            .get_mut(pair)
            .ok_or_else(|| DpgError::rt("语言对加载失败"))?;
        let mut out = Vec::with_capacity(texts.len());
        for s in texts {
            out.push(t.translate(s)?);
        }
        Ok(out)
    }

    /// 释放已加载的模型 (例如切换语言对时)
    pub fn unload_all(&mut self) {
        self.loaded.clear();
    }

    pub fn loaded_pairs(&self) -> Vec<String> {
        let mut v: Vec<String> = self.loaded.keys().cloned().collect();
        v.sort();
        v
    }
}

/// 语言对 "en-zh" -> (src, tgt)
pub fn split_pair(pair: &str) -> Option<(String, String)> {
    let mut it = pair.splitn(2, '-');
    let a = it.next()?.to_string();
    let b = it.next()?.to_string();
    if a.is_empty() || b.is_empty() {
        None
    } else {
        Some((a, b))
    }
}

/// 按需推断语言对名 (用于自动选择方向)
pub fn pair_name(src: &str, tgt: &str) -> String {
    format!("{}-{}", normalize(src), normalize(tgt))
}

/// 把 BCP-47 / 通用语言码归一到模型命名用的短码
pub fn normalize(code: &str) -> String {
    let lower = code.to_ascii_lowercase();
    let base = lower.split(['-', '_']).next().unwrap_or(&lower);
    match base {
        "zh" | "cmn" | "chi" => "zh".to_string(),
        "en" | "eng" => "en".to_string(),
        "ja" | "jpn" => "ja".to_string(),
        "ko" | "kor" => "ko".to_string(),
        "ru" | "rus" => "ru".to_string(),
        "fr" | "fra" => "fr".to_string(),
        "de" | "deu" | "ger" => "de".to_string(),
        "es" | "spa" => "es".to_string(),
        other => other.to_string(),
    }
}

#[allow(dead_code)]
fn _unused(_: &Path) {}
