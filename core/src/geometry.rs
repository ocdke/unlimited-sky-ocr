//! 几何运算: 凸包 / 最小外接旋转矩形 / 点序规范化 / 矩形外扩
//!
//! 与 PaddleOCR 的 DBPostProcess 语义保持一致:
//!   - `min_area_rect` 对应 `cv2.minAreaRect`
//!   - `order_points_clockwise` 对应 `order_points_clockwise`
//!   - `expand_rect` 对应 `pyclipper.PolygonOffset` (矩形外扩 => 长宽各加 2d)

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pt {
    pub x: f32,
    pub y: f32,
}

impl Pt {
    #[inline]
    pub fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }
    #[inline]
    pub fn dist(&self, o: &Pt) -> f32 {
        ((self.x - o.x).powi(2) + (self.y - o.y).powi(2)).sqrt()
    }
    #[inline]
    pub fn to_i32(&self) -> (i32, i32) {
        (self.x.round() as i32, self.y.round() as i32)
    }
}

#[inline]
fn cross(o: &Pt, a: &Pt, b: &Pt) -> f32 {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
}

/// Andrew monotone chain 凸包 (逆时针, 去除共线点)
pub fn convex_hull(pts: &[Pt]) -> Vec<Pt> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let mut p = pts.to_vec();
    p.sort_by(|a, b| {
        a.x.partial_cmp(&b.x)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal))
    });
    p.dedup_by(|a, b| (a.x - b.x).abs() < 1e-6 && (a.y - b.y).abs() < 1e-6);
    if p.len() < 3 {
        return p;
    }

    let mut lower: Vec<Pt> = Vec::with_capacity(p.len());
    for q in p.iter() {
        while lower.len() >= 2 && cross(&lower[lower.len() - 2], &lower[lower.len() - 1], q) <= 0.0 {
            lower.pop();
        }
        lower.push(*q);
    }
    let mut upper: Vec<Pt> = Vec::with_capacity(p.len());
    for q in p.iter().rev() {
        while upper.len() >= 2 && cross(&upper[upper.len() - 2], &upper[upper.len() - 1], q) <= 0.0 {
            upper.pop();
        }
        upper.push(*q);
    }
    lower.pop();
    upper.pop();
    lower.extend(upper);
    lower
}

/// 最小面积外接旋转矩形 (rotating calipers)
/// 返回 4 个角点 (未排序), 以及 (宽, 高)
pub fn min_area_rect(pts: &[Pt]) -> Option<([Pt; 4], f32, f32)> {
    if pts.is_empty() {
        return None;
    }
    let hull = convex_hull(pts);
    if hull.is_empty() {
        return None;
    }
    // 退化: 单点
    if hull.len() == 1 {
        let p = hull[0];
        return Some(([p, p, p, p], 0.0, 0.0));
    }
    // 退化: 线段 -> 用一个极小的矩形包裹
    if hull.len() == 2 {
        let (a, b) = (hull[0], hull[1]);
        let len = a.dist(&b);
        let (dx, dy) = if len > 1e-9 {
            ((b.x - a.x) / len, (b.y - a.y) / len)
        } else {
            (1.0, 0.0)
        };
        let (nx, ny) = (-dy, dx);
        let e = 0.5f32;
        let c = [
            Pt::new(a.x + nx * e, a.y + ny * e),
            Pt::new(b.x + nx * e, b.y + ny * e),
            Pt::new(b.x - nx * e, b.y - ny * e),
            Pt::new(a.x - nx * e, a.y - ny * e),
        ];
        return Some((c, len, 1.0));
    }

    let n = hull.len();
    let mut best_area = f32::INFINITY;
    let mut best: Option<([Pt; 4], f32, f32)> = None;

    for i in 0..n {
        let j = (i + 1) % n;
        let ex = hull[j].x - hull[i].x;
        let ey = hull[j].y - hull[i].y;
        let len = (ex * ex + ey * ey).sqrt();
        if len < 1e-9 {
            continue;
        }
        let (ux, uy) = (ex / len, ey / len);
        let (vx, vy) = (-uy, ux);

        let mut min_u = f32::INFINITY;
        let mut max_u = f32::NEG_INFINITY;
        let mut min_v = f32::INFINITY;
        let mut max_v = f32::NEG_INFINITY;
        for p in &hull {
            let u = p.x * ux + p.y * uy;
            let v = p.x * vx + p.y * vy;
            if u < min_u {
                min_u = u;
            }
            if u > max_u {
                max_u = u;
            }
            if v < min_v {
                min_v = v;
            }
            if v > max_v {
                max_v = v;
            }
        }
        let w = max_u - min_u;
        let h = max_v - min_v;
        let area = w * h;
        if area < best_area {
            best_area = area;
            let mk = |u: f32, v: f32| Pt::new(u * ux + v * vx, u * uy + v * vy);
            best = Some((
                [
                    mk(min_u, min_v),
                    mk(max_u, min_v),
                    mk(max_u, max_v),
                    mk(min_u, max_v),
                ],
                w,
                h,
            ));
        }
    }
    best
}

