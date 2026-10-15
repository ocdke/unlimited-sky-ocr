//! 安装程序的图形界面 (纯 Win32)
//!
//! 布局是"设计像素", 运行时按窗口 DPI 整体缩放, 所以在 125% / 150% 缩放下
//! 不会糊也不会错位。

use std::ffi::c_void;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use crate::{install, launch, Entry, Options, Progress, APP_EXE, APP_NAME};

// ============================================================
//  Win32 绑定 (只声明用到的部分)
// ============================================================

type Hwnd = *mut c_void;
type Hinstance = *mut c_void;
type Hbrush = *mut c_void;
type Hfont = *mut c_void;
type Hicon = *mut c_void;
type Hmenu = *mut c_void;
type Hkey = *mut c_void;

const WS_OVERLAPPED: u32 = 0x0000_0000;
const WS_CAPTION: u32 = 0x00C0_0000;
const WS_SYSMENU: u32 = 0x0008_0000;
const WS_MINIMIZEBOX: u32 = 0x0002_0000;
const WS_CHILD: u32 = 0x4000_0000;
const WS_VISIBLE: u32 = 0x1000_0000;
const WS_TABSTOP: u32 = 0x0001_0000;
const WS_BORDER: u32 = 0x0080_0000;
const WS_VSCROLL: u32 = 0x0020_0000;
const ES_AUTOHSCROLL: u32 = 0x0080;
const ES_LEFT: u32 = 0x0000;
const BS_PUSHBUTTON: u32 = 0x0000_0000;
const BS_DEFPUSHBUTTON: u32 = 0x0000_0001;
const BS_AUTOCHECKBOX: u32 = 0x0000_0003;
const SS_LEFT: u32 = 0x0000_0000;
const SS_ICON: u32 = 0x0000_0003;
const SS_CENTERIMAGE: u32 = 0x0000_0200;
const STM_SETICON: u32 = 0x0170;


const SW_SHOW: i32 = 5;
const SW_HIDE: i32 = 0;
const SW_ENABLE: i32 = 1;
const SW_DISABLE: i32 = 0;

const WM_CREATE: u32 = 0x0001;
const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const WM_CLOSE: u32 = 0x0010;
const WM_COMMAND: u32 = 0x0111;
const WM_SETFONT: u32 = 0x0030;
const WM_GETTEXT: u32 = 0x000D;
const WM_GETTEXTLENGTH: u32 = 0x000E;
const WM_TIMER: u32 = 0x0113;
const WM_CTLCOLORSTATIC: u32 = 0x0138;
const WM_CTLCOLOREDIT: u32 = 0x0133;
const WM_CTLCOLORBTN: u32 = 0x0135;
const WM_APP: u32 = 0x8000;

const COLOR_WINDOW: u32 = 5;
const TRANSPARENT: i32 = 1;
const DT_LEFT: u32 = 0x0000_0000;
const DT_SINGLELINE: u32 = 0x0000_0020;
const DT_VCENTER: u32 = 0x0000_0004;
const DT_NOPREFIX: u32 = 0x0000_0800;

const IMAGE_ICON: u32 = 1;
const LR_DEFAULTCOLOR: u32 = 0x0000_0000;
const DI_NORMAL: u32 = 0x0003;

const PBM_SETRANGE32: u32 = 0x0406;
const PBM_SETPOS: u32 = 0x0402;
const PBS_SMOOTH: u32 = 0x0000_0001;
const PROGRESS_CLASS: &str = "msctls_progress32";

const BIF_RETURNONLYFSDIRS: u32 = 0x0000_0001;
const BIF_NEWDIALOGSTYLE: u32 = 0x0000_0040;
const BIF_USENEWUI: u32 = BIF_NEWDIALOGSTYLE | 0x0000_0040;
const BFFM_INITIALIZED: i32 = 1;
const BFFM_SETSELECTIONW: u32 = 0x0467;

const CS_HREDRAW: u32 = 0x0002;
const CS_VREDRAW: u32 = 0x0001;
const IDC_ARROW: u32 = 32512;

#[repr(C)]
struct WndClassExW {
    cb_size: u32,
    style: u32,
    lpfn_wnd_proc: Option<unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize>,
    cb_cls_extra: i32,
    cb_wnd_extra: i32,
    h_instance: Hinstance,
    h_icon: Hicon,
    h_cursor: Hicon,
    hbr_background: Hbrush,
    lpsz_menu_name: *const u16,
    lpsz_class_name: *const u16,
    h_icon_sm: Hicon,
}

#[repr(C)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

#[repr(C)]
struct Point {
    x: i32,
    y: i32,
}

#[repr(C)]
struct Msg {
    hwnd: Hwnd,
    message: u32,
    w_param: usize,
    l_param: isize,
    time: u32,
    pt: Point,
}

#[repr(C)]
struct PaintStruct {
    hdc: *mut c_void,
    f_erase: i32,
    rc_paint: Rect,
    f_restore: i32,
    f_inc_update: i32,
    rgb_reserved: [u8; 32],
}

