//! Unlimited sky OCR 全屏实时翻译器 —— 卸载程序
//!
//! 由软件主界面的「卸载软件」按钮调用, 也可以单独运行。
//! 全程图形界面, 不弹命令行窗口。
//!
//! 用法:
//!   sky_uninstall.exe [--silent] [--pid N] [--app-dir DIR] [--model-dir DIR]
//!
//! 参数都可以省略 —— 省略时会根据自身所在目录推断。

#![windows_subsystem = "windows"]

use std::ffi::c_void;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[path = "../reg.rs"]
mod reg;

const APP_NAME: &str = "Unlimited sky OCR 全屏实时翻译器";
const APP_EXE: &str = "UnlimitedSky.exe";

// ---------------- Win32 ----------------

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(h: *mut c_void, text: *const u16, caption: *const u16, ty: u32) -> i32;
    fn SetForegroundWindow(h: *mut c_void) -> i32;
    fn GetForegroundWindow() -> *mut c_void;
}
#[link(name = "kernel32")]
extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut c_void;
    fn WaitForSingleObject(h: *mut c_void, ms: u32) -> u32;
    fn CloseHandle(h: *mut c_void) -> i32;
}
#[link(name = "shell32")]
extern "system" {
    fn SHFileOperationW(op: *mut ShFileOpStructW) -> i32;
}

#[repr(C)]
struct ShFileOpStructW {
    hwnd: *mut c_void,
    w_func: u32,
    p_from: *const u16,
    p_to: *const u16,
    flags: u16,
    f_any_operations_aborted: i32,
    name_mappings: *mut c_void,
    progress_title: *const u16,
}

const FO_DELETE: u32 = 3;
const FOF_SILENT: u16 = 0x0004;
const FOF_NOCONFIRMATION: u16 = 0x0010;
const FOF_ALLOWUNDO: u16 = 0x0040;
const FOF_NOERRORUI: u16 = 0x0400;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 双 NUL 结尾的路径列表
fn double_nul(s: &str) -> Vec<u16> {
    let mut v: Vec<u16> = s.encode_utf16().collect();
    v.push(0);
    v.push(0);
    v
}

fn box_yes_no(text: &str, title: &str) -> bool {
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONQUESTION: u32 = 0x0000_0020;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;
    const MB_TOPMOST: u32 = 0x0004_0000;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(text).as_ptr(),
            wide(title).as_ptr(),
            MB_YESNO | MB_ICONQUESTION | MB_SETFOREGROUND | MB_TOPMOST,
        ) == 6
    }
}

fn info(text: &str, title: &str) {
    const MB_OK: u32 = 0x0000_0000;
    const MB_ICONINFORMATION: u32 = 0x0000_0040;
    const MB_SETFOREGROUND: u32 = 0x0001_0000;
    const MB_TOPMOST: u32 = 0x0004_0000;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            wide(text).as_ptr(),
            wide(title).as_ptr(),
            MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST,
        );
    }
}

/// 送进回收站, 误删了还能找回来
fn recycle(path: &Path) -> bool {
    if !path.exists() {
        return true;
    }
    unsafe {
        let from = double_nul(&path.display().to_string());
        let title = wide("正在卸载…");
        let mut op = ShFileOpStructW {
            hwnd: std::ptr::null_mut(),
            w_func: FO_DELETE,
            p_from: from.as_ptr(),
            p_to: std::ptr::null(),
            flags: FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_ALLOWUNDO,
            f_any_operations_aborted: 0,
            name_mappings: std::ptr::null_mut(),
            progress_title: title.as_ptr(),
        };
        SHFileOperationW(&mut op) == 0
    }
}

/// 回收站不行就硬删
fn remove_path(path: &Path) {
    if !path.exists() {
        return;
    }
    if recycle(path) && !path.exists() {
        return;
    }
    if path.is_dir() {
        let _ = fs::remove_dir_all(path);
    } else {
        let _ = fs::remove_file(path);
    }
}

fn wait_pid(pid: u32, ms: u32) {
    if pid == 0 {
        return;
    }
    unsafe {
        const SYNCHRONIZE: u32 = 0x0010_0000;
        let h = OpenProcess(SYNCHRONIZE, 0, pid);
        if !h.is_null() {
            WaitForSingleObject(h, ms);
            CloseHandle(h);
        }
    }
}

// ---------------- 主流程 ----------------

static LOG: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

