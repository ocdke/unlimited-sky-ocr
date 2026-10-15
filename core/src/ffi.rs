//! C ABI 导出层 (供 Flutter / Dart FFI 调用)
//!
//! 设计原则:
//!   * 返回值统一为 UTF-8 JSON 的 C 字符串, 由 `dpg_string_free` 释放
//!   * 出错返回 NULL, 具体错误用 `dpg_last_error()` 取 (线程局部)
//!   * 截屏返回裸 BGRA 缓冲区, 避免任何编码/复制开销

use crate::engine::{EngineConfig, OcrEngine, OcrOptions};
use crate::error::Result;
use crate::image_utils::{decode_file, decode_memory, from_bgra};
use image::RgbImage;
use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_last_error(msg: &str) {
    let sanitized = msg.replace('\0', " ");
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(sanitized).unwrap_or_else(|_| CString::new("error").unwrap());
    });
}

fn cstr_to_str<'a>(p: *const c_char) -> Result<&'a str> {
    if p.is_null() {
        return Err(crate::error::DpgError::cfg("空指针参数"));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|e| crate::error::DpgError::cfg(format!("非法 UTF-8 字符串: {e}")))
}

/// 把 Result<serde 可序列化值> 转成 C 字符串
fn to_c_json<T: serde::Serialize>(r: Result<T>) -> *mut c_char {
    match r {
        Ok(v) => match serde_json::to_string(&v) {
            Ok(s) => match CString::new(s) {
                Ok(c) => c.into_raw(),
                Err(e) => {
                    set_last_error(&format!("序列化结果含非法字符: {e}"));
                    std::ptr::null_mut()
                }
            },
            Err(e) => {
                set_last_error(&format!("JSON 序列化失败: {e}"));
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// 截屏结果 (BGRA, 自上而下)
#[repr(C)]
pub struct DpgImage {
    pub data: *mut u8,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
}

// ============================================================
//  引擎生命周期
// ============================================================

/// 创建引擎。`config_json` 为 `EngineConfig` 的 JSON。
/// 成功返回非空指针; 失败返回 NULL 并用 `dpg_last_error` 取错误。
///
/// # Safety
/// `config_json` 必须是以 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn dpg_engine_new(config_json: *const c_char) -> *mut OcrEngine {
    let json = match cstr_to_str(config_json) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    let cfg = match EngineConfig::from_json(json) {
        Ok(c) => c,
        Err(e) => {
            set_last_error(&format!("解析引擎配置失败: {e}"));
            return std::ptr::null_mut();
        }
    };
    match OcrEngine::new(cfg) {
        Ok(e) => Box::into_raw(Box::new(e)),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `p` 必须是 `dpg_engine_new` 返回的指针, 且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn dpg_engine_free(p: *mut OcrEngine) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

/// 引擎信息 JSON: 是否有检测/分类模型、可用语言、各识别模型的类别数
///
/// # Safety
/// `p` 必须是有效引擎指针。
#[no_mangle]
pub unsafe extern "C" fn dpg_engine_info(p: *mut OcrEngine) -> *mut c_char {
    if p.is_null() {
        set_last_error("引擎指针为空");
        return std::ptr::null_mut();
    }
    let e = &*p;
    let info = serde_json::json!({
        "has_det": e.has_det(),
        "has_cls": e.has_cls(),
        "langs": e.available_langs(),
        "rec_info": e.rec_info().into_iter()
            .map(|(l, c, d, s)| serde_json::json!({
                "lang": l, "num_classes": c, "dict_len": d, "trailing_space": s
            }))
            .collect::<Vec<_>>(),
    });
    to_c_json(Ok(info))
}

// ============================================================
//  OCR
// ============================================================

fn run_ocr(engine: *mut OcrEngine, img: &RgbImage, opts_json: *const c_char) -> *mut c_char {
    if engine.is_null() {
        set_last_error("引擎指针为空");
        return std::ptr::null_mut();
    }
    let opts = if opts_json.is_null() {
        OcrOptions::default()
    } else {
        match cstr_to_str(opts_json).and_then(|s| {
            serde_json::from_str::<OcrOptions>(s)
                .map_err(|e| crate::error::DpgError::cfg(format!("解析识别选项失败: {e}")))
        }) {
            Ok(o) => o,
            Err(e) => {
                set_last_error(&e.to_string());
                return std::ptr::null_mut();
            }
        }
    };
    let engine = unsafe { &mut *engine };
    to_c_json(engine.run(img, &opts))
}

/// 对图片文件做 OCR
///
/// # Safety
/// 指针参数必须有效。
#[no_mangle]
pub unsafe extern "C" fn dpg_ocr_file(
    engine: *mut OcrEngine,
    path: *const c_char,
    opts_json: *const c_char,
) -> *mut c_char {
    let path = match cstr_to_str(path) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    match decode_file(std::path::Path::new(path)) {
        Ok(img) => run_ocr(engine, &img, opts_json),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// 对内存中的图片字节做 OCR
///
/// # Safety
/// `data` 必须指向长度至少 `len` 的有效内存。
#[no_mangle]
pub unsafe extern "C" fn dpg_ocr_bytes(
    engine: *mut OcrEngine,
    data: *const u8,
    len: usize,
    opts_json: *const c_char,
) -> *mut c_char {
    if data.is_null() || len == 0 {
        set_last_error("图像数据为空");
        return std::ptr::null_mut();
    }
    let bytes = std::slice::from_raw_parts(data, len);
    match decode_memory(bytes) {
        Ok(img) => run_ocr(engine, &img, opts_json),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// 对 BGRA 原始像素做 OCR (截屏后的零拷贝路径)
///
/// # Safety
/// `data` 必须指向长度至少 `stride*height` 的有效内存。
#[no_mangle]
pub unsafe extern "C" fn dpg_ocr_bgra(
    engine: *mut OcrEngine,
    data: *const u8,
    width: i32,
    height: i32,
    stride: i32,
    opts_json: *const c_char,
) -> *mut c_char {
    if data.is_null() || width <= 0 || height <= 0 {
        set_last_error("BGRA 参数非法");
        return std::ptr::null_mut();
    }
    let st = if stride <= 0 { width * 4 } else { stride } as usize;
    let need = st * height as usize;
    let buf = std::slice::from_raw_parts(data, need);
    match from_bgra(buf, width as u32, height as u32, st) {
        Ok(img) => run_ocr(engine, &img, opts_json),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// 对 RGBA 原始像素做 OCR (Android ImageReader 路径)
///
/// # Safety
/// `data` 必须指向长度至少 `stride*height` 的有效内存。
#[no_mangle]
pub unsafe extern "C" fn dpg_ocr_rgba(
    engine: *mut OcrEngine,
    data: *const u8,
    width: i32,
    height: i32,
    stride: i32,
    opts_json: *const c_char,
) -> *mut c_char {
    if data.is_null() || width <= 0 || height <= 0 {
        set_last_error("RGBA 参数非法");
        return std::ptr::null_mut();
    }
    let st = if stride <= 0 { width * 4 } else { stride } as usize;
    let need = st * height as usize;
    let buf = std::slice::from_raw_parts(data, need);
    match crate::image_utils::from_rgba(buf, width as u32, height as u32, st) {
        Ok(img) => run_ocr(engine, &img, opts_json),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

// ============================================================
//  截屏
// ============================================================

/// 截取屏幕区域 (仅 Windows)。返回 NULL 表示失败。
/// 成功时返回的结构体及其中 `data` 都需要用 `dpg_image_free` 释放。
///
/// # Safety
/// 返回指针需由调用方检查并释放。
#[no_mangle]
pub unsafe extern "C" fn dpg_capture_rect(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) -> *mut DpgImage {
    #[cfg(windows)]
    {
        match crate::capture_win::capture_rect(x, y, w, h) {
            Ok((mut buf, cw, ch, stride)) => {
                let img = DpgImage {
                    data: buf.as_mut_ptr(),
                    width: cw,
                    height: ch,
                    stride,
                };
                std::mem::forget(buf); // 交给调用方释放
                Box::into_raw(Box::new(img))
            }
            Err(e) => {
                set_last_error(&e.to_string());
                std::ptr::null_mut()
            }
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (x, y, w, h);
        set_last_error("当前平台不支持 dpg_capture_rect");
        std::ptr::null_mut()
    }
}

/// 截取整个虚拟桌面
///
/// # Safety
/// 返回指针需由调用方释放。
#[no_mangle]
pub unsafe extern "C" fn dpg_capture_all() -> *mut DpgImage {
    #[cfg(windows)]
    {
        let (x, y, w, h) = crate::capture_win::virtual_screen_rect();
        dpg_capture_rect(x, y, w, h)
    }
    #[cfg(not(windows))]
    {
        set_last_error("当前平台不支持 dpg_capture_all");
        std::ptr::null_mut()
    }
}

/// 释放截屏结果
///
/// # Safety
/// `p` 必须来自 `dpg_capture_rect` / `dpg_capture_all`, 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn dpg_image_free(p: *mut DpgImage) {
    if p.is_null() {
        return;
    }
    let boxed = Box::from_raw(p);
    if !boxed.data.is_null() {
        let len = (boxed.stride * boxed.height) as usize;
        drop(Vec::from_raw_parts(boxed.data, len, len));
    }
}

/// 桌面几何信息 JSON: 虚拟桌面 + 主屏
#[no_mangle]
pub extern "C" fn dpg_screen_info() -> *mut c_char {
    #[cfg(windows)]
    {
        let (vx, vy, vw, vh) = crate::capture_win::virtual_screen_rect();
        let (px, py, pw, ph) = crate::capture_win::primary_screen_rect();
        let info = serde_json::json!({
            "virtual": {"x": vx, "y": vy, "width": vw, "height": vh},
            "primary": {"x": px, "y": py, "width": pw, "height": ph},
        });
        to_c_json(Ok(info))
    }
    #[cfg(not(windows))]
    {
        set_last_error("当前平台不支持 dpg_screen_info");
        std::ptr::null_mut()
    }
}

/// 声明进程 DPI 感知 (必须在读屏前调用)
#[no_mangle]
pub extern "C" fn dpg_init_platform() {
    #[cfg(windows)]
    crate::capture_win::ensure_dpi_aware();
}

/// 探测全局热键组合是否可用 (1 = 可用, 0 = 已被别的程序占用)。
/// `mods` 位标志: 1=Alt 2=Ctrl 4=Shift 8=Win
#[no_mangle]
pub extern "C" fn dpg_probe_hotkey(mods: i32, vk: i32) -> i32 {
    #[cfg(windows)]
    {
        if crate::capture_win::probe_hotkey(mods as u32, vk as u32) {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (mods, vk);
        1
    }
}

/// 把主窗口从屏幕捕获中排除 (用户仍可见), 用于实时翻译模式避免截到自己的译文。
/// 返回 1 = 成功, 0 = 失败 (需要 Windows 10 2004+)。
#[no_mangle]
pub extern "C" fn dpg_set_capture_exclusion(exclude: i32) -> i32 {
    #[cfg(windows)]
    {
        if crate::capture_win::set_capture_exclusion(exclude != 0) {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        let _ = exclude;
        0
    }
}

/// 只做识别、不做检测: 对给定的矩形框逐个识别。
///
/// 实时翻译的提速关键: 画面只有几行变化时, 复用上一轮的框即可,
/// 不必把整屏重新检测一遍。
///
/// `rects_json` 是 `[[x,y,w,h], ...]` (相对本张图的坐标), 返回 OCR 结果的 JSON。
///
/// # Safety
/// 指针参数必须有效。
#[no_mangle]
pub unsafe extern "C" fn dpg_rec_rects_bgra(
    engine: *mut OcrEngine,
    pixels: *const u8,
    width: i32,
    height: i32,
    stride: i32,
    rects_json: *const c_char,
    lang: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        set_last_error("引擎指针为空");
        return std::ptr::null_mut();
    }
    let rects = match cstr_to_str(rects_json) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    let rects: Vec<[f32; 4]> = match serde_json::from_str(rects) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("解析框失败: {e}"));
            return std::ptr::null_mut();
        }
    };
    let lang = cstr_to_str(lang).unwrap_or("auto");

    let st = if stride <= 0 { width as usize * 4 } else { stride as usize };
    let need = st * height as usize;
    let buf = std::slice::from_raw_parts(pixels, need);
    let img = match from_bgra(buf, width as u32, height as u32, st) {
        Ok(i) => i,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };

    let boxes: Vec<crate::det::DetBox> = rects
        .iter()
        .map(|r| {
            let (x, y, w, h) = (r[0], r[1], r[2], r[3]);
            crate::det::DetBox {
                points: [
                    crate::geometry::Pt { x, y },
                    crate::geometry::Pt { x: x + w, y },
                    crate::geometry::Pt { x: x + w, y: y + h },
                    crate::geometry::Pt { x, y: y + h },
                ],
                score: 1.0,
            }
        })
        .collect();

    let e = &mut *engine;
    match e.recognize_boxes(&img, &boxes, lang) {
        Ok(lines) => to_c_json(Ok(serde_json::json!({
            "lines": lines.iter().map(|l| serde_json::json!({
                "text": l.text,
                "score": l.score,
                "detScore": l.det_score,
                "points": l.points.iter().map(|p| [p[0], p[1]]).collect::<Vec<_>>(),
                "lang": l.lang,
                "rotated": l.rotated,
            })).collect::<Vec<_>>(),
        }))),
        Err(err) => {
            set_last_error(&err.to_string());
            std::ptr::null_mut()
        }
    }
}

// ============================================================
//  平台集成: 单实例 / 系统托盘 / 开机自启
// ============================================================

/// 尝试成为唯一实例。1 = 你是第一个; 0 = 已经有一个在跑。
///
/// 启动要读一百多兆模型, 用户看没反应就会连点好几次 —— 几个实例同时满载
/// 会把整机拖住。这个互斥体就是用来挡住重复启动的。
#[no_mangle]
pub extern "C" fn dpg_single_instance() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::acquire_single_instance() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        1
    }
}

/// 弹出"打开文件"对话框, 返回选中的路径 (UTF-8)。取消返回 null。
///
/// `kind`: "gguf" = 只列 *.gguf, "exe" = 只列 *.exe, 其它 = 所有文件
///
/// # Safety
/// 三个参数都必须是有效的 NUL 结尾 UTF-8 C 字符串 (可为空串)。
#[no_mangle]
pub unsafe extern "C" fn dpg_pick_file(
    kind: *const c_char,
    title: *const c_char,
    initial: *const c_char,
) -> *mut c_char {
    #[cfg(windows)]
    {
        let k = cstr_to_str(kind).unwrap_or("");
        let t = cstr_to_str(title).unwrap_or("选择文件");
        let i = cstr_to_str(initial).unwrap_or("");
        let specs: Vec<(&str, &str)> = match k {
            "gguf" => vec![("GGUF 模型文件 (*.gguf)", "*.gguf"), ("所有文件 (*.*)", "*.*")],
            "exe" => vec![("可执行文件 (*.exe)", "*.exe"), ("所有文件 (*.*)", "*.*")],
            _ => vec![("所有文件 (*.*)", "*.*")],
        };
        match crate::filedlg::pick_file(t, &specs, i) {
            Some(p) => {
                let c = std::ffi::CString::new(p).unwrap_or_default();
                c.into_raw()
            }
            None => std::ptr::null_mut(),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (kind, title, initial);
        std::ptr::null_mut()
    }
}

/// 弹出"选择文件夹"对话框, 返回选中的路径 (UTF-8)。取消返回 null。
///
/// # Safety
/// 两个参数都必须是有效的 NUL 结尾 UTF-8 C 字符串 (可为空串)。
#[no_mangle]
pub unsafe extern "C" fn dpg_pick_folder(
    title: *const c_char,
    initial: *const c_char,
) -> *mut c_char {
    #[cfg(windows)]
    {
        let t = cstr_to_str(title).unwrap_or("选择文件夹");
        let i = cstr_to_str(initial).unwrap_or("");
        match crate::filedlg::pick_folder(t, i) {
            Some(p) => {
                let c = std::ffi::CString::new(p).unwrap_or_default();
                c.into_raw()
            }
            None => std::ptr::null_mut(),
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (title, initial);
        std::ptr::null_mut()
    }
}

/// 检查文件或目录是否存在。1 = 存在。
///
/// # Safety
/// `path` 必须是有效的 NUL 结尾 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn dpg_path_exists(path: *const c_char) -> i32 {
    match cstr_to_str(path) {
        Ok(p) => {
            if p.is_empty() {
                0
            } else if std::path::Path::new(p).exists() {
                1
            } else {
                0
            }
        }
        Err(_) => 0,
    }
}

/// 把主窗口唤到前台 (完全在原生侧完成, 不走 Flutter 通道)。
/// 1 = 成功。
///
/// 之前这一步用 windowManager 的 show/focus/置顶, 通道调用会卡住,
/// await 到 900ms 超时 —— 快捷键"按下去三秒才有反应"就是这个原因。
#[no_mangle]
pub extern "C" fn dpg_focus_window() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::focus_main_window() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 请求已在运行的实例把窗口显示出来 (新实例启动时用)。
/// 由**已在运行的那个**自己去 show/focus, 比跨进程 ShowWindow 可靠得多。
#[no_mangle]
pub extern "C" fn dpg_request_show() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::request_show() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 创建"显示窗口"事件 (启动时调一次)
#[no_mangle]
pub extern "C" fn dpg_create_show_event() {
    #[cfg(windows)]
    crate::platform::create_show_event();
}

/// 轮询是否有"显示窗口"请求 (取走即清)。1 = 有。
#[no_mangle]
pub extern "C" fn dpg_poll_show_request() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::poll_show_request() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 把已经在运行的实例窗口拉到前台。1 = 成功。
#[no_mangle]
pub extern "C" fn dpg_activate_existing() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::activate_existing() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 创建系统托盘图标。`exe_path` 用来抽取程序自身图标。
///
/// # Safety
/// 两个参数都必须是以 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn dpg_tray_init(
    tooltip: *const c_char,
    exe_path: *const c_char,
) -> i32 {
    let tip = cstr_to_str(tooltip).unwrap_or("Unlimited sky OCR");
    let exe = cstr_to_str(exe_path).unwrap_or("");
    #[cfg(windows)]
    {
        if crate::platform::tray_init(tip, exe) {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (tip, exe);
        0
    }
}

/// 注册/注销一个额外的全局热键 (用于"立刻重扫屏幕")。
/// `mods` 位标志: 1=Alt 2=Ctrl 4=Shift 8=Win; `vk` 为虚拟键码。
/// 1 = 成功。
#[no_mangle]
pub extern "C" fn dpg_register_extra_hotkey(mods: i32, vk: i32) -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::register_extra_hotkey(mods as u32, vk as u32) {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (mods, vk);
        0
    }
}

/// 注销额外热键
#[no_mangle]
pub extern "C" fn dpg_unregister_extra_hotkey() {
    #[cfg(windows)]
    crate::platform::unregister_extra_hotkey();
}

/// 取出托盘菜单里待处理的命令: 0=无 1=显示主界面 2=退出 3=强制重扫 (取走即清空)
#[no_mangle]
pub extern "C" fn dpg_tray_poll() -> i32 {
    #[cfg(windows)]
    {
        crate::platform::tray_poll()
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 移除托盘图标
#[no_mangle]
pub extern "C" fn dpg_tray_dispose() {
    #[cfg(windows)]
    crate::platform::tray_dispose();
}

/// 设置/取消开机自启。1 = 成功。
///
/// # Safety
/// `exe_path` 必须是以 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn dpg_set_autostart(enable: i32, exe_path: *const c_char) -> i32 {
    let exe = cstr_to_str(exe_path).unwrap_or("");
    #[cfg(windows)]
    {
        if crate::platform::set_autostart(enable != 0, exe) {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (enable, exe);
        0
    }
}

/// 查询是否已设置开机自启。1 = 已开启。
#[no_mangle]
pub extern "C" fn dpg_get_autostart() -> i32 {
    #[cfg(windows)]
    {
        if crate::platform::get_autostart() {
            1
        } else {
            0
        }
    }
    #[cfg(not(windows))]
    {
        0
    }
}

/// 预加载若干识别模型 (逗号分隔的语种码), 返回实际加载数量。
/// 启动后可以在后台慢慢补, 不阻塞首屏。
///
/// # Safety
/// 指针参数必须有效。
#[no_mangle]
pub unsafe extern "C" fn dpg_preload_langs(
    engine: *mut OcrEngine,
    langs: *const c_char,
) -> i32 {
    if engine.is_null() {
        return 0;
    }
    let list = match cstr_to_str(langs) {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let v: Vec<String> = list
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    (*engine).preload(&v) as i32
}

/// 已加载的识别模型 (JSON 数组)
///
/// # Safety
/// `engine` 必须是有效指针。
#[no_mangle]
pub unsafe extern "C" fn dpg_loaded_langs(engine: *mut OcrEngine) -> *mut c_char {
    if engine.is_null() {
        set_last_error("引擎指针为空");
        return std::ptr::null_mut();
    }
    to_c_json(Ok(serde_json::json!({ "loaded": (*engine).loaded_langs() })))
}

// ============================================================
//  离线翻译
// ============================================================

/// 创建离线翻译引擎。`config_json` 为 `MtConfig` 的 JSON:
/// `{"model_root":"...","onnxruntime_dll":"...","threads":0}`
///
/// 与 OCR 引擎共用同一个 ONNX Runtime 环境, 可以同时存在。
///
/// # Safety
/// `config_json` 必须是以 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn dpg_mt_new(config_json: *const c_char) -> *mut crate::mt_engine::MtEngine {
    let json = match cstr_to_str(config_json) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    let cfg = match serde_json::from_str::<crate::mt_engine::MtConfig>(json) {
        Ok(c) => c,
        Err(e) => {
            set_last_error(&format!("解析翻译引擎配置失败: {e}"));
            return std::ptr::null_mut();
        }
    };
    match crate::mt_engine::MtEngine::new(cfg) {
        Ok(e) => Box::into_raw(Box::new(e)),
        Err(e) => {
            set_last_error(&e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// 列出可用语言对 (JSON 字符串数组), 以及已加载的语言对
///
/// # Safety
/// `p` 必须是 `dpg_mt_new` 返回的有效指针。
#[no_mangle]
pub unsafe extern "C" fn dpg_mt_info(p: *mut crate::mt_engine::MtEngine) -> *mut c_char {
    if p.is_null() {
        set_last_error("翻译引擎指针为空");
        return std::ptr::null_mut();
    }
    let e = &*p;
    to_c_json(Ok(serde_json::json!({
        "available": e.available_pairs(),
        "loaded": e.loaded_pairs(),
    })))
}

/// 批量翻译。`texts_json` 是字符串数组的 JSON, 返回与之等长的译文数组。
///
/// # Safety
/// 指针参数必须有效。
#[no_mangle]
pub unsafe extern "C" fn dpg_mt_translate_batch(
    p: *mut crate::mt_engine::MtEngine,
    pair: *const c_char,
    texts_json: *const c_char,
) -> *mut c_char {
    if p.is_null() {
        set_last_error("翻译引擎指针为空");
        return std::ptr::null_mut();
    }
    let pair = match cstr_to_str(pair) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    let tj = match cstr_to_str(texts_json) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&e.to_string());
            return std::ptr::null_mut();
        }
    };
    let texts: Vec<String> = match serde_json::from_str(tj) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("解析待翻译文本失败: {e}"));
            return std::ptr::null_mut();
        }
    };
    let engine = &mut *p;
    to_c_json(engine.translate_batch(pair, &texts))
}

/// 释放离线翻译引擎
///
/// # Safety
/// `p` 必须来自 `dpg_mt_new`, 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn dpg_mt_free(p: *mut crate::mt_engine::MtEngine) {
    if !p.is_null() {
        drop(Box::from_raw(p));
    }
}

// ============================================================
//  内存管理 / 错误
// ============================================================

/// 释放由本库返回的字符串
///
/// # Safety
/// `s` 必须来自本库的某个返回字符串, 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn dpg_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

/// 取最近一次错误信息 (调用方需用 `dpg_string_free` 释放)
#[no_mangle]
pub extern "C" fn dpg_last_error() -> *mut c_char {
    LAST_ERROR.with(|e| {
        let s = e.borrow().clone();
        s.into_raw()
    })
}

/// 库版本
#[no_mangle]
pub extern "C" fn dpg_version() -> *mut c_char {
    CString::new(env!("CARGO_PKG_VERSION"))
        .unwrap_or_else(|_| CString::new("0").unwrap())
        .into_raw()
}

/// 全局互斥: 保证同一引擎不会被多线程并发调用 (ORT Session 的 run 需要 &mut)
pub type EngineLock = Mutex<()>;