#[repr(C)]
struct BrowseInfoW {
    hwnd_owner: Hwnd,
    pidl_root: *mut c_void,
    psz_display_name: *mut u16,
    lpsz_title: *const u16,
    ul_flags: u32,
    lpfn: Option<unsafe extern "system" fn(Hwnd, u32, isize, isize) -> i32>,
    l_param: isize,
    i_image: i32,
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassExW(wc: *const WndClassExW) -> u16;
    fn CreateWindowExW(
        ex_style: u32,
        class: *const u16,
        title: *const u16,
        style: u32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        parent: Hwnd,
        menu: Hmenu,
        inst: Hinstance,
        param: *mut c_void,
    ) -> Hwnd;
    fn DefWindowProcW(h: Hwnd, m: u32, w: usize, l: isize) -> isize;
    fn DestroyWindow(h: Hwnd) -> i32;
    fn PostQuitMessage(code: i32);
    fn GetMessageW(msg: *mut Msg, h: Hwnd, min: u32, max: u32) -> i32;
    fn TranslateMessage(msg: *const Msg) -> i32;
    fn DispatchMessageW(msg: *const Msg) -> isize;
    fn SendMessageW(h: Hwnd, m: u32, w: usize, l: isize) -> isize;
    fn PostMessageW(h: Hwnd, m: u32, w: usize, l: isize) -> i32;
    fn SetWindowTextW(h: Hwnd, s: *const u16) -> i32;
    fn GetWindowTextW(h: Hwnd, buf: *mut u16, max: i32) -> i32;
    fn GetClientRect(h: Hwnd, r: *mut Rect) -> i32;
    fn GetWindowRect(h: Hwnd, r: *mut Rect) -> i32;
    fn AdjustWindowRectEx(r: *mut Rect, style: u32, menu: i32, ex: u32) -> i32;
    fn ShowWindow(h: Hwnd, cmd: i32) -> i32;
    fn UpdateWindow(h: Hwnd) -> i32;
    fn EnableWindow(h: Hwnd, enable: i32) -> i32;
    fn SetTimer(h: Hwnd, id: usize, ms: u32, cb: *mut c_void) -> usize;
    fn KillTimer(h: Hwnd, id: usize) -> i32;
    fn SetWindowLongPtrW(h: Hwnd, index: i32, value: isize) -> isize;
    fn GetWindowLongPtrW(h: Hwnd, index: i32) -> isize;
    fn BeginPaint(h: Hwnd, ps: *mut PaintStruct) -> *mut c_void;
    fn EndPaint(h: Hwnd, ps: *const PaintStruct) -> i32;
    fn InvalidateRect(h: Hwnd, r: *const Rect, erase: i32) -> i32;
    fn FillRect(hdc: *mut c_void, r: *const Rect, b: Hbrush) -> i32;
    fn DrawTextW(hdc: *mut c_void, s: *const u16, n: i32, r: *mut Rect, fmt: u32) -> i32;
    fn DrawIconEx(
        hdc: *mut c_void,
        x: i32,
        y: i32,
        icon: Hicon,
        cx: i32,
        cy: i32,
        istep: u32,
        hbr: Hbrush,
        flags: u32,
    ) -> i32;
    fn LoadImageW(inst: Hinstance, name: *const u16, ty: u32, cx: i32, cy: i32, fu: u32)
        -> Hicon;
    fn LoadCursorW(inst: Hinstance, name: *const u16) -> Hicon;
    fn SetProcessDPIAware() -> i32;
    fn GetDC(h: Hwnd) -> *mut c_void;
    fn ReleaseDC(h: Hwnd, hdc: *mut c_void) -> i32;
    fn MessageBoxW(h: Hwnd, text: *const u16, caption: *const u16, ty: u32) -> i32;
    fn SetForegroundWindow(h: Hwnd) -> i32;
    fn GetSystemMetrics(i: i32) -> i32;
}

#[link(name = "gdi32")]
extern "system" {
    fn CreateSolidBrush(c: u32) -> Hbrush;
    fn CreateFontW(
        h: i32,
        w: i32,
        esc: i32,
        orient: i32,
        weight: i32,
        italic: u32,
        underline: u32,
        strike: u32,
        charset: u32,
        prec: u32,
        clip: u32,
        quality: u32,
        pitch: u32,
        face: *const u16,
    ) -> Hfont;
    fn SetTextColor(hdc: *mut c_void, c: u32) -> u32;
    fn SetBkColor(hdc: *mut c_void, c: u32) -> u32;
    fn SetBkMode(hdc: *mut c_void, mode: i32) -> i32;
    fn GetStockObject(i: i32) -> *mut c_void;
}

#[link(name = "shell32")]
extern "system" {
    fn SHBrowseForFolderW(bi: *const BrowseInfoW) -> *mut c_void;
    fn SHGetPathFromIDListW(pidl: *const c_void, path: *mut u16) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> Hinstance;
    fn GetLastError() -> u32;
}

#[link(name = "comctl32")]
extern "system" {
    fn InitCommonControlsEx(icc: *const InitCommonControls) -> i32;
}

#[repr(C)]
struct InitCommonControls {
    size: u32,
    classes: u32,
}
const ICC_PROGRESS_CLASS: u32 = 0x0000_0020;

// ============================================================
//  辅助
// ============================================================

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

const COL_BG: u32 = 0x00FA_F7F5; // BGR! 浅灰底
const COL_HEADER: u32 = 0x001B_1614; // 深色头部 (#14161B)
const COL_TEXT: u32 = 0x0020_2020;
const COL_SUB: u32 = 0x0090_8A85;
const COL_ACCENT: u32 = 0x00F7_C34F; // #4FC3F7 -> BGR

// 控件 ID
const ID_APP_EDIT: usize = 1001;
const ID_APP_BROWSE: usize = 1002;
const ID_MODEL_EDIT: usize = 1003;
const ID_MODEL_BROWSE: usize = 1004;
const ID_CHK_DESKTOP: usize = 1005;
const ID_CHK_START: usize = 1006;
const ID_CHK_RUN: usize = 1007;
const ID_INSTALL: usize = 1008;
const ID_CLOSE: usize = 1009;
const ID_PROGRESS: usize = 1010;
const ID_STATUS: usize = 1011;
const ID_LOGO: usize = 1012;
const ID_CHK_AI: usize = 1013;
const ID_AI_INFO: usize = 1014;
const ID_AI_REQ: usize = 1015;
/// 编辑框内容变化通知码 (WM_COMMAND 的高位)
const EN_CHANGE: u32 = 0x0300;
const ID_AI_EDIT: usize = 1016;
const ID_AI_BROWSE: usize = 1017;
const ID_AI_NOTE: usize = 1018;
const TIMER_ID: usize = 1;

