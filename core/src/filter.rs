//! OCR 结果噪声过滤
//!
//! 检测器会把图标、线条、装饰性图形也当成文本框, 识别出来就是一堆
//! 单字符、纯符号、重复字符之类的垃圾行。
//!
//! 但**过滤太狠会把真内容也杀掉** —— 中日文里单字成行很常见 (菜单项、
//! 数字、单位), 所以这里做成分档的, 由用户按自己的场景选。
//!
//! ```text
//! 0 = 关闭     什么都不过滤, 宁可多留
//! 1 = 宽松     只杀掉明显是碎片的东西 (默认)
//! 2 = 标准     再加上单字符、纯符号
//! 3 = 严格     再加上有效字符占比要求
//! ```

/// 噪声过滤档位
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoiseLevel {
    Off = 0,
    Loose = 1,
    Normal = 2,
    Strict = 3,
}

impl NoiseLevel {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => NoiseLevel::Off,
            1 => NoiseLevel::Loose,
            2 => NoiseLevel::Normal,
            _ => NoiseLevel::Strict,
        }
    }
}

/// 判断一段识别结果是否应作为噪声丢弃
pub fn is_noise(
    text: &str,
    score: f32,
    w: f32,
    h: f32,
    min_score: f32,
    level: NoiseLevel,
) -> bool {
    if level == NoiseLevel::Off {
        return text.trim().is_empty();
    }
    // 置信度门槛在任何档位都生效 —— 这是最可靠的信号
    if score < min_score {
        return true;
    }
    let t = text.trim();
    if t.is_empty() {
        return true;
    }

    // 文本框过小: 多半是图标碎片。放到 4px, 之前 6px 会误杀小字
    if w < 4.0 || h < 4.0 {
        return true;
    }

    let chars: Vec<char> = t.chars().filter(|c| !c.is_whitespace()).collect();
    if chars.is_empty() {
        return true;
    }

    // 全是同一个字符 (如 "----"、"aaaa"、"◆◆◆◆")。
    // 长度门槛放到 4, 这样 "11"、"。。" 不会被误杀
    if chars.len() >= 4 && chars.iter().all(|&c| c == chars[0]) {
        return true;
    }

    if level == NoiseLevel::Loose {
        return false;
    }

    // ---- Normal 及以上 ----
    // 单字符: 中日文场景下真的会出现在界面里, 所以只在"标准"以上才丢
    if chars.len() < 2 {
        return true;
    }

    let meaningful = chars.iter().filter(|&&c| is_meaningful(c)).count();

    if level == NoiseLevel::Normal {
        // 两个字符里一个有效字符都没有 -> 纯符号
        return chars.len() <= 2 && meaningful == 0;
    }

    // ---- Strict ----
    let ratio = meaningful as f32 / chars.len() as f32;
    ratio < 0.34
}

/// 是否算"有意义的字符"
fn is_meaningful(c: char) -> bool {
    if c.is_alphanumeric() {
        return true;
    }
    // CJK 统一表意文字 / 假名 / 谚文 / 西里尔 / 希腊 / 阿拉伯 / 泰文 / 天城文
    matches!(c as u32,
        0x3040..=0x30FF      // 平假名 + 片假名
        | 0x3400..=0x4DBF    // CJK 扩展 A
        | 0x4E00..=0x9FFF    // CJK 基本区
        | 0xAC00..=0xD7AF    // 谚文音节
        | 0x1100..=0x11FF    // 谚文字母
        | 0x0400..=0x04FF    // 西里尔
        | 0x0370..=0x03FF    // 希腊
        | 0x0600..=0x06FF    // 阿拉伯
        | 0x0E00..=0x0E7F    // 泰文
        | 0x0900..=0x097F    // 天城文
        | 0x0F00..=0x0FFF    // 藏文
    )
}

/// 去除重复行: 同一段文本、位置高度重叠时只保留置信度最高的那条
pub fn dedup<T, F>(items: &mut Vec<T>, mut key: F)
where
    F: FnMut(&T) -> (String, f32, f32, f32, f32, f32),
{
    let mut best: Vec<(String, f32, f32, f32, f32, f32)> = Vec::new();
    let mut keep: Vec<bool> = Vec::with_capacity(items.len());
    for it in items.iter() {
        let (text, score, cx, cy, w, h) = key(it);
        let mut dup = false;
        for b in best.iter_mut() {
            if b.0 != text {
                continue;
            }
            let dx = (b.2 - cx).abs();
            let dy = (b.3 - cy).abs();
            if dx < (b.4 + w) * 0.25 && dy < (b.5 + h) * 0.25 {
                dup = true;
                if score > b.1 {
                    b.1 = score;
                }
                break;
            }
        }
        if !dup {
            best.push((text, score, cx, cy, w, h));
        }
        keep.push(!dup);
    }
    let mut i = 0;
    items.retain(|_| {
        let k = keep[i];
        i += 1;
        k
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use NoiseLevel::*;

    #[test]
    fn loose_keeps_single_chars() {
        // 宽松档: 单字必须留下 —— 中日文界面里很常见
        assert!(!is_noise("确", 0.9, 20.0, 20.0, 0.5, Loose));
        assert!(!is_noise("5", 0.9, 20.0, 20.0, 0.5, Loose));
        assert!(!is_noise("OK", 0.9, 30.0, 18.0, 0.5, Loose));
    }

    #[test]
    fn loose_still_drops_obvious_junk() {
        assert!(is_noise("----", 0.9, 20.0, 20.0, 0.5, Loose));
        assert!(is_noise("....", 0.9, 20.0, 20.0, 0.5, Loose));
        assert!(is_noise("", 0.9, 20.0, 20.0, 0.5, Loose));
        assert!(is_noise("hello", 0.9, 3.0, 20.0, 0.5, Loose));
        assert!(is_noise("hello", 0.2, 100.0, 20.0, 0.5, Loose));
    }

    #[test]
    fn normal_drops_single_chars() {
        assert!(is_noise("确", 0.9, 20.0, 20.0, 0.5, Normal));
        assert!(!is_noise("确定", 0.9, 40.0, 20.0, 0.5, Normal));
    }

    #[test]
    fn strict_requires_meaningful_ratio() {
        // 3 个纯符号 -> 丢
        assert!(is_noise("。、，", 0.9, 60.0, 20.0, 0.5, Strict));
        // 1 有效 / 4 总数 = 25% < 34% -> 仍在丢弃范围
        assert!(is_noise("a。、，", 0.9, 60.0, 20.0, 0.5, Strict));
        // 2 有效 / 4 总数 = 50% -> 保留
        assert!(!is_noise("ab。、", 0.9, 60.0, 20.0, 0.5, Strict));
    }

    #[test]
    fn off_keeps_everything() {
        assert!(!is_noise("----", 0.1, 2.0, 2.0, 0.5, Off));
        assert!(is_noise("   ", 0.1, 20.0, 20.0, 0.5, Off));
    }

    #[test]
    fn keeps_real_text() {
        for lv in [Loose, Normal, Strict] {
            assert!(!is_noise("Hello world", 0.9, 120.0, 20.0, 0.5, lv));
            assert!(!is_noise("全屏识别翻译", 0.9, 120.0, 22.0, 0.5, lv));
            assert!(!is_noise("42", 0.9, 30.0, 18.0, 0.5, lv));
        }
    }
}
