//! 离线翻译: Marian / OPUS-MT (ONNX)
//!
//! 一次翻译一个 `(src, tgt)` 语言对, 模型来自 Helsinki-NLP 的 OPUS-MT,
//! 由 Xenova 转换为 ONNX (int8 动态量化)。
//!
//! 目录约定 (每个语言对一个子目录):
//! ```text
//! <root>/en-zh/
//!   config.json      HF 配置 (d_model / heads / layers / 特殊 token id)
//!   tokenizer.json   HuggingFace 分词器
//!   encoder.onnx     input_ids + attention_mask -> last_hidden_state
//!   decoder.onnx     decoder_model_merged: 带 KV cache 的增量解码
//! ```
//!
//! 解码用贪心 + KV cache。Marian 的 decoder 是 "merged" 结构:
//! 通过 `use_cache_branch` 在"首次前向"和"增量前向"之间切换,
//! 首次前向需要喂 **长度为 0 的 past 张量**。

use crate::error::{DpgError, OrtExt, Result};
use crate::ort_util::build_session;
use ort::environment::Environment;
use ort::session::{Session, SessionInputValue, SessionInputs};
use ort::value::Tensor;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::path::{Path, PathBuf};
use tokenizers::Tokenizer;

/// 一个语言对的翻译模型描述
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslateModelSpec {
    /// 语言对标识, 如 "en-zh"
    pub pair: String,
    /// 模型目录
    pub dir: PathBuf,
}

/// 运行期配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarianOptions {
    /// 单句最多生成多少 token
    #[serde(default = "d_max_new")]
    pub max_new_tokens: usize,
    /// 输入超过多少 token 就截断 (Marian 位置编码上限 512)
    #[serde(default = "d_max_src")]
    pub max_source_tokens: usize,
}

fn d_max_new() -> usize {
    256
}
fn d_max_src() -> usize {
    400
}

impl Default for MarianOptions {
    fn default() -> Self {
        Self {
            max_new_tokens: d_max_new(),
            max_source_tokens: d_max_src(),
        }
    }
}

struct PastSpec {
    input: String,
    output: String,
    /// true = decoder 自注意力的 K/V (长度随解码增长); false = 交叉注意力 (固定为源长度)
    is_decoder: bool,
}

pub struct MarianTranslator {
    enc: Session,
    dec: Session,
    tokenizer: Tokenizer,
    opts: MarianOptions,

    past_specs: Vec<PastSpec>,
    num_heads: usize,
    head_dim: usize,
    vocab_size: usize,
    decoder_start_id: i64,
    eos_id: i64,
    pub pair: String,
    pub dir: PathBuf,
}