const DESIGN_W: i32 = 680;
const DESIGN_H: i32 = 692;

pub struct AppState {
    entries: Arc<Vec<Entry>>,
    self_path: PathBuf,
    hwnd: Hwnd,
    scale: f32,
    font: Hfont,
    font_bold: Hfont,
    font_title: Hfont,
    font_small: Hfont,
    brush_bg: Hbrush,
    brush_edit: Hbrush,
    brush_header: Hbrush,
    icon: Hicon,
    installing: bool,
    progress: Progress,
    opt: Mutex<Option<Options>>,
    app_dir: Mutex<String>,
    model_dir: Mutex<String>,
    ai_dir: Mutex<String>,
    /// AI 目标磁盘空间是否够 (WM_CTLCOLORSTATIC 里要读, 用原子量)
    ai_space_ok: std::sync::atomic::AtomicBool,
    /// 硬件检测结论, 决定 AI 那一段显示什么颜色 / 能不能勾
    verdict: crate::hw::Verdict,
    vram_mb: u32,
}

impl AppState {
    fn s(&self, v: i32) -> i32 {
        (v as f32 * self.scale).round() as i32
    }
}

unsafe extern "system" fn browse_callback(h: Hwnd, msg: u32, _lp: isize, data: isize) -> i32 {
    if msg == BFFM_INITIALIZED as u32 {
        if data != 0 {
            let s = data as *const u16;
            SendMessageW(h, BFFM_SETSELECTIONW, 1, s as isize);
        }
    }
    0
}

/// 弹出文件夹选择对话框
fn pick_folder(owner: Hwnd, title: &str, initial: &str) -> Option<String> {
    unsafe {
        let init = wide(initial);
        let t = wide(title);
        let bi = BrowseInfoW {
            hwnd_owner: owner,
            pidl_root: std::ptr::null_mut(),
            psz_display_name: std::ptr::null_mut(),
            lpsz_title: t.as_ptr(),
            ul_flags: BIF_RETURNONLYFSDIRS | BIF_USENEWUI,
            lpfn: Some(browse_callback),
            l_param: init.as_ptr() as isize,
            i_image: 0,
        };
        let pidl = SHBrowseForFolderW(&bi);
        if pidl.is_null() {
            return None;
        }
        let mut buf = [0u16; 520];
        let ok = SHGetPathFromIDListW(pidl, buf.as_mut_ptr());
        if ok == 0 {
            return None;
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(0);
        Some(String::from_utf16_lossy(&buf[..len]))
    }
}

/// 读控件文本。
///
/// 早先用的是 "先 WM_GETTEXTLENGTH 问长度, 再按长度 GetWindowTextW",
/// 实测在自定义路径这种场景下会读到**初始值**而不是当前值 ——
/// 路径类输入框直接给足缓冲一次读完, 少一步就少一个出错的地方。
fn get_text(h: Hwnd) -> String {
    unsafe {
        if h.is_null() {
            return String::new();
        }
        let mut buf = vec![0u16; 2048];
        let n = GetWindowTextW(h, buf.as_mut_ptr(), buf.len() as i32);
        if n <= 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..n as usize])
    }
}

// ============================================================
//  窗口过程
// ============================================================

