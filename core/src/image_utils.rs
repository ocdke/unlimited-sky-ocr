//! 图像基础操作
//!
//! 关键点: 自己实现双线性缩放, 与 OpenCV `INTER_LINEAR` 的坐标映射和边界复制语义
//! 保持一致 —— 因为 PaddleOCR 的模型就是在这种插值下训练的。

use crate::error::{DpgError, Result};
use crate::geometry::Pt;
use image::{Rgb, RgbImage};

/// 从内存字节解码 (PNG/JPEG/BMP/WebP/...)
pub fn decode_memory(bytes: &[u8]) -> Result<RgbImage> {
    let img = image::load_from_memory(bytes)?;
    Ok(img.to_rgb8())
}

/// 从文件解码
pub fn decode_file(path: &std::path::Path) -> Result<RgbImage> {
    let bytes = std::fs::read(path)?;
    decode_memory(&bytes)
}

/// BGRA (Windows 截屏/GDI 输出) -> RGB, 处理行跨距
pub fn from_bgra(data: &[u8], w: u32, h: u32, stride: usize) -> Result<RgbImage> {
    from_4byte(data, w, h, stride, true)
}

/// RGBA (Android ImageReader 输出) -> RGB, 处理行跨距
pub fn from_rgba(data: &[u8], w: u32, h: u32, stride: usize) -> Result<RgbImage> {
    from_4byte(data, w, h, stride, false)
}

/// 4 字节/像素的通用转换; `swap_rb` 为 true 时输入是 BGRA, 否则是 RGBA
fn from_4byte(data: &[u8], w: u32, h: u32, stride: usize, swap_rb: bool) -> Result<RgbImage> {
    let need = if stride == 0 { w as usize * 4 } else { stride };
    if data.len() < need * h as usize {
        return Err(DpgError::rt(format!(
            "像素缓冲区过小: 需要 {} 字节, 实际 {}",
            need * h as usize,
            data.len()
        )));
    }
    let mut out = vec![0u8; w as usize * h as usize * 3];
    for y in 0..h as usize {
        let src = &data[y * need..y * need + w as usize * 4];
        let dst = &mut out[y * w as usize * 3..(y + 1) * w as usize * 3];
        for x in 0..w as usize {
            let (r, b) = if swap_rb {
                (src[x * 4 + 2], src[x * 4])
            } else {
                (src[x * 4], src[x * 4 + 2])
            };
            dst[x * 3] = r;
            dst[x * 3 + 1] = src[x * 4 + 1];
            dst[x * 3 + 2] = b;
        }
    }
    RgbImage::from_raw(w, h, out).ok_or_else(|| DpgError::rt("构造图像失败"))
}

/// 双线性缩放, 对齐 OpenCV INTER_LINEAR
pub fn resize_bilinear(src: &RgbImage, nw: u32, nh: u32) -> RgbImage {
    let (sw, sh) = (src.width(), src.height());
    if sw == 0 || sh == 0 || nw == 0 || nh == 0 {
        return RgbImage::new(nw.max(1), nh.max(1));
    }
    if sw == nw && sh == nh {
        return src.clone();
    }
    let mut dst = RgbImage::new(nw, nh);
    let sraw = src.as_raw();
    let draw: &mut [u8] = &mut *dst;
    let scale_x = sw as f32 / nw as f32;
    let scale_y = sh as f32 / nh as f32;
    let (swi, shi) = (sw as i32, sh as i32);

    for dy in 0..nh as i32 {
        let sy = (dy as f32 + 0.5) * scale_y - 0.5;
        let y0f = sy.floor();
        let fy = sy - y0f;
        let y0 = y0f as i32;
        let y1 = y0 + 1;
        let y0c = y0.clamp(0, shi - 1) as usize;
        let y1c = y1.clamp(0, shi - 1) as usize;
        let row0 = y0c * sw as usize * 3;
        let row1 = y1c * sw as usize * 3;
        let drow = dy as usize * nw as usize * 3;

        for dx in 0..nw as i32 {
            let sx = (dx as f32 + 0.5) * scale_x - 0.5;
            let x0f = sx.floor();
            let fx = sx - x0f;
            let x0 = x0f as i32;
            let x1 = x0 + 1;
            let x0c = x0.clamp(0, swi - 1) as usize;
            let x1c = x1.clamp(0, swi - 1) as usize;

            let c00 = row0 + x0c * 3;
            let c01 = row0 + x1c * 3;
            let c10 = row1 + x0c * 3;
            let c11 = row1 + x1c * 3;
            let di = drow + dx as usize * 3;

            let w00 = (1.0 - fx) * (1.0 - fy);
            let w01 = fx * (1.0 - fy);
            let w10 = (1.0 - fx) * fy;
            let w11 = fx * fy;

            for ch in 0..3 {
                let v = sraw[c00 + ch] as f32 * w00
                    + sraw[c01 + ch] as f32 * w01
                    + sraw[c10 + ch] as f32 * w10
                    + sraw[c11 + ch] as f32 * w11;
                draw[di + ch] = (v + 0.5) as u8;
            }
        }
    }
    dst
}

