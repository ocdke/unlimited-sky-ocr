//! OCR 引擎: 串联 检测 -> 裁切 -> 方向分类 -> 识别 -> 多语种重试

use crate::cls::{ClsConfig, TextAngleClassifier};
use crate::det::{sort_boxes_reading_order, DbDetector, DetBox, DetConfig};
use crate::error::{DpgError, Result};
use crate::geometry::Pt;
use crate::image_utils::{crop_quad, rotate180, rotate90_ccw};
use crate::ort_util::global_env;
use crate::rec::{RecConfig, TextRecognizer};
use image::RgbImage;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 单个识别模型 (语言 -> 模型 + 字典)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecModelSpec {
    /// 语言标识: ch / en / latin / cyrillic / korean / arabic / devanagari / el / eslav / th / ta / te
    pub lang: String,
    pub model: PathBuf,
    pub dict: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineConfig {
    /// onnxruntime 动态库路径 (load-dynamic 模式必需)
    #[serde(default)]
    pub onnxruntime_dll: Option<PathBuf>,
    pub det_model: PathBuf,
    #[serde(default)]
    pub cls_model: Option<PathBuf>,
    pub rec_models: Vec<RecModelSpec>,
    /// ONNX Runtime intra-op 线程数; <=0 表示自动
    #[serde(default = "default_threads")]
    pub intra_threads: i32,
    #[serde(default)]
    pub det: DetConfig,
    #[serde(default)]
    pub cls: ClsConfig,
    #[serde(default)]
    pub rec: RecConfig,
    /// 默认识别语言
    #[serde(default = "default_lang")]
    pub default_lang: String,
    /// auto 模式下参与重试的候选语言
    #[serde(default = "default_auto_candidates")]
    pub auto_candidates: Vec<String>,
}

fn default_threads() -> i32 {
    0
}
fn default_lang() -> String {
    "ch".to_string()
}
fn default_auto_candidates() -> Vec<String> {
    vec!["latin".into(), "korean".into(), "cyrillic".into()]
}

/// 换模型重认的接受门槛。
///
/// 实测踩过坑: 一句俄语被 ch 模型认错后, 重试用韩语模型给出了 0.515 的乱码,
/// 而它的分数恰好比原结果高, 于是"成功"替换成了韩语乱码。
/// 0.75 这个门槛要求重认结果自己也站得住脚。
fn default_retry_accept() -> f32 {
    0.75
}

fn default_noise_level() -> i32 {
    1
}

impl EngineConfig {
    /// 从 JSON 字符串解析
    pub fn from_json(s: &str) -> Result<Self> {
        Ok(serde_json::from_str(s)?)
    }

    /// 模型根目录下的标准布局 (与 tools/download_models.ps1 一致)
    pub fn standard(model_root: &Path, dll: Option<PathBuf>, langs: &[&str]) -> Self {
        let ocr = model_root.join("ocr").join("PP-OCRv5");
        let mut rec_models = Vec::new();
        for l in langs {
            rec_models.push(RecModelSpec {
                lang: (*l).to_string(),
                model: ocr.join("rec").join(format!("{l}_PP-OCRv5_rec_mobile.onnx")),
                dict: ocr.join("rec").join("dicts").join(format!("{l}.txt")),
            });
        }
        Self {
            onnxruntime_dll: dll,
            det_model: ocr.join("det").join("ch_PP-OCRv5_det_mobile.onnx"),
            cls_model: Some(
                ocr.join("cls")
                    .join("ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx"),
            ),
            rec_models,
            intra_threads: 0,
            det: DetConfig::default(),
            cls: ClsConfig::default(),
            rec: RecConfig::default(),
            default_lang: "ch".into(),
            auto_candidates: default_auto_candidates(),
        }
    }
}

/// 单次调用的选项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrOptions {
    /// 目标语言; "auto" 表示自动 (先跑 default_lang, 低置信行再用候选模型重试)
    #[serde(default = "opt_lang")]
    pub lang: String,
    #[serde(default = "opt_true")]
    pub use_det: bool,
    #[serde(default = "opt_true")]
    pub use_cls: bool,
    /// 文本置信度下限, 低于该值的行被丢弃
    #[serde(default = "opt_score")]
    pub text_score: f32,
    /// 覆盖检测长边 (越小越快)
    #[serde(default)]
    pub det_limit_side: Option<u32>,
    /// 是否开启多语种自动重试
    #[serde(default = "opt_true")]
    pub auto_multilang: bool,
    /// 低于该置信度才触发重试
    #[serde(default = "opt_retry_score")]
    pub auto_retry_score: f32,
    /// 换模型重认的结果至少要达到这个置信度才允许替换原结果
    #[serde(default = "default_retry_accept")]
    pub auto_retry_accept: f32,
    /// 噪声过滤档位: 0=关闭 1=宽松(默认) 2=标准 3=严格
    ///
    /// 默认用宽松档 —— 之前"少于两个字符就丢"对中日文太狠,
    /// 单字菜单项、数字全被误杀, 用户会感觉"很多内容根本不识别"。
    #[serde(default = "default_noise_level")]
    pub noise_level: i32,
    /// 单次最多重试多少行
    #[serde(default = "opt_max_retry")]
    pub max_retry_lines: usize,
    /// 过滤掉高度小于该值(原图像素)的文本框; None/0 表示不过滤。
    /// 屏幕上过小的文字人眼也读不清, 过滤掉可显著减少识别耗时。
    #[serde(default)]
    pub min_line_height: Option<f32>,
    /// 最多识别多少行 (0 或 None 表示不限); 用于约束极端场景下的最坏延迟
    #[serde(default)]
    pub max_lines: Option<usize>,
}