unsafe extern "system" fn wnd_proc(h: Hwnd, msg: u32, w: usize, l: isize) -> isize {
    let ptr = GetWindowLongPtrW(h, -21) as *mut AppState; // GWLP_USERDATA

    match msg {
        WM_CREATE => {
            let cs = l as *const u32; // 借 CREATESTRUCT 传不进来, 用全局初始化
            let _ = cs;
            0
        }
        WM_PAINT => {
            let st = &*ptr;
            let mut ps = std::mem::zeroed::<PaintStruct>();
            let hdc = BeginPaint(h, &mut ps);
            let mut rc = std::mem::zeroed::<Rect>();
            GetClientRect(h, &mut rc);

            // 背景
            FillRect(hdc, &rc, st.brush_bg);

            // 头部深色块
            let hh = st.s(104);
            let head = Rect {
                left: 0,
                top: 0,
                right: rc.right,
                bottom: hh,
            };
            let hb = CreateSolidBrush(COL_HEADER);
            FillRect(hdc, &head, hb);

            // 头部底部的强调线
            let line = Rect {
                left: 0,
                top: hh - st.s(2),
                right: rc.right,
                bottom: hh,
            };
            let lb = CreateSolidBrush(COL_ACCENT);
            FillRect(hdc, &line, lb);

            // 图标由 STATIC 控件绘制 (见下面 ID_LOGO), 这里只算文字起点
            SetBkMode(hdc, TRANSPARENT);
            let tx = st.s(28) + st.s(56) + st.s(18);

            // 标题
            SetTextColor(hdc, 0x00FF_FFFF);
            let mut r1 = Rect {
                left: tx,
                top: st.s(28),
                right: rc.right - st.s(20),
                bottom: st.s(28) + st.s(30),
            };
            let title = wide(APP_NAME);
            DrawTextW(
                hdc,
                title.as_ptr(),
                -1,
                &mut r1,
                DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX,
            );

            // 副标题
            SetTextColor(hdc, 0x0090_8A85);
            let mut r2 = Rect {
                left: tx,
                top: st.s(58),
                right: rc.right - st.s(20),
                bottom: st.s(58) + st.s(24),
            };
            let sub = wide("安装向导  ·  无境天");
            DrawTextW(
                hdc,
                sub.as_ptr(),
                -1,
                &mut r2,
                DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX,
            );

            EndPaint(h, &ps);
            0
        }
        WM_CTLCOLORSTATIC => {
            let st = &*ptr;
            let hdc = w as *mut c_void;
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, COL_TEXT);
            // 状态文字用灰色
            let child = l as Hwnd;
            let id = unsafe { GetWindowLongPtrW(child, -12) } as usize; // GWLP_ID
            if id == ID_STATUS {
                SetTextColor(hdc, COL_SUB);
            }
            if id == ID_AI_INFO {
                use crate::hw::AiTier;
                SetTextColor(
                    hdc,
                    match st.verdict.tier {
                        AiTier::Great | AiTier::Good => 0x0050_C878, // 绿
                        AiTier::Tight => 0x0000_A5FF,                // 橙
                        AiTier::No => 0x0050_5050,                   // 红 (BGR)
                    },
                );
            }
            if id == ID_AI_REQ {
                SetTextColor(hdc, 0x0090_8A85);
            }
            if id == ID_AI_NOTE {
                // 空间不够时标红
                let ok = st
                    .ai_space_ok
                    .load(std::sync::atomic::Ordering::Relaxed);
                SetTextColor(hdc, if ok { 0x0090_8A85 } else { 0x0050_5050 });
            }
            if id == ID_LOGO {
                return st.brush_header as isize;
            }
            st.brush_bg as isize
        }
        WM_CTLCOLOREDIT | WM_CTLCOLORBTN => {
            let st = &*ptr;
            let hdc = w as *mut c_void;
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, COL_TEXT);
            st.brush_edit as isize
        }
        WM_COMMAND => {
            let id = w & 0xFFFF;
            let st = &mut *ptr;
            match id {
                ID_APP_BROWSE => {
                    let cur = st
                        .app_dir
                        .lock()
                        .map(|g| g.clone())
                        .unwrap_or_default();
                    if let Some(p) = pick_folder(h, "选择程序安装位置", &cur) {
                        let edit = GetDlgItem(h, ID_APP_EDIT);
                        let w2 = wide(&p);
                        SetWindowTextW(edit, w2.as_ptr());
                    }
                }
                ID_MODEL_BROWSE => {
                    let cur = st
                        .model_dir
                        .lock()
                        .map(|g| g.clone())
                        .unwrap_or_default();
                    if let Some(p) = pick_folder(h, "选择模型存放位置（可放到空间更大的磁盘）", &cur) {
                        let edit = GetDlgItem(h, ID_MODEL_EDIT);
                        let w2 = wide(&p);
                        SetWindowTextW(edit, w2.as_ptr());
                    }
                }
                ID_AI_BROWSE => {
                    let cur = st
                        .ai_dir
                        .lock()
                        .map(|g| g.clone())
                        .unwrap_or_default();
                    if let Some(p) = pick_folder(
                        h,
                        "选择本地 AI 存放位置（模型 4.4GB + 运行时 1.5GB，建议放到大容量磁盘）",
                        &cur,
                    ) {
                        let w2 = wide(&p);
                        SetWindowTextW(GetDlgItem(h, ID_AI_EDIT), w2.as_ptr());
                        *st.ai_dir.lock().unwrap() = p;
                        update_ai_note(h, st, true);
                    }
                }
                ID_AI_EDIT => {
                    // 用户手动改路径: 实时刷新可用空间提示
                    if (w >> 16) as u32 == EN_CHANGE {
                        let p = get_text(GetDlgItem(h, ID_AI_EDIT));
                        *st.ai_dir.lock().unwrap() = p;
                        update_ai_note(h, st, false);
                    }
                }
                ID_CHK_AI => {
                    // 勾选状态决定路径行能不能编辑, 一眼就知道"要不要管它"
                    let on = is_checked(h, ID_CHK_AI);
                    let en = if on { SW_ENABLE } else { SW_DISABLE };
                    EnableWindow(GetDlgItem(h, ID_AI_EDIT), en);
                    EnableWindow(GetDlgItem(h, ID_AI_BROWSE), en);
                    if on {
                        update_ai_note(h, st, true);
                    }
                }
                ID_INSTALL => {
                    if !st.installing {
                        start_install(h, st);
                    }
                }
                ID_CLOSE => {
                    if st.installing {
                        return 0;
                    }
                    DestroyWindow(h);
                }
                _ => {}
            }
            0
        }
        WM_TIMER => {
            let st = &mut *ptr;
            if w == TIMER_ID {
                let pct = st.progress.percent.load(Ordering::SeqCst);
                let pb = GetDlgItem(h, ID_PROGRESS);
                SendMessageW(pb, PBM_SETPOS, pct as usize, 0);

                if let Ok(g) = st.progress.status.lock() {
                    let ws = wide(&g);
                    let stt = GetDlgItem(h, ID_STATUS);
                    SetWindowTextW(stt, ws.as_ptr());
                }

                if st.progress.done.load(Ordering::SeqCst) {
                    KillTimer(h, TIMER_ID);
                    st.installing = false;
                    let failed = st.progress.failed.lock().unwrap().clone();
                    let opt = st.opt.lock().unwrap().clone();
                    if let Some(err) = failed {
                        MessageBoxW(
                            h,
                            wide(&format!("安装失败：\n\n{err}")).as_ptr(),
                            wide("安装失败").as_ptr(),
                            0x0000_0010,
                        );
                        EnableWindow(GetDlgItem(h, ID_INSTALL), SW_ENABLE);
                        let btn = GetDlgItem(h, ID_INSTALL);
                        SetWindowTextW(btn, wide("重新安装").as_ptr());
                    } else {
                        let msg = if let Some(o) = &opt {
                            format!(
                                "安装完成！\n\n\
                                 程序位置：\n{}\n\n\
                                 模型位置：\n{}\n\n\
                                 默认快捷键：\n\
                                 　Ctrl+Alt+S　开启 / 关闭 全屏实时翻译\n\
                                 　Ctrl+Alt+H　冻结画面并操控译文\n\
                                 　Ctrl+Alt+G　退出实时翻译并回到主界面\n\
                                 　Ctrl+Alt+Q　框选翻译\n\
                                 　Ctrl+Alt+W　全屏翻译（单次）\n\n\
                                 快捷键可在主界面的「快捷键设置」里点方框后直接按组合键修改。",
                                o.app_dir.display(),
                                o.model_dir.display()
                            )
                        } else {
                            "安装完成！".to_string()
                        };
                        MessageBoxW(
                            h,
                            wide(&msg).as_ptr(),
                            wide("安装完成").as_ptr(),
                            0x0000_0040,
                        );
                        if let Some(o) = &opt {
                            if o.run_after {
                                launch(o);
                            }
                        }
                        DestroyWindow(h);
                    }
                }
            }
            0
        }
        WM_CLOSE => {
            let st = &*ptr;
            if !st.installing {
                DestroyWindow(h);
            }
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(h, msg, w, l),
    }
}

