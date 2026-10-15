//! 文本行方向分类 (0 / 180 度)
//!
//! PP-OCRv5 使用 `PP-LCNet_x0_25_textline_ori`, 输入 3x80x160, 2 分类。
//!
//! 注意: 模型自带的 `inference.yml` 写的是 `ResizeImage(160,80)` + ImageNet 均值,
//! 而 RapidOCR 实现用的是 `(x/127.5 - 1)` + 等比缩放右侧补零。两者不一致,
//! 因此这里把两种变体都做成可配置, 由实测结果决定默认值。

use crate::error::{OrtExt, Result};
use crate::image_utils::resize_bilinear;
use crate::ort_util::{build_session, first_input_name};
use image::RgbImage;
use ort::environment::Environment;
use ort::session::Session;
use ort::value::Tensor;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClsNorm {
    /// (x/255 - ImageNet_mean) / ImageNet_std
    Imagenet,
    /// (x/255 - 0.5) / 0.5
    Half,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClsConfig {
    pub img_h: u32,
    pub img_w: u32,
    pub norm: ClsNorm,
    /// true: 等比缩放到高 80 再右侧补零; false: 直接拉伸到 160x80
    pub keep_ratio: bool,
    /// 判定为 180 度所需的最低置信度
    pub thresh: f32,
}

impl ClsConfig {
    /// 官方 inference.yml 变体
    pub fn official_v5() -> Self {
        Self {
            img_h: 80,
            img_w: 160,
            norm: ClsNorm::Imagenet,
            keep_ratio: false,
            thresh: 0.9,
        }
    }
    /// RapidOCR 实现变体
    pub fn rapidocr_v5() -> Self {
        Self {
            img_h: 80,
            img_w: 160,
            norm: ClsNorm::Half,
            keep_ratio: true,
            thresh: 0.9,
        }
    }
}

impl Default for ClsConfig {
    fn default() -> Self {
        Self::rapidocr_v5()
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ClsOutput {
    /// 0 或 180
    pub angle: u32,
    pub score: f32,
}

pub struct TextAngleClassifier {
    session: Session,
    input_name: String,
    pub cfg: ClsConfig,
}

impl TextAngleClassifier {
    pub fn new(env: &Environment, model: &Path, threads: i32, cfg: ClsConfig) -> Result<Self> {
        let session = build_session(env, model, threads)?;
        let input_name = first_input_name(&session)?;
        Ok(Self {
            session,
            input_name,
            cfg,
        })
    }

    fn make_input(&self, img: &RgbImage) -> (Vec<f32>, u32, u32) {
        let (ih, iw) = (self.cfg.img_h, self.cfg.img_w);
        let (h, w) = (img.height().max(1), img.width().max(1));
        let (rw, rh, off_x) = if self.cfg.keep_ratio {
            // 等比缩放到高度 ih, 宽度不足则右侧补零
            let ratio = w as f32 / h as f32;
            let want = (ih as f32 * ratio).ceil() as u32;
            let rw = want.min(iw).max(1);
            let off = if want > iw {
                // 宽度超出时: 先缩放到 height*ratio=want 再水平方向压缩到 iw 会失真,
                // 与 RapidOCR 一致: 直接以 rw=iw 缩放 (宽度被压缩)
                0
            } else {
                0
            };
            (rw, ih, off)
        } else {
            (iw, ih, 0)
        };
        let resized = resize_bilinear(img, rw, rh);
        let plane = (iw * ih) as usize;
        let mut data = vec![0f32; 3 * plane];
        let raw = resized.as_raw();
        let (m, s) = match self.cfg.norm {
            ClsNorm::Imagenet => ([0.485f32, 0.456, 0.406], [0.229f32, 0.224, 0.225]),
            ClsNorm::Half => ([0.5f32, 0.5, 0.5], [0.5f32, 0.5, 0.5]),
        };
        for y in 0..rh as usize {
            for x in 0..rw as usize {
                let si = (y * rw as usize + x) * 3;
                let di = y * iw as usize + (x + off_x as usize);
                let r = raw[si] as f32 / 255.0;
                let g = raw[si + 1] as f32 / 255.0;
                let b = raw[si + 2] as f32 / 255.0;
                data[di] = (b - m[0]) / s[0];
                data[plane + di] = (g - m[1]) / s[1];
                data[2 * plane + di] = (r - m[2]) / s[2];
            }
        }
        (data, iw, ih)
    }

    /// 单张判断 (批处理版本见 `classify_batch`)
    pub fn classify(&mut self, img: &RgbImage) -> Result<ClsOutput> {
        let mut v = self.classify_batch(std::slice::from_ref(img))?;
        Ok(v.pop().unwrap_or(ClsOutput { angle: 0, score: 0.0 }))
    }

    pub fn classify_batch(&mut self, imgs: &[RgbImage]) -> Result<Vec<ClsOutput>> {
        if imgs.is_empty() {
            return Ok(vec![]);
        }
        let (iw, ih) = (self.cfg.img_w, self.cfg.img_h);
        let b = imgs.len();
        let plane = (iw * ih) as usize;
        let mut batch = vec![0f32; b * 3 * plane];
        for (bi, img) in imgs.iter().enumerate() {
            let (data, _, _) = self.make_input(img);
            batch[bi * 3 * plane..(bi + 1) * 3 * plane].copy_from_slice(&data);
        }
        let tensor = Tensor::from_array((
            [b, 3, ih as usize, iw as usize],
            batch,
        ))
        .ort_ctx("构造方向分类输入张量")?;
        let name = self.input_name.clone();
        let outputs = self
            .session
            .run(ort::inputs![name => tensor])
            .ort_ctx("方向分类推理")?;
        let out = outputs
            .iter()
            .next()
            .map(|(_, v)| v)
            .ok_or_else(|| crate::error::DpgError::rt("方向分类模型没有输出"))?;
        let (shape, prob) = out.try_extract_tensor::<f32>().ort_ctx("读取方向分类输出")?;
        let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
        let classes = *dims.last().unwrap_or(&2);
        let mut res = Vec::with_capacity(b);
        for bi in 0..b {
            let row = &prob[bi * classes..(bi + 1) * classes];
            let mut best = 0usize;
            let mut best_v = f32::NEG_INFINITY;
            for (ci, &v) in row.iter().enumerate() {
                if v > best_v {
                    best_v = v;
                    best = ci;
                }
            }
            let angle = if best == 1 { 180 } else { 0 };
            res.push(ClsOutput {
                angle,
                score: best_v,
            });
        }
        Ok(res)
    }
}