fn opt_lang() -> String {
    "auto".into()
}
fn opt_true() -> bool {
    true
}
fn opt_score() -> f32 {
    0.5
}
fn opt_retry_score() -> f32 {
    0.86
}
fn opt_max_retry() -> usize {
    64
}

impl Default for OcrOptions {
    fn default() -> Self {
        Self {
            lang: opt_lang(),
            use_det: true,
            use_cls: true,
            text_score: opt_score(),
            det_limit_side: None,
            auto_multilang: true,
            auto_retry_score: opt_retry_score(),
        auto_retry_accept: default_retry_accept(),
        noise_level: default_noise_level(),
            max_retry_lines: opt_max_retry(),
            min_line_height: None,
            max_lines: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrLine {
    pub text: String,
    /// 识别置信度
    pub score: f32,
    /// 检测置信度
    pub det_score: f32,
    /// 4 个角点 (原图像素坐标), 顺序 左上/右上/右下/左下
    pub points: [[f32; 2]; 4],
    /// 实际使用的识别模型语言
    pub lang: String,
    /// 裁切时是否做了 90 度旋转 (竖排文本)
    pub rotated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrResult {
    pub lines: Vec<OcrLine>,
    pub image_width: u32,
    pub image_height: u32,
    pub det_ms: f64,
    pub cls_ms: f64,
    pub rec_ms: f64,
    pub total_ms: f64,
}

/// 识别模型的"待加载"描述。
///
/// 启动时只记录路径, 真正用到某个语种才创建 ORT 会话 —— 12 个模型全量加载
/// 要 1 秒以上, 而且是多核满载, 开机首次启动会明显卡顿。
#[derive(Clone)]
struct RecSpec {
    model: PathBuf,
    dict: PathBuf,
    intra_threads: i32,
    cfg: RecConfig,
}

pub struct OcrEngine {
    det: Option<DbDetector>,
    cls: Option<TextAngleClassifier>,
    /// 已加载的识别模型
    recs: HashMap<String, TextRecognizer>,
    /// 全部可用的识别模型 (按需加载)
    rec_specs: HashMap<String, RecSpec>,
    /// 裁剪图内容 -> 识别结果。
    ///
    /// 识别(rec)占了整屏扫描 90% 以上的时间, 而且是按**像素面积**算的 ——
    /// 只要屏幕上那块文字没变, 再识别一遍纯属浪费。这里按裁剪内容的哈希
    /// 缓存结果, 画面基本没动时整屏扫描能从 1 秒降到几十毫秒。
    rec_cache: HashMap<u64, (String, f32)>,
    rec_order: Vec<String>,
    default_lang: String,
    auto_candidates: Vec<String>,
    cfg: EngineConfig,
}

impl OcrEngine {
    pub fn new(cfg: EngineConfig) -> Result<Self> {
        // 复用进程级唯一环境 (ONNX Runtime 限制每进程只能有一个)
        let env = global_env(cfg.onnxruntime_dll.as_deref())?;

        let det = if cfg.det_model.exists() {
            Some(DbDetector::new(
                &env,
                &cfg.det_model,
                cfg.intra_threads,
                cfg.det.clone(),
            )?)
        } else {
            None
        };

        let cls = match cfg.cls_model.as_ref() {
            Some(p) if p.exists() => Some(TextAngleClassifier::new(
                &env,
                p,
                cfg.intra_threads,
                cfg.cls.clone(),
            )?),
            _ => None,
        };

        // 先只登记, 不加载 —— 12 个识别模型合计 104 MB, 全量加载 1 秒以上
        let mut rec_specs = HashMap::new();
        let mut rec_order = Vec::new();
        for spec in &cfg.rec_models {
            if !spec.model.exists() {
                continue;
            }
            rec_specs.insert(
                spec.lang.clone(),
                RecSpec {
                    model: spec.model.clone(),
                    dict: spec.dict.clone(),
                    intra_threads: cfg.intra_threads,
                    cfg: cfg.rec.clone(),
                },
            );
            rec_order.push(spec.lang.clone());
        }
        if rec_specs.is_empty() {
            return Err(DpgError::cfg("没有可用的识别模型"));
        }

        let default_lang = if rec_specs.contains_key(&cfg.default_lang) {
            cfg.default_lang.clone()
        } else {
            rec_order[0].clone()
        };
        let auto_candidates: Vec<String> = cfg
            .auto_candidates
            .iter()
            .filter(|l| rec_specs.contains_key(*l) && **l != default_lang)
            .cloned()
            .collect();

        let mut me = Self {
            det,
            cls,
            recs: HashMap::new(),
            rec_specs,
            rec_cache: HashMap::new(),
            rec_order,
            default_lang: default_lang.clone(),
            auto_candidates,
            cfg,
        };
        // 默认语种先热起来, 保证第一次截图不用等
        me.ensure_rec(&default_lang)?;

        Ok(me)
    }

    /// 裁剪图的内容哈希 (FNV-1a 64 位)
    ///
    /// 逐字节算太慢, 隔几个字节采一次样 —— 文字有一点不同就一定会变,
    /// 而纯色/抗锯齿的微小差异本来也不该影响识别结果。
    fn crop_hash(img: &RgbImage) -> u64 {
        const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
        const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
        let mut h = FNV_OFFSET;
        let raw = img.as_raw();
        let (w, hh) = (img.width() as usize, img.height() as usize);
        h ^= (w as u64).wrapping_mul(31).wrapping_add(hh as u64);
        h = h.wrapping_mul(FNV_PRIME);
        // 横向步长随宽度自适应, 保证大图小图采样量接近
        let step = ((raw.len() / 4096).max(1)) as usize;
        let mut i = 0usize;
        while i < raw.len() {
            h ^= raw[i] as u64;
            h = h.wrapping_mul(FNV_PRIME);
            i += step;
        }
        h
    }

    /// 从缓存取识别结果; 命中就完全跳过模型推理
    fn rec_cached(&mut self, img: &RgbImage, lang: &str) -> Option<(String, f32)> {
        let k = Self::crop_hash(img);
        // 缓存里存的是 (语言, 文本, 置信度) 三元组, 用语言做前缀避免串味
        let key = k ^ Self::lang_salt(lang);
        self.rec_cache.get(&key).cloned()
    }

    fn rec_store(&mut self, img: &RgbImage, lang: &str, text: String, score: f32) {
        // 太短的文本不值得缓存 (命中率低还占地方), 空文本更不该缓存
        if text.trim().is_empty() {
            return;
        }
        if self.rec_cache.len() > 8000 {
            self.rec_cache.clear();
        }
        let key = Self::crop_hash(img) ^ Self::lang_salt(lang);
        self.rec_cache.insert(key, (text, score));
    }

    fn lang_salt(lang: &str) -> u64 {
        let mut h: u64 = 1469_5937_7902_2621;
        for b in lang.bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        h.rotate_left(17)
    }

    /// 按需加载某个语种的识别模型
    fn ensure_rec(&mut self, lang: &str) -> Result<()> {
        if self.recs.contains_key(lang) {
            return Ok(());
        }
        let spec = self
            .rec_specs
            .get(lang)
            .cloned()
            .ok_or_else(|| DpgError::cfg(format!("没有加载识别模型: {lang}")))?;
        let env = global_env(None)?;
        let r = TextRecognizer::new(
            env,
            &spec.model,
            &spec.dict,
            spec.intra_threads,
            spec.cfg,
        )?;
        self.recs.insert(lang.to_string(), r);
        Ok(())
    }

    /// 预加载若干语种 (启动后可以在后台慢慢补, 不阻塞首屏)
    pub fn preload(&mut self, langs: &[String]) -> usize {
        let mut n = 0;
        for l in langs {
            if self.ensure_rec(l).is_ok() {
                n += 1;
            }
        }
        n
    }

    /// 已加载的语种
    pub fn loaded_langs(&self) -> Vec<String> {
        let mut v: Vec<String> = self.recs.keys().cloned().collect();
        v.sort();
        v
    }

    pub fn config(&self) -> &EngineConfig {
        &self.cfg
    }

    pub fn available_langs(&self) -> &[String] {
        &self.rec_order
    }

    /// 单个识别模型的类别数 / 字典长度 (诊断用)
    pub fn rec_info(&self) -> Vec<(String, usize, usize, bool)> {
        let mut v: Vec<_> = self
            .recs
            .iter()
            .map(|(k, r)| (k.clone(), r.num_classes(), r.dict_len(), r.has_trailing_space()))
            .collect();
        v.sort();
        v
    }

    pub fn has_det(&self) -> bool {
        self.det.is_some()
    }

    pub fn has_cls(&self) -> bool {
        self.cls.is_some()
    }

    /// 主流程
    pub fn run(&mut self, img: &RgbImage, opts: &OcrOptions) -> Result<OcrResult> {
        let t_all = std::time::Instant::now();
        let (iw, ih) = (img.width(), img.height());

        // 覆盖检测长边
        if let (Some(det), Some(lim)) = (self.det.as_mut(), opts.det_limit_side) {
            det.cfg.limit_side = lim;
        }

        // ---------- 1. 检测 ----------
        let t_det = std::time::Instant::now();
        let mut boxes: Vec<DetBox> = if opts.use_det {
            match self.det.as_mut() {
                Some(d) => d.detect(img)?.boxes,
                None => return Err(DpgError::cfg("未加载检测模型, 无法执行整图检测")),
            }
        } else {
            vec![DetBox {
                points: [
                    Pt::new(0.0, 0.0),
                    Pt::new(iw as f32 - 1.0, 0.0),
                    Pt::new(iw as f32 - 1.0, ih as f32 - 1.0),
                    Pt::new(0.0, ih as f32 - 1.0),
                ],
                score: 1.0,
            }]
        };
        if boxes.is_empty() {
            return Ok(OcrResult {
                lines: vec![],
                image_width: iw,
                image_height: ih,
                det_ms: t_det.elapsed().as_secs_f64() * 1000.0,
                cls_ms: 0.0,
                rec_ms: 0.0,
                total_ms: t_all.elapsed().as_secs_f64() * 1000.0,
            });
        }
        if opts.use_det {
            sort_boxes_reading_order(&mut boxes);
        }
        // 过滤掉高度过小的文本框: 屏幕上过小的字识别耗时不划算且基本无意义
        if let Some(minh) = opts.min_line_height {
            if minh > 0.0 {
                boxes.retain(|b| crate::geometry::rect_size(&b.points).1 >= minh);
            }
        }
        // 行数上限: 约束极端场景下的最坏延迟
        if let Some(maxn) = opts.max_lines {
            if maxn > 0 && boxes.len() > maxn {
                boxes.truncate(maxn);
            }
        }
        let det_ms = t_det.elapsed().as_secs_f64() * 1000.0;

        // ---------- 2. 裁切 ----------
        let mut crops: Vec<RgbImage> = Vec::with_capacity(boxes.len());
        let mut rotated_flags: Vec<bool> = Vec::with_capacity(boxes.len());
        for b in &boxes {
            let (c, rot) = crop_box(img, b);
            crops.push(c);
            rotated_flags.push(rot);
        }

        // ---------- 3. 方向分类 ----------
        let t_cls = std::time::Instant::now();
        let mut cls_ms = 0.0f64;
        if opts.use_cls {
            if let Some(clf) = self.cls.as_mut() {
                let res = clf.classify_batch(&crops)?;
                for (i, r) in res.iter().enumerate() {
                    if r.angle == 180 && r.score >= clf.cfg.thresh {
                        crops[i] = rotate180(&crops[i]);
                    }
                }
            }
        }
        cls_ms += t_cls.elapsed().as_secs_f64() * 1000.0;

        // ---------- 4. 识别 ----------
        let t_rec = std::time::Instant::now();
        let primary = if opts.lang == "auto" || opts.lang.is_empty() {
            self.default_lang.clone()
        } else {
            opts.lang.clone()
        };
        let primary = if self.rec_specs.contains_key(&primary) {
            primary
        } else {
            self.default_lang.clone()
        };
        // 用到才加载 —— 这就是启动从 1 秒降到几百毫秒的关键
        self.ensure_rec(&primary)?;

        let mut texts: Vec<String> = vec![String::new(); crops.len()];
        let mut scores: Vec<f32> = vec![0.0; crops.len()];
        let mut langs: Vec<String> = vec![primary.clone(); crops.len()];

        {
            // 先看缓存: 屏幕上那块文字没动就不用再识别一遍。
            // rec 占整屏扫描 90% 以上的时间, 而且是按像素面积算的 ——
            // 画面基本静止时这一步能把 1 秒变成几十毫秒。
            let mut todo: Vec<usize> = Vec::with_capacity(crops.len());
            for (i, c) in crops.iter().enumerate() {
                match self.rec_cached(c, &primary) {
                    Some((t, sc)) => {
                        texts[i] = t;
                        scores[i] = sc;
                    }
                    None => todo.push(i),
                }
            }
            if !todo.is_empty() {
                let sub: Vec<RgbImage> = todo.iter().map(|&i| crops[i].clone()).collect();
                let r = self
                    .recs
                    .get_mut(&primary)
                    .ok_or_else(|| DpgError::rt("识别模型缺失"))?;
                let out = r.recognize_batch(&sub)?;
                for (k, o) in out.iter().enumerate() {
                    let gi = todo[k];
                    texts[gi] = o.text.clone();
                    scores[gi] = o.score;
                }
                // 推理完再写缓存 (recognize_batch 借了 self.recs, 这里才能动 self)
                for (k, o) in out.iter().enumerate() {
                    let gi = todo[k];
                    self.rec_store(&crops[gi], &primary, o.text.clone(), o.score);
                }
            }
        }

        // ---------- 5. 多语种自动重试 ----------
        let mut retried = 0usize;
        // 只有"自动检测"才做多语种重试。
        // 用户手动选了语种就说明他知道内容是什么, 再用别的模型去重认
        // 只会把正确结果覆盖成错的 (实测: 选韩语会被 latin/cyrillic 抢走)。
        let user_picked = !(opts.lang == "auto" || opts.lang.is_empty());
        if opts.auto_multilang && !user_picked && !self.auto_candidates.is_empty() {
            let mut idx: Vec<usize> = (0..crops.len())
                .filter(|&i| scores[i] < opts.auto_retry_score)
                .collect();
            // 置信度最低的优先
            idx.sort_by(|&a, &b| {
                scores[a]
                    .partial_cmp(&scores[b])
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            idx.truncate(opts.max_retry_lines);
            if !idx.is_empty() {
                let sub: Vec<RgbImage> = idx.iter().map(|&i| crops[i].clone()).collect();
                let cands = self.auto_candidates.clone();
                for lang in cands {
                    // 候选模型也是用到才加载
                    if self.ensure_rec(&lang).is_err() {
                        continue;
                    }
                    let out = match self.recs.get_mut(&lang) {
                        Some(r) => r.recognize_batch(&sub)?,
                        None => continue,
                    };
                    for (k, &gi) in idx.iter().enumerate() {
                        let o = &out[k];
                        if o.text.is_empty() {
                            continue;
                        }
                        let (bw, bh) = crate::geometry::rect_size(&boxes[gi].points);
                        // 换模型重认出来的结果必须**自己也站得住脚**, 否则会把
                        // 一句俄语换成置信度 0.5 的韩语乱码 —— 实测踩过这个坑。
                        if o.score < opts.auto_retry_accept {
                            continue;
                        }
                        if crate::filter::is_noise(
                            &o.text,
                            o.score,
                            bw,
                            bh,
                            opts.text_score,
                            crate::filter::NoiseLevel::from_i32(opts.noise_level),
                        ) {
                            continue;
                        }
                        // 还要明显更优才替换, 避免抖动
                        if o.score > scores[gi] + 0.05 {
                            texts[gi] = o.text.clone();
                            scores[gi] = o.score;
                            langs[gi] = lang.clone();
                            retried += 1;
                        }
                    }
                }
            }
        }
        let _ = retried;
        let rec_ms = t_rec.elapsed().as_secs_f64() * 1000.0;

        // ---------- 6. 汇总 ----------
        let mut lines = Vec::with_capacity(boxes.len());
        for (i, b) in boxes.iter().enumerate() {
            let (bw, bh) = crate::geometry::rect_size(&b.points);
            let lv = crate::filter::NoiseLevel::from_i32(opts.noise_level);
            if crate::filter::is_noise(&texts[i], scores[i], bw, bh, opts.text_score, lv) {
                continue;
            }
            lines.push(OcrLine {
                text: texts[i].clone(),
                score: scores[i],
                det_score: b.score,
                points: [
                    [b.points[0].x, b.points[0].y],
                    [b.points[1].x, b.points[1].y],
                    [b.points[2].x, b.points[2].y],
                    [b.points[3].x, b.points[3].y],
                ],
                lang: langs[i].clone(),
                rotated: rotated_flags[i],
            });
        }

        // 同一处被检测出多个框时只保留一个, 避免叠字
        crate::filter::dedup(&mut lines, |l| {
            let xs: Vec<f32> = l.points.iter().map(|p| p[0]).collect();
            let ys: Vec<f32> = l.points.iter().map(|p| p[1]).collect();
            let x0 = xs.iter().cloned().fold(f32::MAX, f32::min);
            let x1 = xs.iter().cloned().fold(f32::MIN, f32::max);
            let y0 = ys.iter().cloned().fold(f32::MAX, f32::min);
            let y1 = ys.iter().cloned().fold(f32::MIN, f32::max);
            (
                l.text.clone(),
                l.score,
                (x0 + x1) * 0.5,
                (y0 + y1) * 0.5,
                x1 - x0,
                y1 - y0,
            )
        });

        Ok(OcrResult {
            lines,
            image_width: iw,
            image_height: ih,
            det_ms,
            cls_ms,
            rec_ms,
            total_ms: t_all.elapsed().as_secs_f64() * 1000.0,
        })
    }

    /// 仅识别 (不检测): 对给定的框逐一出结果。
    ///
    /// 实时翻译大幅提速的关键 —— 画面只有几行变化时, 没必要把整屏重新检测
    /// 一遍 (检测 + 全量识别是每轮最贵的部分)。这里直接复用上一轮的框,
    /// 只把重叠脏区域的那几行重新识别。
    pub fn recognize_boxes(
        &mut self,
        img: &RgbImage,
        boxes: &[crate::det::DetBox],
        lang: &str,
    ) -> Result<Vec<OcrLine>> {
        if boxes.is_empty() {
            return Ok(Vec::new());
        }

        let mut crops: Vec<RgbImage> = Vec::with_capacity(boxes.len());
        let mut rotated_flags: Vec<bool> = Vec::with_capacity(boxes.len());
        for b in boxes {
            let (c, rot) = crop_box(img, b);
            crops.push(c);
            rotated_flags.push(rot);
        }

        // 方向分类
        if let Some(clf) = self.cls.as_mut() {
            let res = clf.classify_batch(&crops)?;
            for (i, r) in res.iter().enumerate() {
                if r.angle == 180 && r.score >= clf.cfg.thresh {
                    crops[i] = rotate180(&crops[i]);
                }
            }
        }

        // 逐框识别
        let rec_lang = if self.rec_specs.contains_key(lang) {
            lang.to_string()
        } else {
            self.default_lang.clone()
        };
        self.ensure_rec(&rec_lang)?;
        let mut recs: Vec<crate::rec::RecOutput> = vec![
            crate::rec::RecOutput {
                text: String::new(),
                score: 0.0,
            };
            crops.len()
        ];
        {
            let mut todo: Vec<usize> = Vec::with_capacity(crops.len());
            for (i, c) in crops.iter().enumerate() {
                match self.rec_cached(c, &rec_lang) {
                    Some((t, sc)) => {
                        recs[i].text = t;
                        recs[i].score = sc;
                    }
                    None => todo.push(i),
                }
            }
            if !todo.is_empty() {
                let sub: Vec<RgbImage> = todo.iter().map(|&i| crops[i].clone()).collect();
                let out = {
                    let rec = self
                        .recs
                        .get_mut(&rec_lang)
                        .ok_or_else(|| DpgError::cfg(format!("未加载识别模型: {rec_lang}")))?;
                    rec.recognize_batch(&sub)?
                };
                for (k, o) in out.iter().enumerate() {
                    let gi = todo[k];
                    recs[gi].text = o.text.clone();
                    recs[gi].score = o.score;
                }
                for (k, o) in out.iter().enumerate() {
                    let gi = todo[k];
                    self.rec_store(&crops[gi], &rec_lang, o.text.clone(), o.score);
                }
            }
        }

        let mut out = Vec::with_capacity(boxes.len());
        for (i, b) in boxes.iter().enumerate() {
            let (bw, bh) = crate::geometry::rect_size(&b.points);
            let score = recs[i].score;
            if crate::filter::is_noise(
                &recs[i].text,
                score,
                bw,
                bh,
                0.0,
                crate::filter::NoiseLevel::from_i32(
                    crate::filter::NoiseLevel::Loose as i32,
                ),
            ) {
                continue;
            }
            out.push(OcrLine {
                text: recs[i].text.clone(),
                score,
                det_score: b.score,
                points: [
                    [b.points[0].x, b.points[0].y],
                    [b.points[1].x, b.points[1].y],
                    [b.points[2].x, b.points[2].y],
                    [b.points[3].x, b.points[3].y],
                ],
                lang: rec_lang.clone(),
                rotated: rotated_flags[i],
            });
        }
        Ok(out)
    }

    /// 仅识别 (不检测): 把整张图当作一行
    pub fn recognize_whole(&mut self, img: &RgbImage, lang: &str) -> Result<OcrResult> {
        let opts = OcrOptions {
            lang: lang.to_string(),
            use_det: false,
            use_cls: false,
            auto_multilang: false,
            ..Default::default()
        };
        self.run(img, &opts)
    }

    /// 对单张裁切图做多模型打分 (用于参数/模型对比实验)
    pub fn recognize_multi(&mut self, img: &RgbImage, langs: &[String]) -> Result<Vec<(String, String, f32)>> {
        let mut out = Vec::new();
        for l in langs {
            if self.ensure_rec(l).is_err() {
                continue;
            }
            if let Some(r) = self.recs.get_mut(l) {
                let o = r.recognize(img)?;
                out.push((l.clone(), o.text, o.score));
            }
        }
        Ok(out)
    }
}

/// 按框裁切, 并对竖排文本做 90 度旋转 (RapidOCR `get_rotate_crop_image` 行为)
pub fn crop_box(img: &RgbImage, b: &DetBox) -> (RgbImage, bool) {
    let p = &b.points;
    let cw = p[0].dist(&p[1]).max(p[2].dist(&p[3]));
    let ch = p[0].dist(&p[3]).max(p[1].dist(&p[2]));
    let crop = crop_quad(img, p);
    if cw > 0.0 && ch / cw >= 1.5 {
        (rotate90_ccw(&crop), true)
    } else {
        (crop, false)
    }
}