#[link(name = "user32")]
extern "system" {
    fn GetDlgItem(h: Hwnd, id: usize) -> Hwnd;
}

unsafe fn start_install(h: Hwnd, st: &mut AppState) {
    let app_edit = GetDlgItem(h, ID_APP_EDIT);
    let model_edit = GetDlgItem(h, ID_MODEL_EDIT);
    let app_dir = get_text(app_edit).trim().to_string();
    let model_dir = get_text(model_edit).trim().to_string();
    let ai_edit = GetDlgItem(h, ID_AI_EDIT);
    let ai_dir = get_text(ai_edit).trim().to_string();
    // 诊断: 把读到的原始值落盘, 排查"改了路径却没生效"这类问题
    let _ = std::fs::write(
        std::env::temp_dir().join("sky_setup_ai_path.txt"),
        format!(
            "ai_edit_hwnd=0x{:X}\napp_dir={}\nmodel_dir={}\nai_dir_raw=[{}]\n",
            ai_edit as usize, app_dir, model_dir, ai_dir
        ),
    );
    if app_dir.is_empty() || model_dir.is_empty() {
        MessageBoxW(
            h,
            wide("请填写安装位置和模型存放位置。").as_ptr(),
            wide("提示").as_ptr(),
            0x0000_0040,
        );
        return;
    }
    let app_path = PathBuf::from(&app_dir);
    if app_path.join(APP_EXE).exists() {
        let r = MessageBoxW(
            h,
            wide("目标目录里已有安装。\n\n继续将覆盖现有文件，是否继续？").as_ptr(),
            wide("确认").as_ptr(),
            0x0000_0004 | 0x0000_0020, // MB_YESNO | MB_ICONQUESTION
        );
        if r != 6 {
            return;
        }
    }

    // 硬件不够时不允许勾选, 这里再兜一次底
    let want_ai = is_checked(h, ID_CHK_AI) && st.verdict.selectable;
    // 要装 AI 却没地方放, 直接拦下来, 别让用户等半小时才失败
    if want_ai {
        let free = if ai_dir.is_empty() {
            crate::hw::free_disk_gb_deep(&model_dir)
        } else {
            crate::hw::free_disk_gb_deep(&ai_dir)
        };
        if free > 0.0 && free < 12.0 {
            MessageBoxW(
                h,
                wide(&format!(
                    "本地 AI 存放位置所在磁盘只剩 {free:.1} GB。\n\n                     本地 AI 需要约 12 GB（模型 4.4GB + Ollama 运行时 1.5GB + 余量）。\n                     请换一个空间更大的磁盘，或取消勾选「一起安装本地 AI 翻译」。"
                ))
                .as_ptr(),
                wide("磁盘空间不足").as_ptr(),
                0x0000_0030, // MB_ICONWARNING
            );
            return;
        }
    }
    let opt = Options {
        app_dir: app_path,
        model_dir: PathBuf::from(&model_dir),
        desktop_link: is_checked(h, ID_CHK_DESKTOP),
        start_link: is_checked(h, ID_CHK_START),
        run_after: is_checked(h, ID_CHK_RUN),
        install_ai: want_ai,
        ai_dir: if ai_dir.is_empty() {
            PathBuf::from(&model_dir).join("ai")
        } else {
            PathBuf::from(&ai_dir)
        },
        vram_mb: st.vram_mb,
    };
    *st.app_dir.lock().unwrap() = app_dir;
    *st.model_dir.lock().unwrap() = model_dir;
    *st.opt.lock().unwrap() = Some(Options {
        app_dir: opt.app_dir.clone(),
        model_dir: opt.model_dir.clone(),
        desktop_link: opt.desktop_link,
        start_link: opt.start_link,
        run_after: opt.run_after,
        install_ai: opt.install_ai,
        ai_dir: opt.ai_dir.clone(),
        vram_mb: opt.vram_mb,
    });

    st.installing = true;
    st.progress.percent.store(0, Ordering::SeqCst);
    st.progress.done.store(false, Ordering::SeqCst);
    *st.progress.failed.lock().unwrap() = None;
    *st.progress.status.lock().unwrap() = "准备中…".to_string();

    // 控件状态
    EnableWindow(GetDlgItem(h, ID_APP_EDIT), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_APP_BROWSE), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_MODEL_EDIT), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_MODEL_BROWSE), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_CHK_DESKTOP), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_CHK_START), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_CHK_RUN), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_CHK_AI), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_AI_EDIT), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_AI_BROWSE), SW_DISABLE);
    EnableWindow(GetDlgItem(h, ID_INSTALL), SW_DISABLE);
    let btn = GetDlgItem(h, ID_INSTALL);
    SetWindowTextW(btn, wide("安装中…").as_ptr());

    SetTimer(h, TIMER_ID, 150, std::ptr::null_mut());

    // 工作线程
    let entries = st.entries.clone();
    let exe = st.self_path.clone();
    let percent = st.progress.percent.clone();
    let status = st.progress.status.clone();
    let done = st.progress.done.clone();
    let failed = st.progress.failed.clone();
    std::thread::spawn(move || {
        let prog = Progress {
            percent,
            status,
            done,
            failed,
        };
        install(&exe, &entries, &opt, &prog);
    });
}

