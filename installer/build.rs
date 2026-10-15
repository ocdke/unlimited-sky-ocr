use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=resources.rc");
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=app.ico");

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let res = out.join("resources.res");

    // 找资源编译器 (Windows SDK 自带)
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(kits) = std::fs::read_dir(r"C:\Program Files (x86)\Windows Kits\10\bin") {
        for e in kits.flatten() {
            candidates.push(e.path().join("x64").join("rc.exe"));
        }
    }
    let rc = candidates
        .into_iter()
        .find(|p| p.exists())
        .or_else(|| which("rc.exe"));

    let rc = match rc {
        Some(p) => p,
        None => {
            println!("cargo:warning=未找到 rc.exe, 安装程序将没有图标和现代控件外观");
            return;
        }
    };

    let status = Command::new(&rc)
        .args(["/nologo", "/fo"])
        .arg(&res)
        .arg("resources.rc")
        .status();
    match status {
        Ok(s) if s.success() => {
            println!("cargo:rustc-link-arg={}", res.display());
        }
        _ => println!("cargo:warning=rc.exe 执行失败, 跳过资源"),
    }
}

fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let p = dir.join(name);
        if p.exists() {
            return Some(p);
        }
    }
    None
}
