//! DB (Differentiable Binarization) 文本检测
//!
//! 预处理支持两种模式, 用于实测对齐最优精度:
//!   * `ResizeLong` — PaddleOCR 官方 `DetResizeForTest(resize_long=960)` 行为
//!     (比例 = limit/max(h,w), 尺寸向上对齐到 128 的倍数)
//!   * `LimitSide`  — RapidOCR `DetPreProcess(limit_type=min|max, limit_side_len)`
//!     行为 (四舍五入到 32 的倍数)
//!
//! 后处理与 PaddleOCR `DBPostProcess` / RapidOCR 保持一致:
//!   thresh -> 连通域 -> minAreaRect -> box_score_fast -> unclip -> 缩放回原图

use crate::contours::find_components;
use crate::error::{OrtExt, Result};
use crate::geometry::{
    expand_rect, min_area_rect, point_in_quad, polygon_area, polygon_perimeter, quad_bbox_i32, Pt,
};
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
pub enum DetResizeMode {
    /// PaddleOCR 官方 `resize_long` (PP-OCRv5 det mobile 的 inference.yml)
    ResizeLong,
    /// RapidOCR `limit_side_len` + `limit_type`
    LimitSide,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LimitType {
    Min,
    Max,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetConfig {
    pub resize_mode: DetResizeMode,
    /// `ResizeLong` 模式下的长边目标 (960) / `LimitSide` 模式下的限制边长 (736)
    pub limit_side: u32,
    pub limit_type: LimitType,
    /// 输入归一化均值 (BGR 通道顺序)
    pub mean: [f32; 3],
    pub std: [f32; 3],
    /// 二值化阈值
    pub thresh: f32,
    /// 框得分阈值
    pub box_thresh: f32,
    pub unclip_ratio: f32,
    pub max_candidates: usize,
    /// minAreaRect 短边下限
    pub min_size: f32,
    /// 是否对二值图做 2x2 膨胀 (RapidOCR use_dilation)
    pub use_dilation: bool,
    /// 连通域最小像素数 (噪声过滤)
    pub min_component_pixels: usize,
}

impl DetConfig {
    /// 官方 PaddleOCR PP-OCRv5 det mobile 参数 (来自模型自带 inference.yml)
    pub fn official_v5() -> Self {
        Self {
            resize_mode: DetResizeMode::ResizeLong,
            limit_side: 960,
            limit_type: LimitType::Min,
            mean: [0.485, 0.456, 0.406],
            std: [0.229, 0.224, 0.225],
            thresh: 0.3,
            box_thresh: 0.6,
            unclip_ratio: 1.5,
            max_candidates: 1000,
            min_size: 3.0,
            use_dilation: false,
            min_component_pixels: 6,
        }
    }

    /// RapidOCR 默认参数 (通用, 用 [0.5,0.5,0.5] 归一化)
    pub fn rapidocr_default() -> Self {
        Self {
            resize_mode: DetResizeMode::LimitSide,
            limit_side: 736,
            limit_type: LimitType::Min,
            mean: [0.5, 0.5, 0.5],
            std: [0.5, 0.5, 0.5],
            thresh: 0.3,
            box_thresh: 0.5,
            unclip_ratio: 1.6,
            max_candidates: 1000,
            min_size: 3.0,
            use_dilation: true,
            min_component_pixels: 6,
        }
    }
}

impl Default for DetConfig {
    fn default() -> Self {
        Self::official_v5()
    }
}

#[derive(Debug, Clone)]
pub struct DetBox {
    /// 顺序: 左上, 右上, 右下, 左下 (原图坐标)
    pub points: [Pt; 4],
    pub score: f32,
}

pub struct DetOutput {
    pub boxes: Vec<DetBox>,
    /// 网络输入尺寸
    pub input_w: u32,
    pub input_h: u32,
    /// 概率图尺寸
    pub mask_w: u32,
    pub mask_h: u32,
    pub elapsed_ms: f64,
}

pub struct DbDetector {
    session: Session,
    input_name: String,
    pub cfg: DetConfig,
}

impl DbDetector {
    pub fn new(env: &Environment, model: &Path, threads: i32, cfg: DetConfig) -> Result<Self> {
        let session = build_session(env, model, threads)?;
        let input_name = first_input_name(&session)?;
        Ok(Self {
            session,
            input_name,
            cfg,
        })
    }

    /// 按配置缩放图像 (返回缩放后图像)
    fn resize_for_det(&self, img: &RgbImage) -> RgbImage {
        let (w, h) = (img.width(), img.height());
        let mut rw: i64;
        let mut rh: i64;

        match self.cfg.resize_mode {
            DetResizeMode::ResizeLong => {
                // PaddleOCR resize_image_type2: ratio = resize_long / max(h, w)
                let max_side = h.max(w).max(1) as f32;
                let ratio = self.cfg.limit_side as f32 / max_side;
                rw = (w as f32 * ratio) as i64;
                rh = (h as f32 * ratio) as i64;
                // 向上对齐到 128 的倍数
                const STRIDE: i64 = 128;
                rh = ((rh + STRIDE - 1) / STRIDE) * STRIDE;
                rw = ((rw + STRIDE - 1) / STRIDE) * STRIDE;
            }
            DetResizeMode::LimitSide => {
                let ratio = match self.cfg.limit_type {
                    LimitType::Max => {
                        if (h.max(w) as u32) > self.cfg.limit_side {
                            self.cfg.limit_side as f32 / h.max(w) as f32
                        } else {
                            1.0
                        }
                    }
                    LimitType::Min => {
                        if (h.min(w) as u32) < self.cfg.limit_side {
                            self.cfg.limit_side as f32 / h.min(w) as f32
                        } else {
                            1.0
                        }
                    }
                };
                rw = (w as f32 * ratio) as i64;
                rh = (h as f32 * ratio) as i64;
                // 四舍五入到 32 的倍数
                rw = ((rw as f64 / 32.0).round() as i64 * 32).max(32);
                rh = ((rh as f64 / 32.0).round() as i64 * 32).max(32);
            }
        }

        // 过小的图先补到 32x32 (PaddleOCR image_padding: sum(h,w) < 64)
        let mut src = img.clone();
        if (w + h) < 64 {
            let nw = w.max(32);
            let nh = h.max(32);
            src = crate::image_utils::pad_replicate(&src, 0, nh - h, 0, nw - w);
        }

        rw = rw.max(1);
        rh = rh.max(1);
        resize_bilinear(&src, rw as u32, rh as u32)
    }

    /// BGR + mean/std 归一化 -> NCHW
    fn to_tensor(&self, img: &RgbImage) -> Vec<f32> {
        let (w, h) = (img.width() as usize, img.height() as usize);
        let plane = w * h;
        let mut data = vec![0f32; 3 * plane];
        let raw = img.as_raw();
        let (m, s) = (self.cfg.mean, self.cfg.std);
        for i in 0..plane {
            let r = raw[i * 3] as f32 / 255.0;
            let g = raw[i * 3 + 1] as f32 / 255.0;
            let b = raw[i * 3 + 2] as f32 / 255.0;
            // RGB 数组 -> BGR 通道排布 (0=B, 1=G, 2=R)
            data[i] = (b - m[0]) / s[0];
            data[plane + i] = (g - m[1]) / s[1];
            data[2 * plane + i] = (r - m[2]) / s[2];
        }
        data
    }

    pub fn detect(&mut self, img: &RgbImage) -> Result<DetOutput> {
        let t0 = std::time::Instant::now();
        let (ow, oh) = (img.width(), img.height());
        if ow == 0 || oh == 0 {
            return Ok(DetOutput {
                boxes: vec![],
                input_w: 0,
                input_h: 0,
                mask_w: 0,
                mask_h: 0,
                elapsed_ms: 0.0,
            });
        }

        let resized = self.resize_for_det(img);
        let (iw, ih) = (resized.width(), resized.height());
        let data = self.to_tensor(&resized);
        let tensor = Tensor::from_array(([1usize, 3, ih as usize, iw as usize], data))
            .ort_ctx("构造检测输入张量")?;
        let name = self.input_name.clone();
        // 先把配置拷出来, 避免推理期间再借 `self` (session 已被可变借用)
        let cfg = self.cfg.clone();
        let outputs = self
            .session
            .run(ort::inputs![name => tensor])
            .ort_ctx("检测模型推理")?;

        // PP-OCR 检测模型只有一个输出 (fetch_name_0), 直接取第一个
        let out = outputs
            .iter()
            .next()
            .map(|(_, v)| v)
            .ok_or_else(|| crate::error::DpgError::rt("检测模型没有输出"))?;

        let (shape, prob) = out.try_extract_tensor::<f32>().ort_ctx("读取检测输出")?;
        let dims: Vec<usize> = shape.iter().map(|d| *d as usize).collect();
        if dims.len() < 2 {
            return Err(crate::error::DpgError::rt(format!(
                "检测输出维度异常: {:?}",
                dims
            )));
        }
        let mh = dims[dims.len() - 2];
        let mw = dims[dims.len() - 1];
        // 多通道时只取第 0 个通道 (DB 训练头可能输出 prob+thresh 两通道)
        let mask = &prob[0..mh * mw];

        let boxes = Self::postprocess(&cfg, mask, mw, mh, ow as usize, oh as usize);
        Ok(DetOutput {
            boxes,
            input_w: iw,
            input_h: ih,
            mask_w: mw as u32,
            mask_h: mh as u32,
            elapsed_ms: t0.elapsed().as_secs_f64() * 1000.0,
        })
    }

    fn postprocess(
        cfg: &DetConfig,
        prob: &[f32],
        mw: usize,
        mh: usize,
        ow: usize,
        oh: usize,
    ) -> Vec<DetBox> {
        // 1. 二值化
        let mut binary: Vec<u8> = prob
            .iter()
            .map(|&v| if v > cfg.thresh { 1 } else { 0 })
            .collect();

        // 2. 可选 2x2 膨胀 (cv2.dilate, 默认 border = -inf)
        if cfg.use_dilation {
            binary = dilate_2x2(&binary, mw, mh);
        }

        // 3. 连通域
        let comps = find_components(
            &binary,
            mw,
            mh,
            cfg.min_component_pixels,
            cfg.max_candidates,
        );

        let sx = ow as f32 / mw as f32;
        let sy = oh as f32 / mh as f32;
        let mut out = Vec::with_capacity(comps.len());

        for pts in comps {
            let (rect, w, h) = match min_area_rect(&pts) {
                Some(v) => v,
                None => continue,
            };
            // get_mini_boxes 的 sside = min(rect_w, rect_h)
            if w.min(h) < cfg.min_size {
                continue;
            }
            // 4. 得分过滤
            let score = box_score_fast(prob, mw, mh, &rect);
            if score < cfg.box_thresh {
                continue;
            }
            // 5. unclip: distance = area * ratio / perimeter
            let area = polygon_area(&rect);
            let perim = polygon_perimeter(&rect);
            if perim <= 1e-6 {
                continue;
            }
            let d = area * cfg.unclip_ratio / perim;
            let expanded = expand_rect(&rect, d);
            let (ew, eh) = crate::geometry::rect_size(&expanded);
            if ew.min(eh) < cfg.min_size + 2.0 {
                continue;
            }

            // 6. 映射回原图 + 排序
            let mut p = order_points_clockwise_rapid(&expanded);
            for q in p.iter_mut() {
                q.x = (q.x * sx).round().clamp(0.0, ow as f32 - 1.0);
                q.y = (q.y * sy).round().clamp(0.0, oh as f32 - 1.0);
            }
            // filter_det_res: 宽高任一 <= 3 则丢弃
            let bw = (p[0].dist(&p[1])) as i32;
            let bh = (p[0].dist(&p[3])) as i32;
            if bw <= 3 || bh <= 3 {
                continue;
            }
            out.push(DetBox { points: p, score });
        }
        out
    }
}

/// 2x2 全 1 核膨胀 (对应 cv2.dilate(bitmap, np.array([[1,1],[1,1]])))
fn dilate_2x2(src: &[u8], w: usize, h: usize) -> Vec<u8> {
    let mut dst = vec![0u8; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut v = 0u8;
            // 核锚点为 (1,1): 采样 (x-1..=x, y-1..=y)
            for dy in [-1i32, 0] {
                let ny = y as i32 + dy;
                if ny < 0 || ny >= h as i32 {
                    continue;
                }
                for dx in [-1i32, 0] {
                    let nx = x as i32 + dx;
                    if nx < 0 || nx >= w as i32 {
                        continue;
                    }
                    let s = src[ny as usize * w + nx as usize];
                    if s > v {
                        v = s;
                    }
                }
            }
            dst[y * w + x] = v;
        }
    }
    dst
}

/// RapidOCR `get_mini_boxes` 的角点排序: 先按 x 排序, 再按 y 定上下
pub fn order_points_clockwise_rapid(pts: &[Pt; 4]) -> [Pt; 4] {
    let mut p = *pts;
    p.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
    let (i1, i4) = if p[1].y > p[0].y { (0usize, 1usize) } else { (1, 0) };
    let (i2, i3) = if p[3].y > p[2].y { (2usize, 3usize) } else { (3, 2) };
    [p[i1], p[i2], p[i3], p[i4]]
}

/// box_score_fast: 在外接矩形范围内对落在框内的像素取均值
pub fn box_score_fast(prob: &[f32], w: usize, h: usize, rect: &[Pt; 4]) -> f32 {
    let (x0, y0, x1, y1) = quad_bbox_i32(rect, w as i32, h as i32);
    let mut sum = 0.0f64;
    let mut cnt = 0usize;
    for y in y0..=y1 {
        for x in x0..=x1 {
            let p = Pt::new(x as f32, y as f32);
            if point_in_quad(&p, rect) {
                sum += prob[y as usize * w + x as usize] as f64;
                cnt += 1;
            }
        }
    }
    if cnt == 0 {
        0.0
    } else {
        (sum / cnt as f64) as f32
    }
}

/// 把检测框按阅读顺序排序: 先按 y 分行, 行内按 x (等价 RapidOCR sorted_boxes)
pub fn sort_boxes_reading_order(boxes: &mut [DetBox]) {
    const Y_THRESHOLD: f32 = 10.0;
    boxes.sort_by(|a, b| {
        a.points[0]
            .y
            .partial_cmp(&b.points[0].y)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    // 行分组: 相邻 y 间距小于阈值视为同一行
    let n = boxes.len();
    let mut i = 0usize;
    while i < n {
        let mut j = i + 1;
        while j < n && (boxes[j].points[0].y - boxes[j - 1].points[0].y).abs() < Y_THRESHOLD {
            j += 1;
        }
        boxes[i..j].sort_by(|a, b| {
            a.points[0]
                .x
                .partial_cmp(&b.points[0].x)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        i = j;
    }
}
