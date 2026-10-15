//! 硬件环境检测
//!
//! 本地 AI 翻译要跑一个 7B 大模型, 对显卡有硬性要求。安装时必须先查清楚,
//! 达不到就在界面上明说 —— 免得用户装完 6GB 模型发现跑不动。
//!
//! 全部用原生 API / nvidia-smi, 不引入额外依赖。

use std::os::windows::process::CommandExt;
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[link(name = "kernel32")]
extern "system" {
    fn GlobalMemoryStatusEx(buf: *mut MemoryStatusEx) -> i32;
    fn GetDiskFreeSpaceExW(
        dir: *const u16,
        free_avail: *mut u64,
        total: *mut u64,
        total_free: *mut u64,
    ) -> i32;
}

#[repr(C)]
struct MemoryStatusEx {
    length: u32,
    memory_load: u32,
    total_phys: u64,
    avail_phys: u64,
    total_page_file: u64,
    avail_page_file: u64,
    total_virtual: u64,
    avail_virtual: u64,
    avail_extended_virtual: u64,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

// ============================================================
//  检测结果
// ============================================================

#[derive(Debug, Clone)]
pub struct HwInfo {
    /// 有没有 NVIDIA 显卡 (本地推理基本只能靠它)
    pub has_nvidia: bool,
    pub gpu_name: String,
    pub vram_mb: u32,
    /// 计算能力, 如 "12.0" (Blackwell sm_120)
    pub compute: String,
    pub driver: String,
    pub ram_gb: f64,
}

/// 能不能跑本地 AI 的档位
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiTier {
    /// 显存充裕, 可以上更高精度
    Great,
    /// 刚好够 (8GB 档)
    Good,
    /// 勉强, 要降量化档
    Tight,
    /// 跑不了
    No,
}

impl AiTier {
    pub fn can_install(self) -> bool {
        self != AiTier::No
    }
}

/// 按显存挑量化档位 —— 显存越大越可以用高精度
pub fn pick_quant(vram_mb: u32) -> (&'static str, &'static str, u32) {
    // (量化档, 文件名后缀, 大约多少 MB)
    if vram_mb >= 11264 {
        ("Q5_K_M", "Q5_K_M", 5123)
    } else if vram_mb >= 7168 {
        ("Q4_K_M", "Q4_K_M", 4411)
    } else if vram_mb >= 5632 {
        ("Q3_K_M", "Q3_K_M", 3617)
    } else {
        ("Q3_K_S", "Q3_K_S", 3279)
    }
}

// ============================================================
//  检测
// ============================================================

pub fn detect() -> HwInfo {
    let mut info = HwInfo {
        has_nvidia: false,
        gpu_name: String::new(),
        vram_mb: 0,
        compute: String::new(),
        driver: String::new(),
        ram_gb: total_ram_gb(),
    };

    // nvidia-smi 在装了 NVIDIA 驱动的机器上一定在 System32 里
    let out = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,memory.total,compute_cap,driver_version",
            "--format=csv,noheader,nounits",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    if let Ok(o) = out {
        if o.status.success() {
            let text = String::from_utf8_lossy(&o.stdout);
            // 多卡时只取第一块
            if let Some(line) = text.lines().next() {
                let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                if parts.len() >= 4 {
                    info.has_nvidia = true;
                    info.gpu_name = parts[0].to_string();
                    info.vram_mb = parts[1].parse().unwrap_or(0);
                    info.compute = parts[2].to_string();
                    info.driver = parts[3].to_string();
                }
            }
        }
    }
    info
}

fn total_ram_gb() -> f64 {
    unsafe {
        let mut m: MemoryStatusEx = std::mem::zeroed();
        m.length = std::mem::size_of::<MemoryStatusEx>() as u32;
        if GlobalMemoryStatusEx(&mut m) != 0 {
            m.total_phys as f64 / 1024.0 / 1024.0 / 1024.0
        } else {
            0.0
        }
    }
}

/// 某个目录所在磁盘的可用空间 (GB)
pub fn free_disk_gb(dir: &str) -> f64 {
    unsafe {
        let d = wide(dir);
        let mut avail: u64 = 0;
        let mut total: u64 = 0;
        let mut total_free: u64 = 0;
        if GetDiskFreeSpaceExW(d.as_ptr(), &mut avail, &mut total, &mut total_free) != 0 {
            avail as f64 / 1024.0 / 1024.0 / 1024.0
        } else {
            0.0
        }
    }
}

/// 同 [`free_disk_gb`], 但目录**还不存在**时逐级往上找最近的已存在父目录。
///
/// `GetDiskFreeSpaceExW` 对不存在的路径会直接失败返回 0 —— 而全新安装时
/// "程序安装位置"本来就不存在, 于是磁盘检查会误报"空间不足", 把本地 AI
/// 的勾选项错误地禁掉。装到别的盘这种正常操作也会撞上。
pub fn free_disk_gb_deep(dir: &str) -> f64 {
    let direct = free_disk_gb(dir);
    if direct > 0.0 {
        return direct;
    }
    let mut probe = std::path::PathBuf::from(dir);
    for _ in 0..8 {
        if !probe.pop() {
            break;
        }
        let f = free_disk_gb(&probe.display().to_string());
        if f > 0.0 {
            return f;
        }
    }
    0.0
}

// ============================================================
//  判定
// ============================================================

pub struct Verdict {
    pub tier: AiTier,
    /// 界面上显示的主提示 (一行)
    pub title: String,
    /// 详细说明 (几行, 讲清楚为什么 / 怎么办)
    pub detail: String,
    /// 是否可以让用户勾选安装
    pub selectable: bool,
}

/// 本地 AI 的硬性要求 (写在界面上给用户看)
pub const REQ_TEXT: &str = "最低：NVIDIA 显卡 6GB 显存 · 16GB 内存 · 12GB 可用磁盘\n\
                            推荐：NVIDIA 显卡 8GB 显存及以上（RTX 3060 / 4060 / 5060 等）";

pub fn judge(info: &HwInfo, disk_free_gb: f64) -> Verdict {
    // 内存是第二道门槛: 模型加载和系统都要用
    let ram_ok = info.ram_gb >= 15.0;

    if !info.has_nvidia {
        return Verdict {
            tier: AiTier::No,
            title: "✗ 未检测到 NVIDIA 显卡，无法在本机运行 AI 翻译".into(),
            detail: "本地大模型需要 NVIDIA 显卡做推理。\n\
                     没有的话请在主界面用「腾讯交互翻译」或「AI 大模型翻译」\n\
                     接云端 API（如 DeepSeek），不需要显卡。"
                .into(),
            selectable: false,
        };
    }

    if info.vram_mb < 5000 {
        return Verdict {
            tier: AiTier::No,
            title: format!(
                "✗ 显存不足（{}，只有 {} MB）",
                info.gpu_name, info.vram_mb
            ),
            detail: format!(
                "本地 AI 翻译最低需要 6GB 显存，当前只有 {:.1}GB。\n\
                 显存不够会导致模型跑到内存里，速度会慢十倍以上，体验很差。\n\
                 建议改用云端 API 翻译（DeepSeek 等），不需要显卡。",
                info.vram_mb as f64 / 1024.0
            ),
            selectable: false,
        };
    }

    if disk_free_gb < 12.0 {
        return Verdict {
            tier: AiTier::No,
            title: format!("✗ 磁盘空间不足（可用 {:.1} GB，需要 12 GB）", disk_free_gb),
            detail: "Ollama 运行时约 1.5GB，翻译模型约 3.3-5.1GB（按显存自动选档），\n\
                     再加上解压和缓存的余量，请换一个空间更大的磁盘。"
                .into(),
            selectable: false,
        };
    }

    if !ram_ok {
        return Verdict {
            tier: AiTier::Tight,
            title: format!("△ 内存偏小（{:.1} GB，建议 16 GB）", info.ram_gb),
            detail: "仍然可以安装，但翻译时系统可能会有点卡。".into(),
            selectable: true,
        };
    }

    let (q, _, size) = pick_quant(info.vram_mb);
    let vram_gb = info.vram_mb as f64 / 1024.0;

    let tier = if info.vram_mb >= 11264 {
        AiTier::Great
    } else if info.vram_mb >= 7168 {
        AiTier::Good
    } else {
        AiTier::Tight
    };

    let tag = match tier {
        AiTier::Great => "✓ 完全可以（推荐档）",
        AiTier::Good => "✓ 可以运行（推荐配置）",
        _ => "△ 勉强可以运行",
    };

    Verdict {
        tier,
        title: format!(
            "{} · {} · {:.1}GB 显存 · 计算能力 {}",
            tag, info.gpu_name, vram_gb, info.compute
        ),
        detail: format!(
            "将自动使用 {q} 量化档（约 {:.1} GB），全量加载到显存。\n\
             首次安装要下载约 6 GB，请保持网络畅通。",
            size as f64 / 1024.0
        ),
        selectable: true,
    }
}

// ============================================================
//  Command 的 creation_flags (Windows 扩展)
// ============================================================
