//! Unlimited sky OCR 全屏实时翻译器 —— 图形界面安装程序
//!
//! 纯 Win32 实现, 不依赖任何 GUI 框架, 也不依赖 Inno Setup / NSIS:
//!   * 自解压: 发布目录追加在本 exe 尾部
//!   * 图形界面: 可选安装路径、可选模型存放路径、进度条
//!   * 无控制台窗口 (`windows_subsystem = "windows"`)
//!
//! 载荷格式 (从文件尾部倒着找):
//!   [文件数据...][索引 JSON][索引长度 u64 LE][魔数 "SKYSETUP1"]

#![windows_subsystem = "windows"]

use std::ffi::c_void;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::os::windows::process::CommandExt;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

/// 不让外部程序弹出控制台窗口
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

mod ai;
mod hw;
mod reg;
mod ui;

const MAGIC: &[u8; 9] = b"SKYSETUP1";
const APP_NAME: &str = "Unlimited sky OCR 全屏实时翻译器";
const APP_EXE: &str = "UnlimitedSky.exe";

#[derive(serde::Deserialize)]
pub struct Entry {
    /// 相对路径
    pub p: String,
    /// 数据偏移
    pub o: u64,
    /// 数据长度
    pub l: u64,
}

/// 安装选项
#[derive(Clone)]
pub struct Options {
    pub app_dir: PathBuf,
    pub model_dir: PathBuf,
    pub desktop_link: bool,
    pub start_link: bool,
    pub run_after: bool,
    /// 是否同时部署本地 AI 翻译
    pub install_ai: bool,
    /// 本地 AI 模型的存放位置 (模型 4.4GB + Ollama 运行时 1.5GB)
    pub ai_dir: PathBuf,
    /// 检测到的显存 (决定用哪个量化档)
    pub vram_mb: u32,
}

fn main() {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(_) => return,
    };
    let entries = match read_index(&exe) {
        Ok(v) => v,
        Err(e) => {
            ui::error_box(&format!(
                "安装包不完整或已损坏。\n\n请使用从桌面复制过来的完整文件。\n\n({e})"
            ));
            return;
        }
    };

    let self_path = exe.clone();
    ui::run(Arc::new(entries), self_path);
}

/// 从自身尾部读取载荷索引
fn read_index(exe: &Path) -> std::io::Result<Vec<Entry>> {
    let mut f = fs::File::open(exe)?;
    let len = f.metadata()?.len();
    if len < 32 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "文件太小"));
    }
    f.seek(SeekFrom::End(-(MAGIC.len() as i64)))?;
    let mut magic = [0u8; 9];
    f.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "未找到安装数据",
        ));
    }
    f.seek(SeekFrom::End(-((MAGIC.len() + 8) as i64)))?;
    let mut lb = [0u8; 8];
    f.read_exact(&mut lb)?;
    let ilen = u64::from_le_bytes(lb);
    if ilen == 0 || ilen > len {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "索引长度异常"));
    }
    f.seek(SeekFrom::End(-((MAGIC.len() + 8) as i64 + ilen as i64)))?;
    let mut buf = vec![0u8; ilen as usize];
    f.read_exact(&mut buf)?;
    serde_json::from_slice(&buf).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

// ============================================================
//  安装逻辑 (在工作线程里跑)
// ============================================================

pub struct Progress {
    pub percent: Arc<AtomicU32>,
    pub status: Arc<std::sync::Mutex<String>>,
    pub done: Arc<AtomicBool>,
    pub failed: Arc<std::sync::Mutex<Option<String>>>,
}

pub fn install(exe: &Path, entries: &[Entry], opt: &Options, prog: &Progress) {
    let r = install_inner(exe, entries, opt, prog);
    if let Err(e) = r {
        *prog.failed.lock().unwrap() = Some(e);
    }
    prog.done.store(true, Ordering::SeqCst);
}

fn set_status(prog: &Progress, s: &str) {
    *prog.status.lock().unwrap() = s.to_string();
}

