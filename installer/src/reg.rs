//! 注册表卸载信息
//!
//! Geek Uninstaller、Revo、Windows「应用和功能」等工具都靠读取
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<键名>` 来发现软件。
//! 不写这个键, 软件在它们眼里就是"不存在", 也就没法被卸载。

use std::ffi::c_void;

type Hkey = *mut c_void;
const HKEY_CURRENT_USER: Hkey = 0x8000_0001u32 as usize as Hkey;
const KEY_WRITE: u32 = 0x20006;
const REG_SZ: u32 = 1;
const REG_DWORD: u32 = 4;

/// 卸载信息使用的注册表键名 (用英文, 避免某些工具对中文键名处理异常)
pub const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\UnlimitedSkyOCR";

#[link(name = "advapi32")]
extern "system" {
    fn RegCreateKeyExW(
        hkey: Hkey,
        sub_key: *const u16,
        reserved: u32,
        class: *const u16,
        options: u32,
        sam: u32,
        sa: *mut c_void,
        result: *mut Hkey,
        disposition: *mut u32,
    ) -> i32;
    fn RegSetValueExW(
        hkey: Hkey,
        name: *const u16,
        reserved: u32,
        ty: u32,
        data: *const u8,
        len: u32,
    ) -> i32;
    fn RegDeleteTreeW(hkey: Hkey, sub_key: *const u16) -> i32;
    fn RegCloseKey(hkey: Hkey) -> i32;
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe fn set_str(h: Hkey, name: &str, value: &str) -> bool {
    let n = wide(name);
    let v: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
    RegSetValueExW(
        h,
        n.as_ptr(),
        0,
        REG_SZ,
        v.as_ptr() as *const u8,
        (v.len() * 2) as u32,
    ) == 0
}

unsafe fn set_dword(h: Hkey, name: &str, value: u32) -> bool {
    let n = wide(name);
    let v = value.to_le_bytes();
    RegSetValueExW(h, n.as_ptr(), 0, REG_DWORD, v.as_ptr(), 4) == 0
}

pub struct UninstallInfo<'a> {
    pub display_name: &'a str,
    pub version: &'a str,
    pub publisher: &'a str,
    pub app_dir: &'a str,
    pub exe_path: &'a str,
    pub uninstaller: &'a str,
    /// 占用空间 (KB)
    pub size_kb: u32,
}

/// 写入卸载信息, 返回是否成功
pub fn register(info: &UninstallInfo) -> bool {
    unsafe {
        let sub = wide(UNINSTALL_KEY);
        let mut h: Hkey = std::ptr::null_mut();
        let mut disp: u32 = 0;
        let rc = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            sub.as_ptr(),
            0,
            std::ptr::null(),
            0,
            KEY_WRITE,
            std::ptr::null_mut(),
            &mut h,
            &mut disp,
        );
        if rc != 0 || h.is_null() {
            return false;
        }

        let date = install_date();
        let ok = set_str(h, "DisplayName", info.display_name)
            & set_str(h, "DisplayVersion", info.version)
            & set_str(h, "Publisher", info.publisher)
            & set_str(h, "InstallLocation", info.app_dir)
            & set_str(h, "DisplayIcon", &format!("{},0", info.exe_path))
            // 主流卸载工具点"卸载"时执行的就是这个
            & set_str(h, "UninstallString", &format!("\"{}\"", info.uninstaller))
            & set_str(
                h,
                "QuietUninstallString",
                &format!("\"{}\" --silent", info.uninstaller),
            )
            & set_str(h, "InstallDate", &date)
            & set_dword(h, "EstimatedSize", info.size_kb)
            // 没有"修改/修复"功能, 让工具别显示这两个按钮
            & set_dword(h, "NoModify", 1)
            & set_dword(h, "NoRepair", 1);

        RegCloseKey(h);
        ok
    }
}

/// 删除卸载信息 (卸载时调用)
pub fn unregister() -> bool {
    unsafe {
        let sub = wide(UNINSTALL_KEY);
        RegDeleteTreeW(HKEY_CURRENT_USER, sub.as_ptr()) == 0
    }
}

fn install_date() -> String {
    // 用系统时间拼 YYYYMMDD, 不引入日期库
    #[link(name = "kernel32")]
    extern "system" {
        fn GetLocalTime(t: *mut SystemTime) -> ();
    }
    #[repr(C)]
    struct SystemTime {
        year: u16,
        month: u16,
        day_of_week: u16,
        day: u16,
        hour: u16,
        minute: u16,
        second: u16,
        ms: u16,
    }
    unsafe {
        let mut t = SystemTime {
            year: 0,
            month: 0,
            day_of_week: 0,
            day: 0,
            hour: 0,
            minute: 0,
            second: 0,
            ms: 0,
        };
        GetLocalTime(&mut t);
        format!("{:04}{:02}{:02}", t.year, t.month, t.day)
    }
}
