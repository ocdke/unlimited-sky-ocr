//! 原生文件 / 目录选择对话框
//!
//! Flutter 侧要引 file_picker 之类的包, 而这里只要一个标准的 Win32
//! 打开对话框 —— 用系统自带的, 不增加任何依赖。

#![cfg(windows)]

use std::ffi::c_void;

type Hwnd = *mut c_void;

const OFN_READONLY: u32 = 0x0000_0001;
const OFN_EXPLORER: u32 = 0x0008_0000;
const OFN_FILEMUSTEXIST: u32 = 0x0000_1000;
const OFN_PATHMUSTEXIST: u32 = 0x0000_0800;
const OFN_NOCHANGEDIR: u32 = 0x0000_0008;

#[repr(C)]
struct OpenFileNameW {
    l_struct_size: u32,
    hwnd_owner: Hwnd,
    h_instance: *mut c_void,
    lpstr_filter: *const u16,
    lpstr_custom_filter: *mut u16,
    n_max_cust_filter: u32,
    n_filter_index: u32,
    lpstr_file: *mut u16,
    n_max_file: u32,
    lpstr_file_title: *mut u16,
    n_max_file_title: u32,
    lpstr_def_ext: *const u16,
    lpstr_title: *const u16,
    flags: u32,
    n_file_offset: u16,
    n_file_extension: u16,
    lpstr_def_dir: *const u16,
    lpfn_hook: *mut c_void,
    lp_template_name: *const u16,
    pv_reserved: *mut c_void,
    dw_reserved: u32,
    flags_ex: u32,
}

#[repr(C)]
struct BrowseInfoW {
    hwnd_owner: Hwnd,
    pidl_root: *mut c_void,
    psz_display_name: *mut u16,
    lpsz_title: *const u16,
    ul_flags: u32,
    lpfn: *mut c_void,
    l_param: isize,
    i_image: i32,
}

#[link(name = "comdlg32")]
extern "system" {
    fn GetOpenFileNameW(ofn: *mut OpenFileNameW) -> i32;
}

#[link(name = "shell32")]
extern "system" {
    fn SHBrowseForFolderW(bi: *mut BrowseInfoW) -> *mut c_void;
    fn SHGetPathFromIDListW(pidl: *mut c_void, path: *mut u16) -> i32;
}

#[link(name = "ole32")]
extern "system" {
    fn CoTaskMemFree(p: *mut c_void);
}

const BIF_RETURNONLYFSDIRS: u32 = 0x0000_0001;
const BIF_NEWDIALOGSTYLE: u32 = 0x0000_0040;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 把过滤串 (如 "模型文件 (*.gguf)\0*.gguf\0所有文件 (*.*)\0*.*\0") 转成双 NUL 结尾
fn make_filter(specs: &[(&str, &str)]) -> Vec<u16> {
    let mut v = Vec::new();
    for (name, pat) in specs {
        v.extend(name.encode_utf16());
        v.push(0);
        v.extend(pat.encode_utf16());
        v.push(0);
    }
    if v.is_empty() {
        v.extend("所有文件 (*.*)".encode_utf16());
        v.push(0);
        v.extend("*.*".encode_utf16());
        v.push(0);
    }
    v.push(0);
    v
}

/// 弹出"打开文件"对话框。返回选中的完整路径; 取消返回 None。
pub fn pick_file(title: &str, specs: &[(&str, &str)], initial_dir: &str) -> Option<String> {
    unsafe {
        let mut buf = vec![0u16; 4096];
        let filter = make_filter(specs);
        let t = wide(title);
        let d = wide(initial_dir);

        let mut ofn: OpenFileNameW = std::mem::zeroed();
        ofn.l_struct_size = std::mem::size_of::<OpenFileNameW>() as u32;
        ofn.hwnd_owner = std::ptr::null_mut();
        ofn.lpstr_filter = filter.as_ptr();
        ofn.n_filter_index = 1;
        ofn.lpstr_file = buf.as_mut_ptr();
        ofn.n_max_file = buf.len() as u32;
        ofn.lpstr_title = t.as_ptr();
        ofn.lpstr_def_dir = if initial_dir.is_empty() {
            std::ptr::null()
        } else {
            d.as_ptr()
        };
        ofn.flags = OFN_EXPLORER
            | OFN_FILEMUSTEXIST
            | OFN_PATHMUSTEXIST
            | OFN_NOCHANGEDIR
            | OFN_READONLY;

        if GetOpenFileNameW(&mut ofn) == 0 {
            return None;
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(0);
        if len == 0 {
            None
        } else {
            Some(String::from_utf16_lossy(&buf[..len]))
        }
    }
}

/// 弹出"选择文件夹"对话框
pub fn pick_folder(title: &str, initial_dir: &str) -> Option<String> {
    unsafe {
        let t = wide(title);
        let init = wide(initial_dir);
        let mut bi = BrowseInfoW {
            hwnd_owner: std::ptr::null_mut(),
            pidl_root: std::ptr::null_mut(),
            psz_display_name: std::ptr::null_mut(),
            lpsz_title: t.as_ptr(),
            ul_flags: BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE,
            lpfn: std::ptr::null_mut(),
            l_param: if initial_dir.is_empty() {
                0
            } else {
                init.as_ptr() as isize
            },
            i_image: 0,
        };
        let pidl = SHBrowseForFolderW(&mut bi);
        if pidl.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let ok = SHGetPathFromIDListW(pidl, buf.as_mut_ptr());
        CoTaskMemFree(pidl);
        if ok == 0 {
            return None;
        }
        let len = buf.iter().position(|&c| c == 0).unwrap_or(0);
        Some(String::from_utf16_lossy(&buf[..len]))
    }
}