fn log(s: String) {
    LOG.get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap()
        .push(s);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let silent = args.iter().any(|a| a == "--silent");
    // 逗号分隔的 PID 列表: 要等这些进程都退出才能删文件
    let mut pids: Vec<u32> = arg_value(&args, "--pid")
        .map(|v| {
            v.split(',')
                .filter_map(|x| x.trim().parse::<u32>().ok())
                .collect()
        })
        .unwrap_or_default();

    let self_exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("sky_uninstall.exe"));
    let self_dir = self_exe
        .parent()
        .map(|d| d.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));

    let app_dir = arg_value(&args, "--app-dir")
        .map(PathBuf::from)
        .unwrap_or_else(|| self_dir.clone());

    // 自己就住在要被删掉的目录里 —— Windows 不允许删除正在运行的 exe,
    // 直接删会留下半个残骸 (Geek 卸载后残留目录就是这个原因)。
    // 所以先把自己复制到 TEMP, 再从那里重新跑一遍。
    let relocated = args.iter().any(|a| a == "--relocated");
    if !relocated && same_dir(&self_dir, &app_dir) {
        let tmp = std::env::temp_dir().join("sky_uninstall_run.exe");
        if fs::copy(&self_exe, &tmp).is_ok() {
            let mut child = std::process::Command::new(&tmp);
            if silent {
                child.arg("--silent");
            }
            child.arg("--relocated");
            // 关键: 把**自己**也加进等待列表, 否则新实例会在旧实例还活着
            // (exe 被占用) 的时候就去删目录, 结果留下一堆删不掉的文件
            pids.push(std::process::id());
            let list = pids
                .iter()
                .map(|v| v.to_string())
                .collect::<Vec<_>>()
                .join(",");
            child.arg("--pid").arg(list);
            child.arg("--app-dir").arg(&app_dir);
            if let Some(m) = arg_value(&args, "--model-dir") {
                child.arg("--model-dir").arg(m);
            }
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                const CREATE_NO_WINDOW: u32 = 0x0800_0000;
                child.creation_flags(CREATE_NO_WINDOW);
            }
            if child.spawn().is_ok() {
                return;
            }
        }
    }

    // 模型目录: 优先读配置文件, 否则默认在程序目录下的 models
    let model_dir = arg_value(&args, "--model-dir")
        .map(PathBuf::from)
        .or_else(|| read_model_dir(&app_dir))
        .unwrap_or_else(|| app_dir.join("models"));

    let appdata = PathBuf::from(std::env::var("APPDATA").unwrap_or_default())
        .join("com.dpg")
        .join("dpg_app");
    let desktop_lnk = PathBuf::from(std::env::var("USERPROFILE").unwrap_or_default())
        .join("Desktop")
        .join(format!("{APP_NAME}.lnk"));
    let start_lnk = PathBuf::from(std::env::var("APPDATA").unwrap_or_default())
        .join("Microsoft\\Windows\\Start Menu\\Programs")
        .join(format!("{APP_NAME}.lnk"));

    let models_separate = model_dir != app_dir.join("models");

    if !silent {
        let mut msg = format!(
            "即将卸载：\n\n  {APP_NAME}\n\n\
             程序目录：\n  {}\n",
            app_dir.display()
        );
        if models_separate {
            msg.push_str(&format!("\n模型目录：\n  {}\n", model_dir.display()));
        }
        msg.push_str("\n删除的内容会先放进回收站，误删可以还原。\n\n确定继续吗？");
        if !box_yes_no(&msg, "确认卸载") {
            return;
        }
    }

    // 模型目录单独确认 (它可能很大, 而且可能在别的盘)
    let remove_models = if silent {
        true
    } else if models_separate {
        box_yes_no(
            &format!(
                "是否一并删除模型文件？\n\n  {}\n\n\
                 选「是」= 一起删除（释放约 228 MB）\n\
                 选「否」= 保留模型，下次安装可以复用",
                model_dir.display()
            ),
            "模型文件",
        )
    } else {
        true
    };

    // 等待所有相关进程退出 (主程序 + 搬迁前的旧卸载器)
    for p in &pids {
        wait_pid(*p, 15000);
    }
    std::thread::sleep(std::time::Duration::from_millis(700));

    // 快捷方式
    if desktop_lnk.exists() {
        remove_path(&desktop_lnk);
        log(format!("已删除桌面快捷方式"));
    }
    if start_lnk.exists() {
        remove_path(&start_lnk);
        log("已删除开始菜单快捷方式".to_string());
    }
    // 开始菜单里可能还有个"卸载"快捷方式
    let unlnk = PathBuf::from(std::env::var("APPDATA").unwrap_or_default())
        .join("Microsoft\\Windows\\Start Menu\\Programs")
        .join(format!("卸载 {APP_NAME}.lnk"));
    if unlnk.exists() {
        remove_path(&unlnk);
    }

    // 模型
    if remove_models && model_dir.exists() {
        remove_path(&model_dir);
        log(format!("已删除模型目录 {}", model_dir.display()));
    } else if model_dir.exists() {
        log(format!("已保留模型目录 {}", model_dir.display()));
    }

    // 系统卸载列表里的登记
    if reg::unregister() {
        log("已从系统卸载列表中移除".to_string());
    }

    // 用户配置与日志
    if appdata.exists() {
        remove_path(&appdata);
        log("已删除用户配置与日志".to_string());
    }

    // 程序目录 (放在最后)。正常情况下我们已经把自己搬到 TEMP 了, 这里能删干净
    remove_path(&app_dir);
    if app_dir.exists() {
        // 占用释放可能慢半拍, 再试两次
        for _ in 0..3 {
            std::thread::sleep(std::time::Duration::from_millis(900));
            remove_path(&app_dir);
            if !app_dir.exists() {
                break;
            }
            // 回收站不行就直接硬删
            let _ = fs::remove_dir_all(&app_dir);
        }
    }
    if app_dir.exists() {
        log(format!("程序目录未能完全删除: {}", app_dir.display()));
    } else {
        log(format!("已删除程序目录 {}", app_dir.display()));
    }

    if !silent {
        let mut msg = String::from("卸载完成。\n\n");
        for l in LOG.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap().iter() {
            msg.push_str("  · ");
            msg.push_str(l);
            msg.push('\n');
        }
        if app_dir.exists() {
            msg.push_str(&format!(
                "\n注意：程序目录还有残留，请手动删除：\n  {}\n",
                app_dir.display()
            ));
        }
        info(&msg, "卸载完成");
    }
}

/// 两个路径是否指向同一个目录 (大小写不敏感, 忽略结尾分隔符)
fn same_dir(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| {
        p.canonicalize()
            .unwrap_or_else(|_| p.to_path_buf())
            .display()
            .to_string()
            .trim_end_matches(['\\', '/'])
            .to_ascii_lowercase()
    };
    norm(a) == norm(b)
}

fn arg_value(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|a| a == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn read_model_dir(app_dir: &Path) -> Option<PathBuf> {
    let cfg = fs::read_to_string(app_dir.join("sky_config.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&cfg).ok()?;
    v.get("modelRoot")?.as_str().map(PathBuf::from)
}