/// 与 PaddleOCR `order_points_clockwise` 一致: 返回 [左上, 右上, 右下, 左下]
pub fn order_points_clockwise(pts: &[Pt]) -> [Pt; 4] {
    let mut tl = 0usize;
    let mut br = 0usize;
    let mut tr = 0usize;
    let mut bl = 0usize;
    let mut min_sum = f32::INFINITY;
    let mut max_sum = f32::NEG_INFINITY;
    let mut min_diff = f32::INFINITY;
    let mut max_diff = f32::NEG_INFINITY;
    for (i, p) in pts.iter().enumerate() {
        let s = p.x + p.y;
        let d = p.y - p.x;
        if s < min_sum {
            min_sum = s;
            tl = i;
        }
        if s > max_sum {
            max_sum = s;
            br = i;
        }
        if d < min_diff {
            min_diff = d;
            tr = i;
        }
        if d > max_diff {
            max_diff = d;
            bl = i;
        }
    }
    [pts[tl], pts[tr], pts[br], pts[bl]]
}

/// 多边形面积 (鞋带公式, 取绝对值)
pub fn polygon_area(pts: &[Pt]) -> f32 {
    if pts.len() < 3 {
        return 0.0;
    }
    let mut s = 0.0f32;
    for i in 0..pts.len() {
        let j = (i + 1) % pts.len();
        s += pts[i].x * pts[j].y - pts[j].x * pts[i].y;
    }
    (s * 0.5).abs()
}

/// 多边形周长
pub fn polygon_perimeter(pts: &[Pt]) -> f32 {
    if pts.len() < 2 {
        return 0.0;
    }
    let mut s = 0.0f32;
    for i in 0..pts.len() {
        let j = (i + 1) % pts.len();
        s += pts[i].dist(&pts[j]);
    }
    s
}

/// 把一个旋转矩形沿 4 条边向外扩张 `d` (等价于矩形版 PolygonOffset)
pub fn expand_rect(rect: &[Pt; 4], d: f32) -> [Pt; 4] {
    if d <= 0.0 {
        return *rect;
    }
    let cx = (rect[0].x + rect[1].x + rect[2].x + rect[3].x) * 0.25;
    let cy = (rect[0].y + rect[1].y + rect[2].y + rect[3].y) * 0.25;

    // u 轴: rect[0] -> rect[1];  v 轴: rect[0] -> rect[3]
    let mut ux = rect[1].x - rect[0].x;
    let mut uy = rect[1].y - rect[0].y;
    let ulen = (ux * ux + uy * uy).sqrt();
    if ulen < 1e-9 {
        ux = 1.0;
        uy = 0.0;
    } else {
        ux /= ulen;
        uy /= ulen;
    }
    let half_u = ulen * 0.5 + d;

    let mut vx = rect[3].x - rect[0].x;
    let mut vy = rect[3].y - rect[0].y;
    let vlen = (vx * vx + vy * vy).sqrt();
    if vlen < 1e-9 {
        vx = -uy;
        vy = ux;
    } else {
        vx /= vlen;
        vy /= vlen;
    }
    let half_v = vlen * 0.5 + d;

    let mk = |su: f32, sv: f32| Pt::new(cx + ux * half_u * su + vx * half_v * sv, cy + uy * half_u * su + vy * half_v * sv);
    [mk(-1.0, -1.0), mk(1.0, -1.0), mk(1.0, 1.0), mk(-1.0, 1.0)]
}

