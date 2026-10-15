//! 二值图连通域提取
//!
//! 替代 `cv2.findContours`: 我们只需要每个文本区域的点集来算最小外接旋转矩形,
//! 因此直接做 8 邻域连通域标记并收集像素点, 再对点集求凸包 -> minAreaRect。
//! 对实心文本块而言, 这与基于轮廓的结果一致, 且实现更简单可靠。

use crate::geometry::Pt;

/// 凸包点数上限, 超过则对像素点下采样以控制耗时
const HULL_POINT_BUDGET: usize = 4000;

/// 找出所有前景连通域, 返回每个连通域的点集 (浮点像素中心坐标)
///
/// * `binary`  长度 `w*h` 的 0/1 图
/// * `min_area` 面积小于该值的连通域直接丢弃 (PaddleOCR 的 `min_size` 前置过滤)
/// * `max_candidates` 最多返回多少个候选 (PaddleOCR 默认 1000)
pub fn find_components(
    binary: &[u8],
    w: usize,
    h: usize,
    min_area: usize,
    max_candidates: usize,
) -> Vec<Vec<Pt>> {
    let mut visited = vec![0u8; w * h];
    let mut out: Vec<Vec<Pt>> = Vec::new();
    let mut stack: Vec<u32> = Vec::with_capacity(4096);
    let mut pixels: Vec<(u32, u32)> = Vec::with_capacity(4096);

    for sy in 0..h {
        let row = sy * w;
        for sx in 0..w {
            let start = row + sx;
            if binary[start] == 0 || visited[start] != 0 {
                continue;
            }
            pixels.clear();
            stack.clear();
            stack.push(start as u32);
            visited[start] = 1;

            while let Some(ci) = stack.pop() {
                let c = ci as usize;
                let cy = c / w;
                let cx = c - cy * w;
                pixels.push((cx as u32, cy as u32));

                let y0 = cy.saturating_sub(1);
                let y1 = (cy + 1).min(h - 1);
                let x0 = cx.saturating_sub(1);
                let x1 = (cx + 1).min(w - 1);
                for ny in y0..=y1 {
                    let nrow = ny * w;
                    for nx in x0..=x1 {
                        if nx == cx && ny == cy {
                            continue;
                        }
                        let ni = nrow + nx;
                        if binary[ni] != 0 && visited[ni] == 0 {
                            visited[ni] = 1;
                            stack.push(ni as u32);
                        }
                    }
                }
            }

            if pixels.len() < min_area {
                continue;
            }
            let stride = (pixels.len() / HULL_POINT_BUDGET).max(1);
            let pts: Vec<Pt> = pixels
                .iter()
                .step_by(stride)
                .map(|(x, y)| Pt::new(*x as f32 + 0.5, *y as f32 + 0.5))
                .collect();
            out.push(pts);
            if out.len() >= max_candidates {
                return out;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_two_blobs() {
        // 20x20 图, 两个 3x3 方块
        let (w, h) = (20usize, 20usize);
        let mut bin = vec![0u8; w * h];
        for y in 2..5 {
            for x in 2..5 {
                bin[y * w + x] = 1;
            }
        }
        for y in 10..14 {
            for x in 12..16 {
                bin[y * w + x] = 1;
            }
        }
        let comps = find_components(&bin, w, h, 4, 1000);
        assert_eq!(comps.len(), 2);
        assert_eq!(comps[0].len(), 9);
        assert_eq!(comps[1].len(), 16);
    }

    #[test]
    fn test_min_area_filter() {
        let (w, h) = (10usize, 10usize);
        let mut bin = vec![0u8; w * h];
        bin[0] = 1; // 面积 1
        let comps = find_components(&bin, w, h, 3, 1000);
        assert!(comps.is_empty());
    }
}
