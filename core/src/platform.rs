//! Windows 平台集成: 单实例、系统托盘、开机自启
//!
//! 全部用原生 API 实现, 不引入额外依赖。
//!
//! * **单实例**: 程序启动要读一百多兆模型, 用户看没反应就会连点好几次,
//!   几个实例同时满载会让整机卡住 —— 这里用命名互斥体挡住, 并把已有窗口拉到前面。
//! * **托盘**: 隐藏到一个通知区图标, 右键有「显示主界面 / 退出」。
//!   Dart 侧用一个轻量轮询取命令, 避免跨语言回调的麻烦。
//! * **开机自启**: 写 HKCU 的 Run 键, 不需要管理员权限。

#![cfg(windows)]

use std::ffi::c_void;
use std::sync::atomic::{AtomicI32, AtomicIsize, Ordering};

type Hwnd = *mut c_void;
type Hinstance = *mut c_void;
type Hicon = *mut c_void;
type Hmenu = *mut c_void;
type Hkey = *mut c_void;

const WM_APP: u32 = 0x8000;
const WM_TRAY: u32 = WM_APP + 1; // 托盘回调
const WM_COMMAND: u32 = 0x0111;
const WM_DESTROY: u32 = 0x0002;
const WM_CLOSE: u32 = 0x0010;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONUP: u32 = 0x0205;

const NIM_ADD: u32 = 0;
const NIM_MODIFY: u32 = 1;
const NIM_DELETE: u32 = 2;
const NIF_MESSAGE: u32 = 0x01;
const NIF_ICON: u32 = 0x02;
const NIF_TIP: u32 = 0x04;

const MF_STRING: u32 = 0x0000;
const MF_SEPARATOR: u32 = 0x0800;
const TPM_RIGHTBUTTON: u32 = 0x0002;
const TPM_RETURNCMD: u32 = 0x0100;

const IDM_SHOW: usize = 1;
const IDM_EXIT: usize = 2;

/// Dart 侧轮询到的待处理命令
static PENDING: AtomicI32 = AtomicI32::new(0);
static TRAY_HWND: AtomicIsize = AtomicIsize::new(0);

pub const CMD_NONE: i32 = 0;
pub const CMD_SHOW: i32 = 1;
pub const CMD_EXIT: i32 = 2;
/// 强制重扫屏幕 (由原生热键触发)
pub const CMD_RESCAN: i32 = 3;

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
    hbr_background: *mut c_void,
    lpsz_menu_name: *const u16,
    lpsz_class_name: *const u16,
    h_icon_sm: Hicon,
}

