//! Windows 屏幕截屏 (GDI BitBlt)
//!
//! 手写 Win32 FFI, 不引入额外 crate。截屏结果直接是 BGRA 缓冲区, 可以:
//!   * 交给 `image_utils::from_bgra` 转成 RGB 供 OCR 使用
//!   * 交给 Flutter 用 `decodeImageFromPixels` 显示选区预览
//! 避免任何中间编码开销。

#![cfg(windows)]

use crate::error::{DpgError, Result};
use std::ffi::c_void;

type Hdc = *mut c_void;
type HBitmap = *mut c_void;
type HGDIOBJ = *mut c_void;
type Bool = i32;

#[repr(C)]
#[derive(Clone, Copy)]
struct BitmapInfoHeader {
    bi_size: u32,
    bi_width: i32,
    bi_height: i32,
    bi_planes: u16,
    bi_bit_count: u16,
    bi_compression: u32,
    bi_size_image: u32,
    bi_x_pels_per_meter: i32,
    bi_y_pels_per_meter: i32,
    bi_clr_used: u32,
    bi_clr_important: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct RgbQuad {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct BitmapInfo {
    header: BitmapInfoHeader,
    colors: [RgbQuad; 1],
}

const SRCCOPY: u32 = 0x00CC_0020;
const DIB_RGB_COLORS: u32 = 0;
const BI_RGB: u32 = 0;

pub const SM_XVIRTUALSCREEN: i32 = 76;
pub const SM_YVIRTUALSCREEN: i32 = 77;
pub const SM_CXVIRTUALSCREEN: i32 = 78;
pub const SM_CYVIRTUALSCREEN: i32 = 79;

#[link(name = "user32")]
extern "system" {
    fn GetDC(hwnd: *mut c_void) -> Hdc;
    fn ReleaseDC(hwnd: *mut c_void, hdc: Hdc) -> i32;
    fn GetSystemMetrics(index: i32) -> i32;
    fn SetProcessDPIAware() -> Bool;
}

#[link(name = "gdi32")]
extern "system" {
    fn CreateCompatibleDC(hdc: Hdc) -> Hdc;
    fn DeleteDC(hdc: Hdc) -> Bool;
    fn CreateCompatibleBitmap(hdc: Hdc, w: i32, h: i32) -> HBitmap;
    fn SelectObject(hdc: Hdc, obj: HGDIOBJ) -> HGDIOBJ;
    fn DeleteObject(obj: HGDIOBJ) -> Bool;
    fn BitBlt(
        dst: Hdc,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        src: Hdc,
        sx: i32,
        sy: i32,
        rop: u32,
    ) -> Bool;
    fn GetDIBits(
        hdc: Hdc,
        bmp: HBitmap,
        start: u32,
        lines: u32,
        bits: *mut c_void,
        info: *mut BitmapInfo,
        usage: u32,
    ) -> i32;
}

/// 声明进程为 DPI 感知, 否则高 DPI 屏上拿到的是被系统缩放后的虚拟坐标
pub fn ensure_dpi_aware() {
    unsafe {
        let _ = SetProcessDPIAware();
    }
}

/// 虚拟桌面 (所有显示器合并) 的矩形: (x, y, w, h)
pub fn virtual_screen_rect() -> (i32, i32, i32, i32) {
    unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    }
}

/// 主显示器矩形
pub fn primary_screen_rect() -> (i32, i32, i32, i32) {
    unsafe {
        (
            0,
            0,
            GetSystemMetrics(0), // SM_CXSCREEN
            GetSystemMetrics(1), // SM_CYSCREEN
        )
    }
}

/// 截取屏幕区域, 返回 (BGRA 数据, 宽, 高, 行跨距)
pub fn capture_rect(x: i32, y: i32, w: i32, h: i32) -> Result<(Vec<u8>, i32, i32, i32)> {
    if w <= 0 || h <= 0 {
        return Err(DpgError::cfg(format!("截屏区域非法: {w}x{h}")));
    }
    struct DcGuard(Hdc);
    impl Drop for DcGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = ReleaseDC(std::ptr::null_mut(), self.0);
            }
        }
    }
    struct MemDcGuard(Hdc);
    impl Drop for MemDcGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = DeleteDC(self.0);
            }
        }
    }
    struct BmpGuard(HBitmap);
    impl Drop for BmpGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = DeleteObject(self.0);
            }
        }
    }

    unsafe {
        let screen = GetDC(std::ptr::null_mut());
        if screen.is_null() {
            return Err(DpgError::rt("GetDC 失败"));
        }
        let screen = DcGuard(screen);

        let mem = CreateCompatibleDC(screen.0);
        if mem.is_null() {
            return Err(DpgError::rt("CreateCompatibleDC 失败"));
        }
        let mem = MemDcGuard(mem);

        let bmp = CreateCompatibleBitmap(screen.0, w, h);
        if bmp.is_null() {
            return Err(DpgError::rt("CreateCompatibleBitmap 失败"));
        }
        let bmp = BmpGuard(bmp);

        let old = SelectObject(mem.0, bmp.0);
        if old.is_null() {
            return Err(DpgError::rt("SelectObject 失败"));
        }

        let ok = BitBlt(mem.0, 0, 0, w, h, screen.0, x, y, SRCCOPY);
        if ok == 0 {
            let _ = SelectObject(mem.0, old);
            return Err(DpgError::rt("BitBlt 失败"));
        }

        let stride = ((w * 4 + 3) / 4) * 4;
        let mut buf = vec![0u8; (stride * h) as usize];
        let mut info = BitmapInfo {
            header: BitmapInfoHeader {
                bi_size: std::mem::size_of::<BitmapInfoHeader>() as u32,
                bi_width: w,
                bi_height: -h, // 负数 = 自上而下
                bi_planes: 1,
                bi_bit_count: 32,
                bi_compression: BI_RGB,
                bi_size_image: (stride * h) as u32,
                bi_x_pels_per_meter: 0,
                bi_y_pels_per_meter: 0,
                bi_clr_used: 0,
                bi_clr_important: 0,
            },
            colors: [RgbQuad { b: 0, g: 0, r: 0, a: 0 }],
        };
        let lines = GetDIBits(
            mem.0,
            bmp.0,
            0,
            h as u32,
            buf.as_mut_ptr() as *mut c_void,
            &mut info,
            DIB_RGB_COLORS,
        );
        let _ = SelectObject(mem.0, old);
        if lines == 0 {
            return Err(DpgError::rt("GetDIBits 失败"));
        }
        // GDI 32bpp DIB 的 alpha 通道不可靠, 强制不透明
        for px in buf.chunks_exact_mut(4) {
            px[3] = 255;
        }
        Ok((buf, w, h, stride))
    }
}