fn install_inner(
    exe: &Path,
    entries: &[Entry],
    opt: &Options,
    prog: &Progress,
) -> Result<(), String> {
    set_status(prog, "正在结束正在运行的旧版本…");
    // 注意: 必须带 CREATE_NO_WINDOW, 否则 taskkill / powershell 会闪出 cmd 黑框
    let _ = std::process::Command::new("taskkill")
        .args(["/IM", APP_EXE, "/F"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    std::thread::sleep(std::time::Duration::from_millis(500));

    fs::create_dir_all(&opt.app_dir).map_err(|e| format!("无法创建安装目录: {e}"))?;
    fs::create_dir_all(&opt.model_dir).map_err(|e| format!("无法创建模型目录: {e}"))?;

    let total: u64 = entries.iter().map(|e| e.l).sum();
    let mut src = fs::File::open(exe).map_err(|e| e.to_string())?;
    let mut done: u64 = 0;

    for e in entries {
        // 模型文件走模型目录, 其余走程序目录
        let is_model = e.p.starts_with("models/");
        let base = if is_model { &opt.model_dir } else { &opt.app_dir };
        let rel = if is_model {
            e.p.trim_start_matches("models/")
        } else {
            e.p.as_str()
        };
        let out = base.join(rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("创建目录失败: {e}"))?;
        }
        src.seek(SeekFrom::Start(e.o)).map_err(|e| e.to_string())?;
        let mut data = vec![0u8; e.l as usize];
        src.read_exact(&mut data).map_err(|e| e.to_string())?;
        fs::write(&out, &data).map_err(|e| format!("写入 {} 失败: {e}", out.display()))?;

        done += e.l;
        prog.percent
            .store((done * 100 / total.max(1)) as u32, Ordering::SeqCst);
        if done % (8 * 1024 * 1024) < e.l {
            set_status(
                prog,
                &format!(
                    "正在安装…  {:.0} / {:.0} MB",
                    done as f64 / 1048576.0,
                    total as f64 / 1048576.0
                ),
            );
        }
    }

    // 告诉程序模型放在哪里
    set_status(prog, "写入配置…");
    let cfg = format!(
        "{{\n  \"modelRoot\": {}\n}}\n",
        serde_json::to_string(&opt.model_dir.display().to_string()).unwrap()
    );
    let _ = fs::write(opt.app_dir.join("sky_config.json"), cfg);

    // 快捷方式
    if opt.desktop_link || opt.start_link {
        set_status(prog, "创建快捷方式…");
        if let Err(e) = create_shortcuts(opt) {
            // 快捷方式失败不该让整个安装失败
            set_status(prog, &format!("快捷方式创建失败 (不影响使用): {e}"));
            std::thread::sleep(std::time::Duration::from_millis(900));
        }
    }

    // 卸载程序随包一起装进去 (由软件主界面的「卸载软件」按钮调用,
    // 也可以从开始菜单单独运行)。它是图形界面的, 不会弹命令行窗口。
    set_status(prog, "写入卸载程序…");
    if let Ok(self_exe) = std::env::current_exe() {
        if let Some(dir) = self_exe.parent() {
            let helper = dir.join("sky_uninstall.exe");
            if helper.exists() {
                let _ = fs::copy(&helper, opt.app_dir.join("sky_uninstall.exe"));
            }
        }
    }

    // 注册到系统卸载列表 —— Geek / Revo / 「应用和功能」都读这里
    set_status(prog, "注册卸载信息…");
    let size_kb = (total / 1024) as u32;
    let app_dir_s = opt.app_dir.display().to_string();
    let reg_ok = reg::register(&reg::UninstallInfo {
        display_name: APP_NAME,
        version: "1.0.0",
        publisher: "Unlimited sky",
        app_dir: &app_dir_s,
        exe_path: &opt.app_dir.join(APP_EXE).display().to_string(),
        uninstaller: &opt.app_dir.join("sky_uninstall.exe").display().to_string(),
        size_kb,
    });
    if !reg_ok {
        set_status(prog, "提示: 写入卸载注册表项失败, 卸载工具可能看不到本软件");
        std::thread::sleep(std::time::Duration::from_millis(1200));
    }

    // 本地 AI 翻译 (可选) —— 下载量大, 放在最后, 前面已经装完的不会白费
    if opt.install_ai {
        deploy_ai(opt, prog, 80);
    }

    set_status(prog, "安装完成");
    prog.percent.store(100, Ordering::SeqCst);
    Ok(())
}

/// 部署本地 AI 翻译。失败**不算安装失败** —— 主程序已经装好了,
/// 用户仍然可以用云端 API 或内置离线翻译。
fn deploy_ai(opt: &Options, prog: &Progress, base_pct: u32) {
    let aopt = ai::AiOptions {
        root: opt.ai_dir.clone(),
        vram_mb: opt.vram_mb,
    };
    // 把 AI 这段的 0-100 映射到整体进度的 base_pct-100
    let span = 100u32.saturating_sub(base_pct);
    let status = prog.status.clone();
    let percent = prog.percent.clone();
    let cb = move |p: u32, msg: String| {
        *status.lock().unwrap() = msg;
        percent.store(base_pct + span * p / 100, Ordering::SeqCst);
    };
    let ap = ai::AiProgress { report: &cb };
    if let Err(e) = ai::deploy(&aopt, &ap) {
        *prog.status.lock().unwrap() =
            format!("本地 AI 未装成功（不影响主程序）: {e}");
        std::thread::sleep(std::time::Duration::from_millis(2500));
    }
}

fn create_shortcuts(opt: &Options) -> Result<(), String> {
    let app = opt.app_dir.join(APP_EXE);
    let mut targets: Vec<PathBuf> = Vec::new();
    if opt.desktop_link {
        targets.push(
            PathBuf::from(std::env::var("USERPROFILE").unwrap_or_default())
                .join("Desktop")
                .join(format!("{APP_NAME}.lnk")),
        );
    }
    if opt.start_link {
        targets.push(
            PathBuf::from(std::env::var("APPDATA").unwrap_or_default())
                .join("Microsoft\\Windows\\Start Menu\\Programs")
                .join(format!("{APP_NAME}.lnk")),
        );
    }
    if targets.is_empty() {
        return Ok(());
    }

    let list = targets
        .iter()
        .map(|p| format!("'{}'", p.display().to_string().replace('\'', "''")))
        .collect::<Vec<_>>()
        .join(",");
    let ps = format!(
        r#"$w = New-Object -ComObject WScript.Shell
foreach ($p in @({list})) {{
  $l = $w.CreateShortcut($p)
  $l.TargetPath = '{t}'
  $l.WorkingDirectory = '{d}'
  $l.IconLocation = '{t},0'
  $l.Description = '{APP_NAME}'
  $l.Save()
}}"#,
        list = list,
        t = app.display().to_string().replace('\'', "''"),
        d = opt.app_dir.display().to_string().replace('\'', "''"),
    );
    let out = std::process::Command::new("powershell")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &ps])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).to_string());
    }
    Ok(())
}

pub fn launch(opt: &Options) {
    let app = opt.app_dir.join(APP_EXE);
    let _ = std::process::Command::new(&app)
        .current_dir(&opt.app_dir)
        .spawn();
}

// 供 ui 模块使用
#[allow(dead_code)]
pub fn dummy(_: *mut c_void) {}