#[repr(C)]
struct NotifyIconDataW {
    cb_size: u32,
    hwnd: Hwnd,
    u_id: u32,
    u_flags: u32,
    u_callback_message: u32,
    h_icon: Hicon,
    sz_tip: [u16; 128],
    dw_state: u32,
    sz_state: [u16; 256],
    sz_info: [u16; 256],
    u_timeout_or_version: u32,
    sz_info_title: [u16; 64],
    dw_info_flags: u32,
    guid_item: [u8; 16],
    h_balloon_icon: Hicon,
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

#[link(name = "kernel32")]
extern "system" {
    fn CreateMutexW(sa: *mut c_void, initial_owner: i32, name: *const u16) -> *mut c_void;
    fn GetLastError() -> u32;
    fn SetLastError(err: u32);
    fn GetModuleHandleW(name: *const u16) -> Hinstance;
    fn GetCurrentProcessId() -> u32;
    fn CreateEventW(sa: *mut c_void, manual_reset: i32, initial: i32, name: *const u16)
        -> *mut c_void;
    fn OpenEventW(access: u32, inherit: i32, name: *const u16) -> *mut c_void;
    fn SetEvent(h: *mut c_void) -> i32;
    fn WaitForSingleObject(h: *mut c_void, ms: u32) -> u32;
    fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> *mut c_void;
    fn Process32FirstW(snap: *mut c_void, entry: *mut ProcessEntry32W) -> i32;
    fn Process32NextW(snap: *mut c_void, entry: *mut ProcessEntry32W) -> i32;
    fn CloseHandle(h: *mut c_void) -> i32;
    fn GetCurrentProcess() -> *mut c_void;
    fn QueryFullProcessImageNameW(
        h: *mut c_void,
        flags: u32,
        name: *mut u16,
        size: *mut u32,
    ) -> i32;
}

#[repr(C)]
struct ProcessEntry32W {
    dw_size: u32,
    cnt_usage: u32,
    th32_process_id: u32,
    th32_default_heap_id: usize,
    th32_module_id: u32,
    cnt_threads: u32,
    th32_parent_process_id: u32,
    pc_pri_class_base: i32,
    dw_flags: u32,
    sz_exe_file: [u16; 260],
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassExW(wc: *const WndClassExW) -> u16;
    fn CreateWindowExW(
        ex: u32,
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
    fn GetMessageW(msg: *mut Msg, h: Hwnd, min: u32, max: u32) -> i32;
    fn TranslateMessage(msg: *const Msg) -> i32;
    fn DispatchMessageW(msg: *const Msg) -> isize;
    fn PostMessageW(h: Hwnd, m: u32, w: usize, l: isize) -> i32;
    fn PostQuitMessage(code: i32);
    fn CreatePopupMenu() -> Hmenu;
    fn AppendMenuW(menu: Hmenu, flags: u32, id: usize, text: *const u16) -> i32;
    fn DestroyMenu(menu: Hmenu) -> i32;
    fn TrackPopupMenu(
        menu: Hmenu,
        flags: u32,
        x: i32,
        y: i32,
        reserved: i32,
        hwnd: Hwnd,
        rect: *const c_void,
    ) -> i32;
    fn GetCursorPos(p: *mut Point) -> i32;
    fn SetForegroundWindow(h: Hwnd) -> i32;
    fn IsWindowVisible(h: Hwnd) -> i32;
    fn ShowWindow(h: Hwnd, cmd: i32) -> i32;
    fn FindWindowW(class: *const u16, title: *const u16) -> Hwnd;
    fn SetWindowPos(h: Hwnd, after: Hwnd, x: i32, y: i32, cx: i32, cy: i32, flags: u32) -> i32;
    fn EnumWindows(
        cb: Option<unsafe extern "system" fn(Hwnd, isize) -> i32>,
        param: isize,
    ) -> i32;
    fn GetWindowThreadProcessId(h: Hwnd, pid: *mut u32) -> u32;
    fn GetWindow(h: Hwnd, cmd: u32) -> Hwnd;
}

const WM_HOTKEY: u32 = 0x0312;
const EXTRA_HOTKEY_ID: i32 = 0x5C01;

#[link(name = "user32")]
extern "system" {
    fn RegisterHotKey(hwnd: Hwnd, id: i32, mods: u32, vk: u32) -> i32;
    fn UnregisterHotKey(hwnd: Hwnd, id: i32) -> i32;
}

#[link(name = "shell32")]
extern "system" {
    fn Shell_NotifyIconW(message: u32, data: *mut NotifyIconDataW) -> i32;
    fn ExtractIconW(inst: Hinstance, exe: *const u16, index: u32) -> Hicon;
    fn ExtractIconExW(
        file: *const u16,
        index: i32,
        large: *mut Hicon,
        small: *mut Hicon,
        count: u32,
    ) -> u32;
}

#[link(name = "advapi32")]
extern "system" {
    fn RegCreateKeyExW(
        hkey: Hkey,
        sub: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        sam: u32,
        sa: *mut c_void,
        result: *mut Hkey,
        disp: *mut u32,
    ) -> i32;
    fn RegSetValueExW(
        hkey: Hkey,
        name: *const u16,
        reserved: u32,
        ty: u32,
        data: *const u8,
        len: u32,
    ) -> i32;
    fn RegDeleteValueW(hkey: Hkey, name: *const u16) -> i32;
    fn RegQueryValueExW(
        hkey: Hkey,
        name: *const u16,
        reserved: *mut u32,
        ty: *mut u32,
        data: *mut u8,
        len: *mut u32,
    ) -> i32;
    fn RegOpenKeyExW(
        hkey: Hkey,
        sub: *const u16,
        options: u32,
        sam: u32,
        result: *mut Hkey,
    ) -> i32;
    fn RegCloseKey(hkey: Hkey) -> i32;
}

const HKEY_CURRENT_USER: Hkey = 0x8000_0001u32 as usize as Hkey;
const KEY_SET_VALUE: u32 = 0x0002;
const KEY_QUERY_VALUE: u32 = 0x0001;
const REG_SZ: u32 = 1;
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_VALUE: &str = "UnlimitedSkyOCR";

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

// ============================================================
//  单实例
// ============================================================

/// 尝试成为唯一实例。返回 true = 你是第一个; false = 已有实例在跑。
///
/// 注意 `CreateMutexW`: 只有"名字已存在"时才会把 last-error 设成
/// ERROR_ALREADY_EXISTS, **成功新建时不会清零** —— 线程上残留的错误码会让
/// 新进程误判成"已有实例", 于是刚打开就自己退出。所以必须先 SetLastError(0)。
pub fn acquire_single_instance() -> bool {
    unsafe {
        let name = wide("Local\\UnlimitedSkyOCR_SingleInstance");
        SetLastError(0);
        let h = CreateMutexW(std::ptr::null_mut(), 1, name.as_ptr());
        if h.is_null() {
            return true; // 拿不到互斥体就别挡着用户
        }
        const ERROR_ALREADY_EXISTS: u32 = 183;
        if GetLastError() != ERROR_ALREADY_EXISTS {
            return true;
        }
        // 双保险: 互斥体说"已存在", 但真的还有同名进程在跑吗?
        // 没有的话就照样启动, 免得因为误判把用户挡在门外。
        count_same_exe_processes() == 0
    }
}

/// 统计除自己以外、同名的进程数量
fn count_same_exe_processes() -> usize {
    unsafe {
        let me = GetCurrentProcessId();
        let mut my_exe = [0u16; 260];
        let mut size = 260u32;
        if QueryFullProcessImageNameW(GetCurrentProcess(), 0, my_exe.as_mut_ptr(), &mut size) == 0
        {
            return 0;
        }
        let my_name: String = String::from_utf16_lossy(&my_exe[..size as usize])
            .rsplit(['\\', '/'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();

        const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap as isize == -1 {
            return 0;
        }
        let mut entry: ProcessEntry32W = std::mem::zeroed();
        entry.dw_size = std::mem::size_of::<ProcessEntry32W>() as u32;
        let mut n = 0usize;
        if Process32FirstW(snap, &mut entry) != 0 {
            loop {
                if entry.th32_process_id != me {
                    let end = entry
                        .sz_exe_file
                        .iter()
                        .position(|&c| c == 0)
                        .unwrap_or(entry.sz_exe_file.len());
                    let name = String::from_utf16_lossy(&entry.sz_exe_file[..end]).to_ascii_lowercase();
                    if name == my_name {
                        n += 1;
                    }
                }
                if Process32NextW(snap, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
        n
    }
}

// ------------------------------------------------------------
//  「请把窗口显示出来」事件
//
//  靠新进程去 ShowWindow 别的进程的窗口并不可靠 (前台窗口权限限制)。
//  改成: 新进程只负责举旗, 由**已在运行的那个**自己把窗口显示出来 ——
//  它调 windowManager.show()/focus(), 一定管用。
// ------------------------------------------------------------

fn show_event_name() -> Vec<u16> {
    wide("Local\\UnlimitedSkyOCR_ShowEvent")
}

/// 让已在运行的实例把窗口显示出来
pub fn request_show() -> bool {
    unsafe {
        // 发信号只需要 EVENT_MODIFY_STATE
        const EVENT_MODIFY_STATE: u32 = 0x0002;
        let h = OpenEventW(EVENT_MODIFY_STATE, 0, show_event_name().as_ptr());
        if h.is_null() {
            return false;
        }
        let ok = SetEvent(h) != 0;
        CloseHandle(h);
        ok
    }
}

/// 创建事件 (启动时调用一次)
pub fn create_show_event() {
    unsafe {
        CreateEventW(std::ptr::null_mut(), 0, 0, show_event_name().as_ptr());
    }
}

/// 轮询是否有"显示窗口"的请求 (取走即清)
pub fn poll_show_request() -> bool {
    unsafe {
        // 关键: WaitForSingleObject 需要 SYNCHRONIZE 权限。
        // 只申请 EVENT_MODIFY_STATE 的话等待会直接失败, 请求就石沉大海。
        const SYNCHRONIZE: u32 = 0x0010_0000;
        const EVENT_MODIFY_STATE: u32 = 0x0002;
        let h = OpenEventW(
            SYNCHRONIZE | EVENT_MODIFY_STATE,
            0,
            show_event_name().as_ptr(),
        );
        if h.is_null() {
            // 事件还没建出来 (比如旧版本在跑), 顺手建一个再试
            create_show_event();
            let h2 = OpenEventW(
                SYNCHRONIZE | EVENT_MODIFY_STATE,
                0,
                show_event_name().as_ptr(),
            );
            if h2.is_null() {
                return false;
            }
            let hit = WaitForSingleObject(h2, 0) == 0;
            CloseHandle(h2);
            return hit;
        }
        let hit = WaitForSingleObject(h, 0) == 0; // WAIT_OBJECT_0
        CloseHandle(h);
        hit
    }
}

unsafe extern "system" fn find_main_proc(h: Hwnd, param: isize) -> i32 {
    let ctx = &mut *(param as *mut (u32, Hwnd));
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(h, &mut pid);
    if pid == ctx.0 && IsWindowVisible(h) != 0 && GetWindow(h, 4).is_null() {
        ctx.1 = h;
        return 0;
    }
    1
}

/// 把已在运行的实例窗口拉到前台
pub fn activate_existing() -> bool {
    unsafe {
        let mut ctx = (GetCurrentProcessId(), std::ptr::null_mut::<c_void>());
        // 先试自己进程 (同进程多窗口), 再按标题找
        EnumWindows(Some(find_main_proc), &mut ctx as *mut _ as isize);
        let mut h = ctx.1;
        if h.is_null() {
            h = FindWindowW(std::ptr::null(), wide("Unlimited sky OCR 全屏实时翻译器").as_ptr());
        }
        if h.is_null() {
            return false;
        }
        ShowWindow(h, 9); // SW_RESTORE
        SetForegroundWindow(h);
        const HWND_TOPMOST: Hwnd = -1isize as Hwnd;
        const SWP_NOMOVE: u32 = 0x0002;
        const SWP_NOSIZE: u32 = 0x0001;
        SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
        SetWindowPos(
            h,
            -2isize as Hwnd, // HWND_NOTOPMOST
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE,
        );
        true
    }
}


// ------------------------------------------------------------
//  把主窗口唤到前台
//
//  完全在原生侧做, 不走 Flutter 的 platform channel ——
//  通道调用在某些窗口操作上会卡住不返回 (实测 setEffect 就会),
//  一旦 await 到超时就是将近 1 秒的延迟, 快捷键"按下去 3 秒才有反应"
//  就是这么来的。
// ------------------------------------------------------------

unsafe extern "system" fn find_own_proc(h: Hwnd, param: isize) -> i32 {
    let ctx = &mut *(param as *mut (u32, Hwnd));
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(h, &mut pid);
    if pid != ctx.0 {
        return 1;
    }
    if !GetWindow(h, 4).is_null() {
        return 1; // 有 owner 的是对话框, 跳过
    }
    // 优先可见窗口, 没有就退回隐藏的那个
    if IsWindowVisible(h) != 0 {
        ctx.1 = h;
        return 0;
    }
    if ctx.1.is_null() {
        ctx.1 = h;
    }
    1
}

/// 把本进程主窗口恢复到前台并置顶闪一下。
pub fn focus_main_window() -> bool {
    unsafe {
        let mut ctx = (GetCurrentProcessId(), std::ptr::null_mut::<c_void>());
        EnumWindows(Some(find_own_proc), &mut ctx as *mut _ as isize);
        let h = ctx.1;
        if h.is_null() {
            return false;
        }
        const SW_SHOW: i32 = 5;
        const SW_RESTORE: i32 = 9;
        const HWND_TOPMOST: Hwnd = -1isize as Hwnd;
        const HWND_NOTOPMOST: Hwnd = -2isize as Hwnd;
        const SWP_NOMOVE: u32 = 0x0002;
        const SWP_NOSIZE: u32 = 0x0001;
        const SWP_SHOWWINDOW: u32 = 0x0040;

        ShowWindow(h, SW_SHOW);
        ShowWindow(h, SW_RESTORE);
        SetWindowPos(
            h,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
        SetForegroundWindow(h);
        SetWindowPos(
            h,
            HWND_NOTOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
        true
    }
}

// ============================================================
//  系统托盘
// ============================================================

unsafe extern "system" fn tray_proc(h: Hwnd, msg: u32, w: usize, l: isize) -> isize {
    match msg {
        WM_HOTKEY => {
            if w as i32 == EXTRA_HOTKEY_ID {
                PENDING.store(CMD_RESCAN, Ordering::SeqCst);
            }
            0
        }
        WM_TRAY => {
            let event = (l as usize & 0xFFFF) as u32;
            if event == WM_LBUTTONUP {
                PENDING.store(CMD_SHOW, Ordering::SeqCst);
                return 0;
            }
            if event == WM_RBUTTONUP {
                let menu = CreatePopupMenu();
                AppendMenuW(menu, MF_STRING, IDM_SHOW, wide("显示主界面").as_ptr());
                AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                AppendMenuW(menu, MF_STRING, IDM_EXIT, wide("退出").as_ptr());
                let mut pt = Point { x: 0, y: 0 };
                GetCursorPos(&mut pt);
                SetForegroundWindow(h);
                let cmd = TrackPopupMenu(
                    menu,
                    TPM_RIGHTBUTTON | TPM_RETURNCMD,
                    pt.x,
                    pt.y,
                    0,
                    h,
                    std::ptr::null(),
                );
                DestroyMenu(menu);
                match cmd as usize {
                    IDM_SHOW => PENDING.store(CMD_SHOW, Ordering::SeqCst),
                    IDM_EXIT => {
                        PENDING.store(CMD_EXIT, Ordering::SeqCst);
                        PostMessageW(h, WM_CLOSE, 0, 0);
                    }
                    _ => {}
                }
                return 0;
            }
            0
        }
        WM_COMMAND => {
            match w & 0xFFFF {
                IDM_SHOW => PENDING.store(CMD_SHOW, Ordering::SeqCst),
                IDM_EXIT => {
                    PENDING.store(CMD_EXIT, Ordering::SeqCst);
                    PostMessageW(h, WM_CLOSE, 0, 0);
                }
                _ => {}
            }
            0
        }
        WM_CLOSE => {
            DestroyWindow(h);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(h, msg, w, l),
    }
}

/// 创建托盘图标。`exe_path` 用来抽取程序自身图标。
pub fn tray_init(tooltip: &str, exe_path: &str) -> bool {
    unsafe {
        if TRAY_HWND.load(Ordering::SeqCst) != 0 {
            return true; // 已经有了
        }
        let inst = GetModuleHandleW(std::ptr::null());
        let cls = wide("UnlimitedSkyTray");
        let wc = WndClassExW {
            cb_size: std::mem::size_of::<WndClassExW>() as u32,
            style: 0,
            lpfn_wnd_proc: Some(tray_proc),
            cb_cls_extra: 0,
            cb_wnd_extra: 0,
            h_instance: inst,
            h_icon: std::ptr::null_mut(),
            h_cursor: std::ptr::null_mut(),
            hbr_background: std::ptr::null_mut(),
            lpsz_menu_name: std::ptr::null(),
            lpsz_class_name: cls.as_ptr(),
            h_icon_sm: std::ptr::null_mut(),
        };
        RegisterClassExW(&wc);

        // 消息窗口 (不可见)
        let h = CreateWindowExW(
            0,
            cls.as_ptr(),
            wide("UnlimitedSkyTray").as_ptr(),
            0,
            0,
            0,
            0,
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            inst,
            std::ptr::null_mut(),
        );
        if h.is_null() {
            return false;
        }

        // 从自己的 exe 抽图标 (大图标更适合托盘)
        let mut large: Hicon = std::ptr::null_mut();
        let mut small: Hicon = std::ptr::null_mut();
        let n = ExtractIconExW(
            wide(exe_path).as_ptr(),
            0,
            &mut large,
            &mut small,
            1,
        );
        let icon = if n > 0 && !small.is_null() {
            small
        } else if !large.is_null() {
            large
        } else {
            ExtractIconW(inst, wide(exe_path).as_ptr(), 0)
        };

        let mut data = NotifyIconDataW {
            cb_size: std::mem::size_of::<NotifyIconDataW>() as u32,
            hwnd: h,
            u_id: 1,
            u_flags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            u_callback_message: WM_TRAY,
            h_icon: icon,
            sz_tip: [0; 128],
            dw_state: 0,
            sz_state: [0; 256],
            sz_info: [0; 256],
            u_timeout_or_version: 0,
            sz_info_title: [0; 64],
            dw_info_flags: 0,
            guid_item: [0; 16],
            h_balloon_icon: std::ptr::null_mut(),
        };
        for (i, c) in tooltip.encode_utf16().take(127).enumerate() {
            data.sz_tip[i] = c;
        }

        if Shell_NotifyIconW(NIM_ADD, &mut data) == 0 {
            DestroyWindow(h);
            return false;
        }
        TRAY_HWND.store(h as isize, Ordering::SeqCst);

        // 起一个线程跑托盘的消息循环
        std::thread::spawn(move || {
            let mut msg: Msg = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        });
        true
    }
}

/// 注册一个"额外"的全局热键 (目前用于"立刻重扫屏幕")。
///
/// 之所以不交给 Dart 侧的 hotkey_manager: 实测注册到第 9 个时回调就不再触发了,
/// 原生 RegisterHotKey 没有这个问题, 而且注册失败能明确知道。
/// `mods` 位标志: 1=Alt 2=Ctrl 4=Shift 8=Win
pub fn register_extra_hotkey(mods: u32, vk: u32) -> bool {
    unsafe {
        let h = TRAY_HWND.load(Ordering::SeqCst) as Hwnd;
        if h.is_null() {
            return false;
        }
        const MOD_NOREPEAT: u32 = 0x4000;
        UnregisterHotKey(h, EXTRA_HOTKEY_ID);
        RegisterHotKey(h, EXTRA_HOTKEY_ID, mods | MOD_NOREPEAT, vk) != 0
    }
}

/// 注销那个额外热键
pub fn unregister_extra_hotkey() {
    unsafe {
        let h = TRAY_HWND.load(Ordering::SeqCst) as Hwnd;
        if !h.is_null() {
            UnregisterHotKey(h, EXTRA_HOTKEY_ID);
        }
    }
}

/// 取出待处理命令 (0=无 1=显示主界面 2=退出 3=强制重扫), 取走即清空
pub fn tray_poll() -> i32 {
    PENDING.swap(CMD_NONE, Ordering::SeqCst)
}

/// 移除托盘图标
pub fn tray_dispose() {
    let h = TRAY_HWND.swap(0, Ordering::SeqCst) as Hwnd;
    if h.is_null() {
        return;
    }
    unsafe {
        let mut data = NotifyIconDataW {
            cb_size: std::mem::size_of::<NotifyIconDataW>() as u32,
            hwnd: h,
            u_id: 1,
            u_flags: 0,
            u_callback_message: WM_TRAY,
            h_icon: std::ptr::null_mut(),
            sz_tip: [0; 128],
            dw_state: 0,
            sz_state: [0; 256],
            sz_info: [0; 256],
            u_timeout_or_version: 0,
            sz_info_title: [0; 64],
            dw_info_flags: 0,
            guid_item: [0; 16],
            h_balloon_icon: std::ptr::null_mut(),
        };
        UnregisterHotKey(h, EXTRA_HOTKEY_ID);
        Shell_NotifyIconW(NIM_DELETE, &mut data);
        PostMessageW(h, WM_CLOSE, 0, 0);
    }
}

// ============================================================
//  开机自启
// ============================================================

/// 设置/取消开机自启
pub fn set_autostart(enable: bool, exe_path: &str) -> bool {
    unsafe {
        let mut h: Hkey = std::ptr::null_mut();
        let rc = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            wide(RUN_KEY).as_ptr(),
            0,
            std::ptr::null(),
            0,
            KEY_SET_VALUE | KEY_QUERY_VALUE,
            std::ptr::null_mut(),
            &mut h,
            std::ptr::null_mut(),
        );
        if rc != 0 || h.is_null() {
            return false;
        }
        let ok = if enable {
            // 加引号, 防止路径里有空格时被截断
            let v: Vec<u16> = format!("\"{exe_path}\" --autostart")
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            RegSetValueExW(
                h,
                wide(RUN_VALUE).as_ptr(),
                0,
                REG_SZ,
                v.as_ptr() as *const u8,
                (v.len() * 2) as u32,
            ) == 0
        } else {
            let r = RegDeleteValueW(h, wide(RUN_VALUE).as_ptr());
            r == 0 || r == 2 // 2 = 本来就没有
        };
        RegCloseKey(h);
        ok
    }
}

/// 查询当前是否已设置开机自启
pub fn get_autostart() -> bool {
    unsafe {
        let mut h: Hkey = std::ptr::null_mut();
        let rc = RegOpenKeyExW(
            HKEY_CURRENT_USER,
            wide(RUN_KEY).as_ptr(),
            0,
            KEY_QUERY_VALUE,
            &mut h,
        );
        if rc != 0 || h.is_null() {
            return false;
        }
        let mut buf = [0u16; 1024];
        let mut len = (buf.len() * 2) as u32;
        let r = RegQueryValueExW(
            h,
            wide(RUN_VALUE).as_ptr(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            buf.as_mut_ptr() as *mut u8,
            &mut len,
        );
        RegCloseKey(h);
        r == 0
    }
}