/// 刷新「本地 AI 存放位置」下面的容量提示。
///
/// 用户在挑盘的时候最需要知道的就是"这个盘放不放得下", 所以边改边算。
unsafe fn update_ai_note(h: Hwnd, st: &AppState, from_pick: bool) {
    let dir = st.ai_dir.lock().map(|g| g.clone()).unwrap_or_default();
    if dir.trim().is_empty() {
        return;
    }
    // 6GB 是运行时 + 模型 + 解压余量的总和, 留一点富余
    const NEED_GB: f64 = 12.0;
    let free = crate::hw::free_disk_gb_deep(dir.trim());

    let (text, ok) = if free <= 0.0 {
        ("无法读取该路径的磁盘信息，请确认盘符存在".to_string(), false)
    } else if free < NEED_GB {
        (
            format!(
                "✗ 该磁盘只剩 {free:.1} GB，本地 AI 需要约 {NEED_GB:.0} GB，请换一个磁盘",
            ),
            false,
        )
    } else {
        (
            format!(
                "✓ 该磁盘可用 {free:.1} GB，足够（模型 4.4GB + 运行时 1.5GB）",
            ),
            true,
        )
    };

    st.ai_space_ok
        .store(ok, std::sync::atomic::Ordering::Relaxed);
    let w = wide(&text);
    SetWindowTextW(GetDlgItem(h, ID_AI_NOTE), w.as_ptr());
    let _ = from_pick;
}

unsafe fn is_checked(h: Hwnd, id: usize) -> bool {
    unsafe {
        // BM_GETCHECK = 0x00F0
        SendMessageW(GetDlgItem(h, id), 0x00F0, 0, 0) == 1
    }
}

// ============================================================
//  创建窗口
// ============================================================

pub fn error_box(text: &str) {
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(text).as_ptr(),
            wide("安装程序").as_ptr(),
            0x0000_0010,
        );
    }
}

