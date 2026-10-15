//! CTC 文本识别 (PP-OCRv5 rec / SVTR-LCNet)
//!
//! 预处理完全对齐 RapidOCR `TextRecognizer.resize_norm_img`:
//!   * 按批内最大宽高比决定输入宽度: `img_width = int(48 * max(320/48, max_wh_ratio))`
//!   * `resized_w = min(img_width, ceil(48 * w/h))`, 缩放到 `(resized_w, 48)`
//!   * BGR 顺序, 归一化 `(x/255 - 0.5)/0.5`, 右侧补 0
//!
//! 解码: 输出已带 softmax, 直接 `argmax` 取类别、`max` 取置信度;
//! CTC 折叠规则 = "与前一个原始类别不同且非 blank(0)"。

use crate::dict::Dict;
use crate::error::{DpgError, OrtExt, Result};
use crate::image_utils::resize_bilinear;
use crate::ort_util::{build_session, first_input_name};
use image::RgbImage;
use ort::environment::Environment;
use ort::session::Session;
use ort::value::Tensor;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecConfig {
    pub img_h: u32,
    /// 参考实现中的最小输入宽度 (PP-OCRv5 rec_img_shape = [3,48,320])
    pub img_w_min: u32,
    /// 单批最大样本数
    pub batch_num: usize,
    /// 输入宽度上限, 防止超长文本行导致显存/内存爆炸
    pub max_width: u32,
}