// ============================================================
//  全局热键占用探测
// ============================================================

const MOD_ALT: u32 = 0x0001;
const MOD_CONTROL: u32 = 0x0002;
const MOD_SHIFT: u32 = 0x0004;
const MOD_WIN: u32 = 0x0008;
const MOD_NOREPEAT: u32 = 0x4000;

#[link(name = "user32")]
extern "system" {
    fn RegisterHotKey(hwnd: *mut c_void, id: i32, mods: u32, vk: u32) -> Bool;
    fn UnregisterHotKey(hwnd: *mut c_void, id: i32) -> Bool;
}

/// 探测一个全局热键组合是否可用 (是否已被别的程序占用)。
///
/// Windows 的 `RegisterHotKey` 在组合被占用时只是返回失败, 不少上层库
/// 会把这个失败吞掉, 于是"注册成功"其实是假的 —— 用户按下去毫无反应。
/// 这里主动试一次再注销, 用来提前告诉用户哪个快捷键不可用。
///
/// `mods` 位标志: 1=Alt 2=Ctrl 4=Shift 8=Win
pub fn probe_hotkey(mods: u32, vk: u32) -> bool {
    unsafe {
        let m = (mods & (MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) | MOD_NOREPEAT;
        // 用一个不太可能撞车的 id
        const PROBE_ID: i32 = 0x7FF0;
        if RegisterHotKey(std::ptr::null_mut(), PROBE_ID, m, vk) != 0 {
            UnregisterHotKey(std::ptr::null_mut(), PROBE_ID);
            true
        } else {
            false
        }
    }
}

/// 截取整个虚拟桌面
pub fn capture_all() -> Result<(Vec<u8>, i32, i32, i32)> {
    let (x, y, w, h) = virtual_screen_rect();
    capture_rect(x, y, w, h)
}

// ============================================================
//  窗口捕获排除
// ============================================================

const WDA_NONE: u32 = 0x0000_0000;
const WDA_EXCLUDEFROMCAPTURE: u32 = 0x0000_0011;

#[link(name = "user32")]
extern "system" {
    fn EnumWindows(
        cb: Option<unsafe extern "system" fn(*mut c_void, isize) -> Bool>,
        lparam: isize,
    ) -> Bool;
    fn GetWindowThreadProcessId(hwnd: *mut c_void, pid: *mut u32) -> u32;
    fn IsWindowVisible(hwnd: *mut c_void) -> Bool;
    fn GetWindow(hwnd: *mut c_void, cmd: u32) -> *mut c_void;
    fn SetWindowDisplayAffinity(hwnd: *mut c_void, affinity: u32) -> Bool;
}

const GW_OWNER: u32 = 4;

unsafe extern "system" fn enum_proc(hwnd: *mut c_void, lparam: isize) -> Bool {
    let ctx = &mut *(lparam as *mut FindCtx);
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if pid != ctx.pid {
        return 1;
    }
    // 只要有 owner 的就是对话框/工具窗, 跳过
    if !GetWindow(hwnd, GW_OWNER).is_null() {
        return 1;
    }
    let visible = IsWindowVisible(hwnd) != 0;
    if visible {
        // 可见窗口优先, 直接采用并停止枚举
        ctx.found = Some(hwnd);
        return 0;
    }
    // 隐藏窗口作为备选 —— 覆盖层是"先 hide 再配置"的,
    // 如果只认可见窗口, 排除捕获就会静默失效
    if ctx.found.is_none() {
        ctx.found = Some(hwnd);
    }
    1
}

struct FindCtx {
    pid: u32,
    found: Option<*mut c_void>,
}

/// 找到本进程的主窗口 (可见、无 owner 的顶层窗口)
pub fn find_main_window() -> Option<*mut c_void> {
    unsafe {
        let mut ctx = FindCtx {
            pid: std::process::id(),
            found: None,
        };
        EnumWindows(
            Some(enum_proc),
            &mut ctx as *mut FindCtx as isize,
        );
        ctx.found
    }
}

/// 把本进程主窗口从屏幕捕获中排除 (但用户仍能看到)。
///
/// 实时翻译必须在"显示译文"的同时"截取原始画面", 否则会把上一次的译文
/// 一起截进去, 形成"翻译自己的翻译"的反馈循环。
/// `WDA_EXCLUDEFROMCAPTURE` 需要 Windows 10 2004 (build 19041) 及以上。
///
/// 返回 true 表示设置成功。
pub fn set_capture_exclusion(exclude: bool) -> bool {
    unsafe {
        let hwnd = match find_main_window() {
            Some(h) => h,
            None => return false,
        };
        let affinity = if exclude {
            WDA_EXCLUDEFROMCAPTURE
        } else {
            WDA_NONE
        };
        SetWindowDisplayAffinity(hwnd, affinity) != 0
    }
}