/// 矩形的 (宽, 高): 宽 = max(|p0p1|, |p3p2|), 高 = max(|p0p3|, |p1p2|)
pub fn rect_size(rect: &[Pt; 4]) -> (f32, f32) {
    let w = rect[0].dist(&rect[1]).max(rect[3].dist(&rect[2]));
    let h = rect[0].dist(&rect[3]).max(rect[1].dist(&rect[2]));
    (w, h)
}

/// 判断点是否在凸四边形内 (包含边界)
#[inline]
pub fn point_in_quad(p: &Pt, q: &[Pt; 4]) -> bool {
    let mut has_neg = false;
    let mut has_pos = false;
    for i in 0..4 {
        let a = &q[i];
        let b = &q[(i + 1) % 4];
        let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        if c < 0.0 {
            has_neg = true;
        } else if c > 0.0 {
            has_pos = true;
        }
        if has_neg && has_pos {
            return false;
        }
    }
    true
}

/// 四边形外接整数包围盒, 并裁剪到图像范围内
pub fn quad_bbox_i32(rect: &[Pt; 4], w: i32, h: i32) -> (i32, i32, i32, i32) {
    let mut xmin = f32::INFINITY;
    let mut ymin = f32::INFINITY;
    let mut xmax = f32::NEG_INFINITY;
    let mut ymax = f32::NEG_INFINITY;
    for p in rect.iter() {
        xmin = xmin.min(p.x);
        ymin = ymin.min(p.y);
        xmax = xmax.max(p.x);
        ymax = ymax.max(p.y);
    }
    let x0 = (xmin.floor() as i32).clamp(0, (w - 1).max(0));
    let y0 = (ymin.floor() as i32).clamp(0, (h - 1).max(0));
    let x1 = (xmax.ceil() as i32).clamp(0, (w - 1).max(0));
    let y1 = (ymax.ceil() as i32).clamp(0, (h - 1).max(0));
    (x0, y0, x1, y1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_min_area_rect_axis_aligned() {
        let pts = vec![
            Pt::new(10.0, 20.0),
            Pt::new(110.0, 20.0),
            Pt::new(110.0, 50.0),
            Pt::new(10.0, 50.0),
        ];
        let (rect, w, h) = min_area_rect(&pts).unwrap();
        let (rw, rh) = rect_size(&rect);
        assert!((rw - 100.0).abs() < 1e-3, "rw={rw}");
        assert!((rh - 30.0).abs() < 1e-3, "rh={rh}");
        assert!((w - 100.0).abs() < 1e-3);
        assert!((h - 30.0).abs() < 1e-3);
    }

    #[test]
    fn test_order_points() {
        let pts = [
            Pt::new(110.0, 50.0),
            Pt::new(10.0, 20.0),
            Pt::new(10.0, 50.0),
            Pt::new(110.0, 20.0),
        ];
        let o = order_points_clockwise(&pts);
        assert!((o[0].x - 10.0).abs() < 1e-3 && (o[0].y - 20.0).abs() < 1e-3);
        assert!((o[1].x - 110.0).abs() < 1e-3 && (o[1].y - 20.0).abs() < 1e-3);
        assert!((o[2].x - 110.0).abs() < 1e-3 && (o[2].y - 50.0).abs() < 1e-3);
        assert!((o[3].x - 10.0).abs() < 1e-3 && (o[3].y - 50.0).abs() < 1e-3);
    }

    #[test]
    fn test_expand_rect() {
        let rect = [
            Pt::new(0.0, 0.0),
            Pt::new(100.0, 0.0),
            Pt::new(100.0, 20.0),
            Pt::new(0.0, 20.0),
        ];
        let e = expand_rect(&rect, 5.0);
        let (w, h) = rect_size(&e);
        assert!((w - 110.0).abs() < 1e-3, "w={w}");
        assert!((h - 30.0).abs() < 1e-3, "h={h}");
    }
}