impl Default for RecConfig {
    fn default() -> Self {
        Self {
            img_h: 48,
            img_w_min: 320,
            batch_num: 8,
            max_width: 3200,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RecOutput {
    pub text: String,
    pub score: f32,
}

pub struct TextRecognizer {
    session: Session,
    input_name: String,
    dict: Dict,
    /// 类别数 = 字典条目 + 1 (blank) [+ 1 (空格)]
    num_classes: usize,
    /// 是否在字典末尾追加空格类别 (自动探测)
    has_trailing_space: bool,
    pub cfg: RecConfig,
}

/// 用一张极小的假图探测模型输出类别数 (PP-OCR rec 输出为 [B, T, C], C 固定)
fn probe_num_classes(
    session: &mut Session,
    input_name: &str,
    img_h: usize,
) -> Result<usize> {
    let w = 32usize;
    let data = vec![0f32; 3 * img_h * w];
    let tensor =
        Tensor::from_array(([1usize, 3, img_h, w], data)).ort_ctx("构造探测张量")?;
    let name = input_name.to_string();
    let outputs = session
        .run(ort::inputs![name => tensor])
        .ort_ctx("探测识别模型输出维度")?;
    let out = outputs
        .iter()
        .next()
        .map(|(_, v)| v)
        .ok_or_else(|| crate::error::DpgError::rt("识别模型没有输出"))?;
    let (shape, _) = out.try_extract_tensor::<f32>().ort_ctx("读取探测输出")?;
    let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
    dims.last()
        .copied()
        .ok_or_else(|| crate::error::DpgError::rt(format!("识别输出维度异常: {:?}", dims)))
}

/// 读取 ONNX `metadata_props["character"]` 中内嵌的字典
fn read_embedded_dict(session: &Session) -> Option<String> {
    let meta = session.metadata().ok()?;
    let s = meta.custom("character")?;
    if s.trim().is_empty() {
        None
    } else {
        Some(s)
    }
}

impl TextRecognizer {
    pub fn new(
        env: &Environment,
        model: &Path,
        dict_path: &Path,
        threads: i32,
        cfg: RecConfig,
    ) -> Result<Self> {
        let mut session = build_session(env, model, threads)?;
        let input_name = first_input_name(&session)?;
        let img_h = cfg.img_h as usize;

        // 先探测输出类别数, 再据此选择字典, 保证索引严格对齐
        let num_classes = probe_num_classes(&mut session, &input_name, img_h)?;

        // 候选 1: 模型内嵌字典 (RapidOCR 转换的 ONNX 把字典写进 metadata_props["character"]。
        //         实测其内容 = 字典文件内容 + 末尾追加一个空格, 即类别数 = len + 1)
        let mut chosen: Option<(Dict, bool)> = None;
        if let Some(text) = read_embedded_dict(&session) {
            let d = Dict::from_text(&text);
            if !d.is_empty() && d.len() + 1 == num_classes {
                chosen = Some((d, false));
            }
        }

        // 候选 2: 外部字典文件 (CTC 需要 blank + 字典 + 末尾空格 => 类别数 = len + 2)
        if chosen.is_none() {
            let d = Dict::from_file(dict_path)?;
            if d.is_empty() {
                return Err(DpgError::cfg(format!("字典为空: {}", dict_path.display())));
            }
            if d.len() + 2 == num_classes {
                chosen = Some((d, true));
            } else if d.len() + 1 == num_classes {
                chosen = Some((d, false));
            } else {
                return Err(DpgError::cfg(format!(
                    "字典与模型不匹配: {} 有 {} 项, 而模型输出 {} 类 (期望 {} 或 {})",
                    dict_path.display(),
                    d.len(),
                    num_classes,
                    d.len() + 2,
                    d.len() + 1
                )));
            }
        }

        let (dict, has_trailing_space) = chosen.unwrap();
        Ok(Self {
            session,
            input_name,
            dict,
            num_classes,
            has_trailing_space,
            cfg,
        })
    }

    #[inline]
    pub fn num_classes(&self) -> usize {
        self.num_classes
    }

    #[inline]
    pub fn dict_len(&self) -> usize {
        self.dict.len()
    }

    #[inline]
    pub fn has_trailing_space(&self) -> bool {
        self.has_trailing_space
    }

    /// 单张识别
    pub fn recognize(&mut self, img: &RgbImage) -> Result<RecOutput> {
        let mut v = self.recognize_batch(std::slice::from_ref(img))?;
        Ok(v.pop().unwrap_or(RecOutput {
            text: String::new(),
            score: 0.0,
        }))
    }

    /// 批识别: 内部按宽高比排序并分批 (与参考实现一致, 可显著加速)
    pub fn recognize_batch(&mut self, imgs: &[RgbImage]) -> Result<Vec<RecOutput>> {
        let n = imgs.len();
        let mut results: Vec<RecOutput> = vec![
            RecOutput {
                text: String::new(),
                score: 0.0,
            };
            n
        ];
        if n == 0 {
            return Ok(results);
        }

        // 按宽高比升序排列
        let mut ratios: Vec<f32> = Vec::with_capacity(n);
        for im in imgs {
            let h = im.height().max(1) as f32;
            ratios.push(im.width() as f32 / h);
        }
        let mut order: Vec<usize> = (0..n).collect();
        order.sort_by(|&a, &b| {
            ratios[a]
                .partial_cmp(&ratios[b])
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let ih = self.cfg.img_h as usize;
        let base_ratio = self.cfg.img_w_min as f32 / ih as f32;
        let batch_num = self.cfg.batch_num.max(1);

        let mut start = 0usize;
        while start < n {
            let end = (start + batch_num).min(n);
            let mut max_wh_ratio = base_ratio;
            for &oi in &order[start..end] {
                if ratios[oi] > max_wh_ratio {
                    max_wh_ratio = ratios[oi];
                }
            }
            let mut img_w = (ih as f32 * max_wh_ratio) as usize;
            img_w = img_w.clamp(ih, self.cfg.max_width as usize).max(1);

            let b = end - start;
            let plane = img_w * ih;
            let mut batch = vec![0f32; b * 3 * plane];

            for (bi, &oi) in order[start..end].iter().enumerate() {
                let img = &imgs[oi];
                let (h, w) = (img.height().max(1), img.width().max(1));
                let ratio = w as f32 / h as f32;
                let want = (ih as f32 * ratio).ceil() as usize;
                let resized_w = want.min(img_w).max(1);
                let resized = resize_bilinear(img, resized_w as u32, ih as u32);
                let raw = resized.as_raw();
                let off = bi * 3 * plane;
                for y in 0..ih {
                    for x in 0..resized_w {
                        let si = (y * resized_w + x) * 3;
                        let di = off + y * img_w + x;
                        let r = raw[si] as f32 / 255.0;
                        let g = raw[si + 1] as f32 / 255.0;
                        let bch = raw[si + 2] as f32 / 255.0;
                        // BGR 顺序 + (x - 0.5)/0.5
                        batch[di] = bch / 0.5 - 1.0;
                        batch[plane + di] = g / 0.5 - 1.0;
                        batch[2 * plane + di] = r / 0.5 - 1.0;
                    }
                }
            }

            let tensor = Tensor::from_array(([b, 3, ih, img_w], batch))
                .ort_ctx("构造识别输入张量")?;
            let name = self.input_name.clone();
            let outputs = self
                .session
                .run(ort::inputs![name => tensor])
                .ort_ctx("识别模型推理")?;
            let out = outputs
                .iter()
                .next()
                .map(|(_, v)| v)
                .ok_or_else(|| crate::error::DpgError::rt("识别模型没有输出"))?;
            let (shape, logits) = out.try_extract_tensor::<f32>().ort_ctx("读取识别输出")?;
            let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
            if dims.len() != 3 {
                return Err(crate::error::DpgError::rt(format!(
                    "识别输出维度异常 (期望 [B,T,C]): {:?}",
                    dims
                )));
            }
            let (_, t, c) = (dims[0], dims[1], dims[2]);
            for bi in 0..b {
                let slice = &logits[bi * t * c..(bi + 1) * t * c];
                results[order[start + bi]] =
                    ctc_decode(&self.dict, self.has_trailing_space, slice, t, c);
            }
            start = end;
        }
        Ok(results)
    }

    /// 类别索引 -> 字符 (blank 返回 None)
    ///
    /// 字典有两种排布, 由 `has_trailing_space` 区分:
    ///   * 内嵌/外部字典已含末尾空格: id in 1..=len -> dict[id-1]
    ///   * 需要额外补一个空格类别:   id == len+1     -> " "
    #[inline]
    fn char_at_impl<'a>(
        dict: &'a Dict,
        has_trailing_space: bool,
        id: usize,
    ) -> Option<&'a str> {
        if id == 0 {
            return None; // blank
        }
        if id <= dict.len() {
            return dict.get(id - 1);
        }
        if has_trailing_space && id == dict.len() + 1 {
            return Some(" ");
        }
        None
    }

    /// CTC 贪心解码
    ///
    /// 输出张量已带 softmax, 因此直接把 `argmax` 的概率当作置信度;
    /// 折叠规则 = "与前一个原始类别不同, 且不是 blank(0)"。
    fn ctc_decode_impl(
        dict: &Dict,
        has_trailing_space: bool,
        logits: &[f32],
        t: usize,
        c: usize,
    ) -> RecOutput {
        let mut text = String::new();
        let mut prev = usize::MAX;
        let mut conf_sum = 0.0f64;
        let mut conf_cnt = 0usize;
        for ti in 0..t {
            let row = &logits[ti * c..(ti + 1) * c];
            let mut best = 0usize;
            let mut best_v = f32::NEG_INFINITY;
            for (ci, &v) in row.iter().enumerate() {
                if v > best_v {
                    best_v = v;
                    best = ci;
                }
            }
            if best != 0 && best != prev {
                if let Some(ch) = TextRecognizer::char_at_impl(dict, has_trailing_space, best)
                {
                    text.push_str(ch);
                    conf_sum += best_v as f64;
                    conf_cnt += 1;
                }
            }
            prev = best;
        }
        let score = if conf_cnt > 0 {
            (conf_sum / conf_cnt as f64) as f32
        } else {
            0.0
        };
        RecOutput { text, score }
    }
}

/// 自由函数包装: 只借用 `dict`, 与 `session` 的可变借用不相交
#[inline]
fn ctc_decode(
    dict: &Dict,
    has_trailing_space: bool,
    logits: &[f32],
    t: usize,
    c: usize,
) -> RecOutput {
    TextRecognizer::ctc_decode_impl(dict, has_trailing_space, logits, t, c)
}