impl MarianTranslator {
    /// 从语言对目录加载
    pub fn from_dir(
        env: &Environment,
        pair: &str,
        dir: &Path,
        threads: i32,
        opts: MarianOptions,
    ) -> Result<Self> {
        let cfg_path = dir.join("config.json");
        let tok_path = dir.join("tokenizer.json");
        let enc_path = dir.join("encoder.onnx");
        let dec_path = dir.join("decoder.onnx");
        for p in [&cfg_path, &tok_path, &enc_path, &dec_path] {
            if !p.exists() {
                return Err(DpgError::cfg(format!(
                    "离线翻译模型文件缺失: {}",
                    p.display()
                )));
            }
        }

        let cfg: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&cfg_path)?)?;
        let num_heads = cfg["decoder_attention_heads"].as_u64().unwrap_or(8) as usize;
        let d_model = cfg["d_model"].as_u64().unwrap_or(512) as usize;
        let layers = cfg["decoder_layers"].as_u64().unwrap_or(6) as usize;
        let vocab_size = cfg["vocab_size"].as_u64().unwrap_or(65001) as usize;
        let decoder_start_id = cfg["decoder_start_token_id"]
            .as_i64()
            .or_else(|| cfg["pad_token_id"].as_i64())
            .unwrap_or(65000);
        let eos_id = cfg["eos_token_id"].as_i64().unwrap_or(0);
        if num_heads == 0 || d_model % num_heads != 0 {
            return Err(DpgError::cfg(format!(
                "配置异常: d_model={d_model} 不能被 heads={num_heads} 整除"
            )));
        }
        let head_dim = d_model / num_heads;

        let enc = build_session(env, &enc_path, threads)?;
        let dec = build_session(env, &dec_path, threads)?;

        // 枚举 past_key_values.* 输入, 并推出对应的 present.* 输出名
        let mut past_specs = Vec::with_capacity(layers * 4);
        for inp in dec.inputs() {
            let name = inp.name();
            if let Some(rest) = name.strip_prefix("past_key_values.") {
                past_specs.push(PastSpec {
                    input: name.to_string(),
                    output: format!("present.{rest}"),
                    is_decoder: name.contains(".decoder."),
                });
            }
        }
        if past_specs.is_empty() {
            return Err(DpgError::cfg(
                "decoder 模型没有 past_key_values 输入, 需要 decoder_model_merged 版本",
            ));
        }

        let tokenizer = load_tokenizer(&tok_path)?;

        Ok(Self {
            enc,
            dec,
            tokenizer,
            opts,
            past_specs,
            num_heads,
            head_dim,
            vocab_size,
            decoder_start_id,
            eos_id,
            pair: pair.to_string(),
            dir: dir.to_path_buf(),
        })
    }

    /// 翻译单句
    pub fn translate(&mut self, text: &str) -> Result<String> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Ok(String::new());
        }

        // ---------- 1. 分词 ----------
        let enc = self
            .tokenizer
            .encode(trimmed, true)
            .map_err(|e| DpgError::rt(format!("分词失败: {e}")))?;
        let mut src_ids: Vec<i64> = enc.get_ids().iter().map(|&x| x as i64).collect();
        if src_ids.len() > self.opts.max_source_tokens {
            src_ids.truncate(self.opts.max_source_tokens);
        }
        let src_len = src_ids.len();
        if src_len == 0 {
            return Ok(String::new());
        }

        // ---------- 2. 编码 ----------
        let mask = vec![1i64; src_len];
        let t_ids =
            Tensor::from_array((vec![1usize, src_len], src_ids)).ort_ctx("encoder input_ids")?;
        let t_mask =
            Tensor::from_array((vec![1usize, src_len], mask)).ort_ctx("encoder attention_mask")?;
        let enc_feeds: Vec<(Cow<str>, SessionInputValue)> = vec![
            (Cow::Borrowed("input_ids"), t_ids.into()),
            (Cow::Borrowed("attention_mask"), t_mask.into()),
        ];
        let enc_outs = self
            .enc
            .run(SessionInputs::from(enc_feeds))
            .ort_ctx("编码器推理")?;
        let enc_out = enc_outs
            .iter()
            .next()
            .map(|(_, v)| v)
            .ok_or_else(|| DpgError::rt("编码器没有输出"))?;
        let (_, hidden) = enc_out
            .try_extract_tensor::<f32>()
            .ort_ctx("读取编码器输出")?;
        let hidden: Vec<f32> = hidden.to_vec();

        // 交叉注意力的 K/V 在整段解码中不变, 用与输入等长的全 1 掩码
        let enc_mask_vec = vec![1i64; src_len];

        // ---------- 3. 贪心解码 (带 KV cache) ----------
        let mut past: Option<Vec<Vec<f32>>> = None;
        // 交叉注意力 K/V, 整段解码不变, 只在第一步取一次
        let mut enc_kv: Option<Vec<Vec<f32>>> = None;
        let mut past_len = 0usize;
        let mut cur = self.decoder_start_id;
        let mut out_ids: Vec<i64> = Vec::with_capacity(64);

        for step in 0..self.opts.max_new_tokens {
            let first = step == 0;
            let mut feeds: Vec<(Cow<str>, SessionInputValue)> =
                Vec::with_capacity(self.past_specs.len() + 5);

            let t_cur =
                Tensor::from_array((vec![1usize, 1usize], vec![cur])).ort_ctx("decoder input_ids")?;
            let t_emask = Tensor::from_array((vec![1usize, src_len], enc_mask_vec.clone()))
                .ort_ctx("decoder encoder_attention_mask")?;
            let t_hidden = Tensor::from_array((
                vec![1usize, src_len, self.head_dim * self.num_heads],
                hidden.clone(),
            ))
            .ort_ctx("decoder encoder_hidden_states")?;

            feeds.push((Cow::Borrowed("input_ids"), t_cur.into()));
            feeds.push((Cow::Borrowed("encoder_attention_mask"), t_emask.into()));
            feeds.push((Cow::Borrowed("encoder_hidden_states"), t_hidden.into()));

            for (i, spec) in self.past_specs.iter().enumerate() {
                // 首次前向 (use_cache_branch=false) 时, 所有 past 张量的序列维
                // 都必须是 0 —— 包括交叉注意力的 K/V, 它们由模型内部算出。
                //
                // 交叉注意力的 K/V 在整段解码中恒定不变, 这里用 `enc_kv` 固化,
                // 只在第一步取一次 —— 增量分支下模型返回的 present.*.encoder.*
                // 是空张量, 每步回读会拿到 0 元素。
                let (len, data) = if spec.is_decoder {
                    match &past {
                        None => (0usize, Vec::new()),
                        Some(p) => (past_len, p[i].clone()),
                    }
                } else {
                    match &enc_kv {
                        None => (0usize, Vec::new()),
                        Some(p) => (src_len, p[i].clone()),
                    }
                };
                let shape = vec![1usize, self.num_heads, len, self.head_dim];
                let expect: usize = shape.iter().product();
                if data.len() != expect {
                    return Err(DpgError::rt(format!(
                        "past 张量尺寸不符: step={step} input={} is_decoder={} len={len} \
                         data={} expect={expect} past_len={past_len} src_len={src_len}",
                        spec.input,
                        spec.is_decoder,
                        data.len()
                    )));
                }
                let t = Tensor::from_array((shape, data)).ort_ctx("decoder past 张量")?;
                feeds.push((Cow::Owned(spec.input.clone()), t.into()));
            }

            let t_branch = Tensor::from_array((vec![1usize], vec![!first]))
                .ort_ctx("decoder use_cache_branch")?;
            feeds.push((Cow::Borrowed("use_cache_branch"), t_branch.into()));

            let outs = self
                .dec
                .run(SessionInputs::from(feeds))
                .ort_ctx("解码器推理")?;

            // logits 是 ONNX 图的第一个输出 ([1, 1, vocab])
            let logits_val = outs
                .iter()
                .next()
                .map(|(_, v)| v)
                .ok_or_else(|| DpgError::rt("解码器没有输出"))?;
            let (shape, logits) = logits_val
                .try_extract_tensor::<f32>()
                .ort_ctx("读取解码器 logits")?;
            let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
            if dims.len() != 3 {
                return Err(DpgError::rt(format!("logits 维度异常: {:?}", dims)));
            }
            let vocab = dims[2];
            if logits.len() < vocab {
                return Err(DpgError::rt("logits 长度不足"));
            }
            let mut best = 0usize;
            let mut best_v = f32::NEG_INFINITY;
            for (i, &v) in logits[..vocab].iter().enumerate() {
                if v > best_v {
                    best_v = v;
                    best = i;
                }
            }

            if best as i64 == self.eos_id {
                break;
            }
            out_ids.push(best as i64);
            cur = best as i64;

            // 首次前向: 一次性固化交叉注意力的 K/V
            if enc_kv.is_none() {
                let mut e = vec![Vec::new(); self.past_specs.len()];
                for (i, spec) in self.past_specs.iter().enumerate() {
                    if spec.is_decoder {
                        continue;
                    }
                    let val = outs.get(&spec.output).ok_or_else(|| {
                        DpgError::rt(format!("首次前向缺少输出 {}", spec.output))
                    })?;
                    let (_, data) =
                        val.try_extract_tensor::<f32>().ort_ctx("读取交叉注意力 K/V")?;
                    if data.is_empty() {
                        return Err(DpgError::rt(format!(
                            "交叉注意力 K/V 为空: {}",
                            spec.output
                        )));
                    }
                    e[i] = data.to_vec();
                }
                enc_kv = Some(e);
            }

            // decoder 的 KV 每步增长, 从 present.* 回读
            let mut next: Vec<Vec<f32>> = match past.take() {
                Some(p) => p,
                None => vec![Vec::new(); self.past_specs.len()],
            };
            for (i, spec) in self.past_specs.iter().enumerate() {
                if !spec.is_decoder {
                    continue; // 交叉注意力 K/V 已固化, 不需要每步更新
                }
                let val = outs
                    .get(&spec.output)
                    .ok_or_else(|| DpgError::rt(format!("解码器缺少输出 {}", spec.output)))?;
                let (_, data) = val.try_extract_tensor::<f32>().ort_ctx("读取 present 张量")?;
                if data.is_empty() {
                    return Err(DpgError::rt(format!("present 张量为空: {}", spec.output)));
                }
                next[i] = data.to_vec();
            }
            past_len += 1;
            past = Some(next);

            // 安全阀: 源长度 3 倍还没结束就放弃
            if out_ids.len() > self.opts.max_new_tokens.min(src_len * 3 + 16) {
                break;
            }
        }

        // ---------- 4. 反分词 ----------
        let ids: Vec<u32> = out_ids.iter().map(|&x| x as u32).collect();
        let text = self
            .tokenizer
            .decode(&ids, true)
            .map_err(|e| DpgError::rt(format!("反分词失败: {e}")))?;
        Ok(text.trim().to_string())
    }

    pub fn vocab_size(&self) -> usize {
        self.vocab_size
    }

    pub fn num_layers(&self) -> usize {
        self.past_specs.len() / 4
    }
}

/// 加载 HuggingFace tokenizer.json
///
/// OPUS-MT 用的是 SentencePiece 的 `Precompiled` 归一化, 在 `tokenizers`
/// crate 里需要 oniguruma (C 库)。为了不给 Windows/Android 引入额外 C 工具链,
/// 这里把归一化替换成等价的 NFKC —— 对 `nmt_nfkc` 而言差异仅在少量特殊
/// 标点映射上, 对翻译质量没有可观察影响。
fn load_tokenizer(path: &Path) -> Result<Tokenizer> {
    let raw = std::fs::read_to_string(path)?;
    let mut v: serde_json::Value = serde_json::from_str(&raw)?;
    let is_precompiled = v
        .get("normalizer")
        .and_then(|n| n.get("type"))
        .and_then(|t| t.as_str())
        == Some("Precompiled");
    if is_precompiled {
        v["normalizer"] = serde_json::json!({ "type": "NFKC" });
    }
    let tok: Tokenizer = serde_json::from_value(v)
        .map_err(|e| DpgError::cfg(format!("加载分词器失败 ({}): {e}", path.display())))?;
    Ok(tok)
}
