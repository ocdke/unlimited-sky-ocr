# 贡献指南 / Contributing

[English below](#english)

---

## 中文

感谢你有兴趣参与。这个项目是 Windows 桌面工具，改动最好**先在真机上跑起来再提 PR**。

### 开发环境

| 组件 | 版本 |
|---|---|
| Rust | 1.99+（MSVC 工具链） |
| Flutter | 3.47+ |
| Visual Studio Build Tools | 含「使用 C++ 的桌面开发」+ Windows SDK |
| ONNX Runtime | 1.31.0 (win-x64) |

资源的放置见 [README 的「资源准备」](README.md#资源准备)。

### 目录职责

```
core/       Rust 推理内核 —— 抓屏、OCR、离线翻译。导出 C ABI 给 Dart 调用
app/        Flutter 界面。所有界面逻辑都在 app/lib
installer/  Rust 安装程序（原生 Win32 GUI，不依赖 Inno Setup / NSIS）
tools/      PowerShell 构建与打包脚本
docs/       截图与开发笔记
```

**改内核之后必须同步 DLL**，否则 Dart 侧会因为找不到新符号而静默降级：

```powershell
cd core; cargo build --release
copy target\release\dpg_core.dll ..\app\build\windows\x64\runner\Release\
```

这个坑踩过好几次，`tools\build_windows.ps1` 会自动做，但手工构建时容易忘。

### 提交前

```powershell
cd core; cargo test --release           # Rust 单测
cd ..\app; flutter analyze              # 静态检查
flutter test                            # Dart 单测
```

### 代码风格

- **注释写「为什么」，不写「是什么」。** 这个项目里值得注释的地方，几乎都是
  「某个 API 有反直觉的行为，所以必须绕开」这类信息。
  比如 `ui.rs` 里那段关于 `2>&1` 把原生命令 stderr 变成 ErrorRecord 的注释 ——
  正是它解释了为什么要先把 `$ErrorActionPreference` 降回 Continue。
- **中文注释**是这个项目的主流，保持即可。
- **不要引入新的重型依赖**。安装程序刻意只用 `serde`；文件对话框是手写的
  Win32 FFI，就是为了避免拖进 `file_picker` 之类。

### 已知的坑（改之前先看一眼）

| 位置 | 坑 |
|---|---|
| `app/windows/runner/main.cpp`、`Runner.rc` | **必须存成 UTF-8 with BOM**，否则 MSVC 报 C2001 |
| `tools/*.ps1` | **必须 UTF-8 with BOM**，否则 PS 5.1 按 GBK 读，中文全乱 |
| `core/src/platform.rs` | `CreateMutexW` 成功时**不清零** last-error，判断单实例前要先 `SetLastError(0)` |
| `core/src/platform.rs` | `WaitForSingleObject` 需要 `SYNCHRONIZE` 权限，只给 `EVENT_MODIFY_STATE` 会直接失败 |
| `installer/src/ai.rs` | PowerShell 里 `2>&1` 会把原生命令 stderr 包成 ErrorRecord，`$ErrorActionPreference='Stop'` 下会抛异常 |
| `installer/src/ai.rs` | 判断 `ollama create` 是否成功**不能看退出码**，要看 `ollama list` 的结果 |
| `core/src/rec.rs` | rec 成本 ≈ 总时间步数 × 输出类别数；`ch` 模型有 18385 类，是主要开销 |
| `app/lib/core/frame_diff.dart` | 动态壁纸会让像素一直变，必须用文字区域掩码过滤 |

### PR 建议

1. 一个 PR 只做一件事
2. 说明**验证方式**（跑过什么、看到什么结果）
3. 性能相关改动请附前后对比数字
4. UI 改动请附截图

### 报 Bug

请附上日志：`%LOCALAPPDATA%\UnlimitedSkyOCR\dpg.log`

如果是识别/翻译不准，还请说明：
- 识别语言设置（自动 / 指定语种）
- 降噪强度
- 翻译引擎
- 原始文字长什么样（截图最好）

---

## English

Thanks for your interest. This is a Windows desktop tool — please **actually run
your change on a real machine before opening a PR**.

### Development environment

| Component | Version |
|---|---|
| Rust | 1.99+ (MSVC toolchain) |
| Flutter | 3.47+ |
| Visual Studio Build Tools | "Desktop development with C++" + Windows SDK |
| ONNX Runtime | 1.31.0 (win-x64) |

See [Resource setup](README.md#resource-setup) for where the models and runtime go.

### Layout

```
core/      Rust inference core — capture, OCR, offline translation. Exposes a C ABI to Dart
app/       Flutter UI. All UI logic lives in app/lib
installer/ Rust installer (raw Win32 GUI, no Inno Setup / NSIS)
tools/     PowerShell build and packaging scripts
docs/      Screenshots and development notes
```

**After changing the core you must copy the DLL**, or the Dart side will silently
fall back because the new symbol can't be found:

```powershell
cd core; cargo build --release
copy target\release\dpg_core.dll ..\app\build\windows\x64\runner\Release\
```

`tools\build_windows.ps1` does this for you; manual builds tend to forget it.

### Before submitting

```powershell
cd core; cargo test --release           # Rust unit tests
cd ..\app; flutter analyze              # static analysis
flutter test                            # Dart unit tests
```

### Style

- **Comment the *why*, not the *what*.** Almost every comment worth writing in
  this project explains a counter-intuitive API behaviour that had to be worked
  around — for example the note in `ui.rs` about `2>&1` turning a native
  command's stderr into an `ErrorRecord`, which is why
  `$ErrorActionPreference` has to be lowered to `Continue` first.
- **Chinese comments** are the norm here; keep them that way.
- **Don't add heavy dependencies.** The installer deliberately depends only on
  `serde`; the file dialogs are hand-written Win32 FFI specifically to avoid
  pulling in `file_picker` and friends.

### Known traps

| Where | Trap |
|---|---|
| `app/windows/runner/main.cpp`, `Runner.rc` | **Must be UTF-8 with BOM**, or MSVC fails with C2001 |
| `tools/*.ps1` | **Must be UTF-8 with BOM**, or PowerShell 5.1 reads them as GBK |
| `core/src/platform.rs` | `CreateMutexW` does **not** clear last-error on success — call `SetLastError(0)` first |
| `core/src/platform.rs` | `WaitForSingleObject` needs `SYNCHRONIZE`; `EVENT_MODIFY_STATE` alone fails |
| `installer/src/ai.rs` | In PowerShell, `2>&1` wraps native stderr into an ErrorRecord, which throws under `$ErrorActionPreference='Stop'` |
| `installer/src/ai.rs` | Don't trust `ollama create`'s exit code — check `ollama list` instead |
| `core/src/rec.rs` | Recognition cost ≈ timesteps × output classes; the `ch` model has 18385 classes |
| `app/lib/core/frame_diff.dart` | Animated wallpapers change pixels forever; mask by text regions |

### Pull requests

1. One thing per PR
2. Say **how you verified it**
3. Performance changes need before/after numbers
4. UI changes need a screenshot

### Reporting bugs

Please attach `%LOCALAPPDATA%\UnlimitedSkyOCR\dpg.log`.

For recognition or translation accuracy issues, also mention:

- OCR language setting (auto / explicit)
- Noise filter level
- Translation engine
- What the source text actually looked like (a screenshot is best)