pub fn run(entries: Arc<Vec<Entry>>, self_path: PathBuf) {
    unsafe {
        SetProcessDPIAware();
        let icc = InitCommonControls {
            size: std::mem::size_of::<InitCommonControls>() as u32,
            classes: ICC_PROGRESS_CLASS,
        };
        InitCommonControlsEx(&icc);

        let inst = GetModuleHandleW(std::ptr::null());
        let cls_name = wide("SkySetupWnd");

        // 标题栏用默认尺寸
        let icon = LoadImageW(inst, 1 as *const u16, IMAGE_ICON, 0, 0, LR_DEFAULTCOLOR);

        let wc = WndClassExW {
            cb_size: std::mem::size_of::<WndClassExW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW,
            lpfn_wnd_proc: Some(wnd_proc),
            cb_cls_extra: 0,
            cb_wnd_extra: 0,
            h_instance: inst,
            h_icon: icon,
            h_cursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW as *const u16),
            hbr_background: CreateSolidBrush(COL_BG),
            lpsz_menu_name: std::ptr::null(),
            lpsz_class_name: cls_name.as_ptr(),
            h_icon_sm: icon,
        };
        RegisterClassExW(&wc);

        // 按屏幕 DPI 定尺寸
        let dpi = {
            let hdc = GetDC(std::ptr::null_mut());
            let d = {
                #[link(name = "gdi32")]
                extern "system" {
                    fn GetDeviceCaps(hdc: *mut c_void, index: i32) -> i32;
                }
                const LOGPIXELSX: i32 = 88;
                GetDeviceCaps(hdc, LOGPIXELSX)
            };
            ReleaseDC(std::ptr::null_mut(), hdc);
            if d <= 0 {
                96
            } else {
                d
            }
        };
        let scale = dpi as f32 / 96.0;
        let cw = (DESIGN_W as f32 * scale).round() as i32;
        let ch = (DESIGN_H as f32 * scale).round() as i32;

        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        let mut rc = Rect {
            left: 0,
            top: 0,
            right: cw,
            bottom: ch,
        };
        AdjustWindowRectEx(&mut rc, style, 0, 0);
        let sw = rc.right - rc.left;
        let sh = rc.bottom - rc.top;
        let sx = (GetSystemMetrics(0) - sw) / 2;
        let sy = (GetSystemMetrics(1) - sh) / 2;

        let hwnd = CreateWindowExW(
            0,
            cls_name.as_ptr(),
            wide(APP_NAME).as_ptr(),
            style,
            sx,
            sy,
            sw,
            sh,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            inst,
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            error_box(&format!(
                "创建窗口失败 (错误码 {})",
                GetLastError()
            ));
            return;
        }

        // ---- 状态 ----
        let s = |v: i32| (v as f32 * scale).round() as i32;
        let face = wide("Microsoft YaHei UI");
        let font = CreateFontW(
            -s(14), 0, 0, 0, 400, 0, 0, 0, 134, 0, 0, 5, 0, face.as_ptr(),
        );
        let font_bold = CreateFontW(
            -s(15), 0, 0, 0, 600, 0, 0, 0, 134, 0, 0, 5, 0, face.as_ptr(),
        );
        let font_title = CreateFontW(
            -s(19), 0, 0, 0, 600, 0, 0, 0, 134, 0, 0, 5, 0, face.as_ptr(),
        );
        let font_small = CreateFontW(
            -s(12), 0, 0, 0, 400, 0, 0, 0, 134, 0, 0, 5, 0, face.as_ptr(),
        );

        let default_app = PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_default())
            .join("Programs")
            .join("UnlimitedSkyOCR");
        let default_model = default_app.join("models");
        // 本地 AI 单独占一份 (模型 4.4GB + 运行时 1.5GB), 默认跟模型目录同级
        let default_ai = default_model.join("ai");

        // 先查硬件 —— 本地 AI 那一栏要据此显示能不能装
        let hw = crate::hw::detect();
        let disk = crate::hw::free_disk_gb_deep(&default_model.display().to_string());
        let verdict = crate::hw::judge(&hw, disk);
        let vram_mb = hw.vram_mb;
        // verdict 之后要 move 进 AppState, 这里先把界面要用的部分取出来
        let ai_selectable = verdict.selectable;
        let ai_info_text = format!("{}\r\n{}", verdict.title, verdict.detail);
        // 诊断: 判定值落到临时文件, 出问题时能直接看
        let _ = std::fs::write(
            std::env::temp_dir().join("sky_setup_hw.txt"),
            format!(
                "has_nvidia={}\ngpu={}\nvram_mb={}\ncompute={}\nram_gb={:.1}\ndisk_gb={:.1}\ntier={:?}\nselectable={}\n",
                hw.has_nvidia, hw.gpu_name, hw.vram_mb, hw.compute, hw.ram_gb, disk,
                verdict.tier, ai_selectable
            ),
        );

        let state = Box::new(AppState {
            entries,
            self_path,
            hwnd,
            scale,
            font,
            font_bold,
            font_title,
            font_small,
            brush_bg: CreateSolidBrush(COL_BG),
            brush_edit: CreateSolidBrush(0x00FF_FFFF),
            brush_header: CreateSolidBrush(COL_HEADER),
            icon,
            installing: false,
            progress: Progress {
                percent: Arc::new(AtomicU32::new(0)),
                status: Arc::new(Mutex::new(String::new())),
                done: Arc::new(AtomicBool::new(false)),
                failed: Arc::new(Mutex::new(None)),
            },
            opt: Mutex::new(None),
            app_dir: Mutex::new(default_app.display().to_string()),
            model_dir: Mutex::new(default_model.display().to_string()),
            ai_dir: Mutex::new(default_ai.display().to_string()),
            ai_space_ok: std::sync::atomic::AtomicBool::new(true),
            verdict,
            vram_mb,
        });
        let st_ptr = Box::into_raw(state);
        SetWindowLongPtrW(hwnd, -21, st_ptr as isize);

        // ---- 控件 ----
        let mk = |class: &str,
                  text: &str,
                  style: u32,
                  x: i32,
                  y: i32,
                  w: i32,
                  h: i32,
                  id: usize,
                  font: Hfont|
         -> Hwnd {
            let c = wide(class);
            let t = wide(text);
            let ctrl = CreateWindowExW(
                0,
                c.as_ptr(),
                t.as_ptr(),
                WS_CHILD | WS_VISIBLE | style,
                s(x),
                s(y),
                s(w),
                s(h),
                hwnd,
                id as Hmenu,
                inst,
                std::ptr::null_mut(),
            );
            SendMessageW(ctrl, WM_SETFONT, font as usize, 1);
            ctrl
        };

        // 头部 logo —— 用 STATIC + STM_SETICON 绘制。
        // 直接在 WM_PAINT 里 DrawIconEx 对这种带 alpha 通道的 ico 不可靠, 会画不出来。
        let logo = mk("STATIC", "", SS_ICON | SS_CENTERIMAGE, 28, 22, 56, 56, ID_LOGO, font);
        // 按控件实际像素尺寸加载, 否则 Windows 会给默认的 32x32, 在头部显得很小
        let logo_icon = LoadImageW(inst, 1 as *const u16, IMAGE_ICON, s(56), s(56), LR_DEFAULTCOLOR);
        let logo_icon = if logo_icon.is_null() { icon } else { logo_icon };
        if !logo_icon.is_null() {
            SendMessageW(logo, STM_SETICON, logo_icon as usize, 0);
        }

        // 段落标题
        mk("STATIC", "程序安装位置", SS_LEFT, 30, 126, 300, 22, 900, font_bold);
        mk(
            "EDIT",
            &default_app.display().to_string(),
            ES_LEFT | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP,
            30,
            152,
            500,
            30,
            ID_APP_EDIT,
            font,
        );
        mk(
            "BUTTON",
            "浏览…",
            BS_PUSHBUTTON | WS_TABSTOP,
            540,
            151,
            108,
            32,
            ID_APP_BROWSE,
            font,
        );
        mk(
            "STATIC",
            "程序本体约 190 MB",
            SS_LEFT,
            32,
            186,
            400,
            20,
            901,
            font_small,
        );

        mk("STATIC", "模型存放位置", SS_LEFT, 30, 218, 300, 22, 902, font_bold);
        mk(
            "EDIT",
            &default_model.display().to_string(),
            ES_LEFT | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP,
            30,
            244,
            500,
            30,
            ID_MODEL_EDIT,
            font,
        );
        mk(
            "BUTTON",
            "浏览…",
            BS_PUSHBUTTON | WS_TABSTOP,
            540,
            243,
            108,
            32,
            ID_MODEL_BROWSE,
            font,
        );
        mk(
            "STATIC",
            "OCR 与离线翻译模型约 228 MB，空间紧张时可以放到别的磁盘",
            SS_LEFT,
            32,
            278,
            560,
            20,
            903,
            font_small,
        );

        mk(
            "BUTTON",
            "创建桌面快捷方式",
            BS_AUTOCHECKBOX | WS_TABSTOP,
            30,
            308,
            200,
            24,
            ID_CHK_DESKTOP,
            font,
        );
        mk(
            "BUTTON",
            "创建开始菜单快捷方式",
            BS_AUTOCHECKBOX | WS_TABSTOP,
            250,
            308,
            220,
            24,
            ID_CHK_START,
            font,
        );
        mk(
            "BUTTON",
            "安装完成后立即运行",
            BS_AUTOCHECKBOX | WS_TABSTOP,
            30,
            336,
            220,
            24,
            ID_CHK_RUN,
            font,
        );
        // 默认全部勾上
        for id in [ID_CHK_DESKTOP, ID_CHK_START, ID_CHK_RUN] {
            SendMessageW(GetDlgItem(hwnd, id), 0x00F1, 1, 0); // BM_SETCHECK
        }

        // ================= 本地 AI 翻译 (可选) =================
        mk(
            "STATIC",
            "本地 AI 翻译（可选）",
            SS_LEFT,
            30,
            372,
            300,
            22,
            904,
            font_bold,
        );

        // 硬件检测结论 —— 颜色由 WM_CTLCOLORSTATIC 按档位决定
        mk(
            "STATIC",
            &ai_info_text,
            SS_LEFT,
            30,
            394,
            618,
            48,
            ID_AI_INFO,
            font_small,
        );

        mk(
            "STATIC",
            crate::hw::REQ_TEXT,
            SS_LEFT,
            30,
            444,
            618,
            32,
            ID_AI_REQ,
            font_small,
        );

        let ai_label = if ai_selectable {
            format!(
                "一起安装本地 AI 翻译（腾讯混元 Hunyuan-MT-7B，需额外下载约 6 GB）"
            )
        } else {
            "本地 AI 翻译（当前硬件不满足，已禁用）".to_string()
        };
        mk(
            "BUTTON",
            &ai_label,
            BS_AUTOCHECKBOX | WS_TABSTOP,
            30,
            478,
            618,
            24,
            ID_CHK_AI,
            font,
        );

        // 本地 AI 的存放位置 —— 单独一行, 可自由改到别的盘
        mk(
            "STATIC",
            "本地 AI 存放位置（模型 4.4GB + 运行时 1.5GB）",
            SS_LEFT,
            30,
            506,
            500,
            20,
            905,
            font_small,
        );
        mk(
            "EDIT",
            &default_ai.display().to_string(),
            ES_LEFT | ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP,
            30,
            528,
            500,
            30,
            ID_AI_EDIT,
            font,
        );
        mk(
            "BUTTON",
            "浏览…",
            BS_PUSHBUTTON | WS_TABSTOP,
            540,
            527,
            108,
            32,
            ID_AI_BROWSE,
            font,
        );
        mk(
            "STATIC",
            "",
            SS_LEFT,
            32,
            562,
            600,
            18,
            ID_AI_NOTE,
            font_small,
        );

        mk(
            "STATIC",
            "准备就绪，点击「开始安装」。",
            SS_LEFT,
            30,
            586,
            600,
            22,
            ID_STATUS,
            font_small,
        );

        let pb = mk(
            PROGRESS_CLASS,
            "",
            PBS_SMOOTH,
            30,
            612,
            618,
            14,
            ID_PROGRESS,
            font,
        );
        SendMessageW(pb, PBM_SETRANGE32, 0, 100);

        mk(
            "BUTTON",
            "开始安装",
            BS_DEFPUSHBUTTON | WS_TABSTOP,
            436,
            642,
            130,
            36,
            ID_INSTALL,
            font_bold,
        );
        mk(
            "BUTTON",
            "退出",
            BS_PUSHBUTTON | WS_TABSTOP,
            576,
            642,
            72,
            36,
            ID_CLOSE,
            font,
        );

        let _ = (&font_title, &st_ptr);

        // 本地 AI 复选框: 硬件达标就默认勾上, 不达标禁用。
        // 放在 ShowWindow 之前统一处理 —— 和上面三个复选框一样, 这里最稳。
        if ai_selectable {
            SendMessageW(GetDlgItem(hwnd, ID_CHK_AI), 0x00F1, 1, 0); // BM_SETCHECK
        } else {
            EnableWindow(GetDlgItem(hwnd, ID_CHK_AI), SW_DISABLE);
        }
        // 初始化 AI 路径那一段的可用状态和容量提示
        {
            let st = &*st_ptr;
            let en = if ai_selectable { SW_ENABLE } else { SW_DISABLE };
            EnableWindow(GetDlgItem(hwnd, ID_AI_EDIT), en);
            EnableWindow(GetDlgItem(hwnd, ID_AI_BROWSE), en);
            update_ai_note(hwnd, st, true);
        }
        // 回读一次, 确认真的勾上了
        let checked = SendMessageW(GetDlgItem(hwnd, ID_CHK_AI), 0x00F0, 0, 0); // BM_GETCHECK
        let _ = std::fs::write(
            std::env::temp_dir().join("sky_setup_hw2.txt"),
            format!("ai_selectable={ai_selectable} bm_getcheck={checked}\n"),
        );

        ShowWindow(hwnd, SW_SHOW);
        UpdateWindow(hwnd);
        SetForegroundWindow(hwnd);

        let mut msg = std::mem::zeroed::<Msg>();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // 收尾
        let _ = Box::from_raw(st_ptr);
    }
}