#[inline]
fn sample_bilinear_clamped(src: &RgbImage, x: f32, y: f32) -> [u8; 3] {
    let (sw, sh) = (src.width() as i32, src.height() as i32);
    let x = x.clamp(0.0, (sw - 1) as f32);
    let y = y.clamp(0.0, (sh - 1) as f32);
    let x0f = x.floor();
    let y0f = y.floor();
    let fx = x - x0f;
    let fy = y - y0f;
    let x0 = x0f as i32;
    let y0 = y0f as i32;
    let x1 = (x0 + 1).min(sw - 1);
    let y1 = (y0 + 1).min(sh - 1);
    let raw = src.as_raw();
    let idx = |xx: i32, yy: i32| ((yy * sw + xx) * 3) as usize;
    let (i00, i01, i10, i11) = (idx(x0, y0), idx(x1, y0), idx(x0, y1), idx(x1, y1));
    let mut out = [0u8; 3];
    for ch in 0..3 {
        let v = raw[i00 + ch] as f32 * (1.0 - fx) * (1.0 - fy)
            + raw[i01 + ch] as f32 * fx * (1.0 - fy)
            + raw[i10 + ch] as f32 * (1.0 - fx) * fy
            + raw[i11 + ch] as f32 * fx * fy;
        out[ch] = (v + 0.5) as u8;
    }
    out
}

/// 按 4 点 (顺序: 左上, 右上, 右下, 左下) 裁切并矫正为轴对齐矩形
///
/// 矩形 -> 矩形是仿射映射, 因此直接用 `p = p0 + u*(p1-p0) + v*(p3-p0)` 反查采样,
/// 无需解单应矩阵, 结果与 `cv2.warpPerspective` 等价。
pub fn crop_quad(src: &RgbImage, quad: &[Pt; 4]) -> RgbImage {
    let w = quad[0].dist(&quad[1]).max(quad[3].dist(&quad[2])).round();
    let h = quad[0].dist(&quad[3]).max(quad[1].dist(&quad[2])).round();
    let w = (w.max(1.0)) as u32;
    let h = (h.max(1.0)) as u32;

    let ax = quad[1].x - quad[0].x;
    let ay = quad[1].y - quad[0].y;
    let bx = quad[3].x - quad[0].x;
    let by = quad[3].y - quad[0].y;

    let mut dst = RgbImage::new(w, h);
    {
        let draw: &mut [u8] = &mut *dst;
        for y in 0..h {
            let v = (y as f32 + 0.5) / h as f32;
            let drow = y as usize * w as usize * 3;
            for x in 0..w {
                let u = (x as f32 + 0.5) / w as f32;
                let sx = quad[0].x + ax * u + bx * v;
                let sy = quad[0].y + ay * u + by * v;
                let px = sample_bilinear_clamped(src, sx, sy);
                let di = drow + x as usize * 3;
                draw[di] = px[0];
                draw[di + 1] = px[1];
                draw[di + 2] = px[2];
            }
        }
    }
    dst
}

/// 旋转 180 度
pub fn rotate180(src: &RgbImage) -> RgbImage {
    let (w, h) = (src.width(), src.height());
    let mut dst = RgbImage::new(w, h);
    let sraw = src.as_raw();
    let draw: &mut [u8] = &mut *dst;
    let n = (w * h) as usize;
    for i in 0..n {
        let si = (n - 1 - i) * 3;
        let di = i * 3;
        draw[di] = sraw[si];
        draw[di + 1] = sraw[si + 1];
        draw[di + 2] = sraw[si + 2];
    }
    dst
}

/// 逆时针旋转 90 度
pub fn rotate90_ccw(src: &RgbImage) -> RgbImage {
    let (w, h) = (src.width(), src.height());
    // 新图宽 = h, 高 = w
    let mut dst = RgbImage::new(h, w);
    let sraw = src.as_raw();
    let draw: &mut [u8] = &mut *dst;
    for y in 0..h {
        for x in 0..w {
            // 原 (x, y) -> 新 (y, w-1-x)
            let nx = y as usize;
            let ny = (w - 1 - x) as usize;
            let si = ((y * w + x) * 3) as usize;
            let di = ((ny * h as usize + nx) * 3) as usize;
            draw[di] = sraw[si];
            draw[di + 1] = sraw[si + 1];
            draw[di + 2] = sraw[si + 2];
        }
    }
    dst
}

/// 图像外扩 padding (PaddleOCR `image_padding`: 太小的图先补一圈再缩放)
pub fn pad_replicate(src: &RgbImage, top: u32, bottom: u32, left: u32, right: u32) -> RgbImage {
    if top == 0 && bottom == 0 && left == 0 && right == 0 {
        return src.clone();
    }
    let nw = src.width() + left + right;
    let nh = src.height() + top + bottom;
    let mut dst = RgbImage::new(nw, nh);
    {
        let draw: &mut [u8] = &mut *dst;
        for y in 0..nh {
            let sy = (y as i32 - top as i32).clamp(0, src.height() as i32 - 1) as u32;
            for x in 0..nw {
                let sx = (x as i32 - left as i32).clamp(0, src.width() as i32 - 1) as u32;
                let px = src.get_pixel(sx, sy);
                let di = ((y * nw + x) * 3) as usize;
                draw[di] = px[0];
                draw[di + 1] = px[1];
                draw[di + 2] = px[2];
            }
        }
    }
    let _ = Rgb([0u8, 0, 0]);
    dst
}

/// 按整数矩形裁剪, 越界部分用边缘像素复制
pub fn crop_rect(src: &RgbImage, x: i32, y: i32, w: u32, h: u32) -> RgbImage {
    let mut dst = RgbImage::new(w.max(1), h.max(1));
    {
        let draw: &mut [u8] = &mut *dst;
        for yy in 0..h {
            let sy = (y + yy as i32).clamp(0, src.height() as i32 - 1);
            for xx in 0..w {
                let sx = (x + xx as i32).clamp(0, src.width() as i32 - 1);
                let px = src.get_pixel(sx as u32, sy as u32);
                let di = ((yy as usize * w as usize) + xx as usize) * 3;
                draw[di] = px[0];
                draw[di + 1] = px[1];
                draw[di + 2] = px[2];
            }
        }
    }
    dst
}
