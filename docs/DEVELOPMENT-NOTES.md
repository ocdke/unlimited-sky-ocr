# DPG — 全屏 OCR 识别翻译

跨平台（**Windows + Android**）的全屏截图 → OCR 识别 → 翻译 → 悬浮译文工具。
核心推理用 **Rust** 编写，UI 用 **Flutter** 单代码库，两端共用同一份识别内核。

---

## 1. 当前状态

| 模块 | 状态 | 说明 |
|---|---|---|
| Rust OCR 内核（检测/方向分类/多语种识别） | ✅ 已完成 | PP-OCRv5 mobile 全语种，CPU 推理 |
| Windows 全屏截屏（GDI） | ✅ 已完成 | 手写 Win32 FFI，BGRA 零编码开销 |
| Flutter 应用（冻结截图 → 框选 → 翻译 → 叠加译文） | ✅ 已完成 | **已端到端实测通过** |
| 在线翻译（腾讯 / 谷歌 / DeepL / OpenAI 兼容 LLM） | ✅ 已完成 | 带 LRU 缓存与批量去重 |
| 全局热键、置顶覆盖窗口、设置持久化 | ✅ 已完成 | |
| Android 截屏与覆盖层代码 | ✅ 已完成 | MediaProjection 前台服务 + 平台通道 |
| Android 交叉编译与 APK 打包 | ✅ **已产出 99.3 MB APK** | arm64-v8a，尚未在真机验证 |
| **离线翻译模型** | ✅ **已完成（中↔英）** | Marian/OPUS-MT int8 ONNX，CPU 推理 |

**两端产物**

| 平台 | 产物 | 体积 | 说明 |
|---|---|---|---|
| Windows | `app\build\windows\x64\runner\Release\dpg_app.exe` | 188 MB / 含离线模型 416 MB | 12 语种 OCR + 中英离线翻译，已端到端实测 |
| Android | `app\build\app\outputs\flutter-apk\app-release.apk` | 99.3 MB | arm64-v8a，5 语种 OCR（离线翻译需重跑打包脚本带入新内核） |

> 离线翻译内核已同时支持两平台（Android 交叉编译已实测通过，`libdpg_core.so` 4.07 MB）。
> 重新执行 `tools\build_android.ps1` 即可把离线翻译打进 APK。

---

## 1.1 实测数据（本机：Ryzen 7 7700 8C/16T，CPU 推理）

**精度**（越接近 1.0 越好，均来自 PP-OCRv5 mobile 模型）

| 测试图 | 尺寸 | 行数 | 识别结果抽样 |
|---|---|---|---|
| `bench/test.png` | 900×260 | 3 | `Hello OCR 123` → **0.986**（与图中文字逐字符一致） |
| `bench/ch_en_num.jpg` | 323×430 | 17 | `强力去污符合国标` **0.989** · `惊喜福利不容错过` **0.995** · `假一赔十` **0.995** · `-40°C深度防冻不结冰` **0.920** |
| `bench/long.jpeg` | 822×4732 | 54 | `建议排查英特尔产品；Mobileye` **0.999** · `回应非法测绘传闻` **0.999** |

**速度**

| 场景 | 行数 | det | cls | rec | 合计 |
|---|---|---|---|---|---|
| 框选小块（典型用法） | 17 | 93 ms | 9 ms | 165 ms | **268 ms** |
| 全屏 2560×1440，最小高度 0 | 95 | 62 ms | 41 ms | 1393 ms | **1503 ms** |
| 全屏 2560×1440，最小高度 18 | 73 | 59 ms | 29 ms | 1187 ms | **1280 ms** |
| 全屏 2560×1440，最小高度 24 | 28 | 61 ms | 14 ms | 333 ms | **404 ms** |
| 长文档 822×4732 | 54 | 31 ms | 21 ms | 1052 ms | **1132 ms** |

**结论与调优要点**

1. **rec 是绝对瓶颈（占 85%+）**。成本 ≈ `总时间步数 × 输出类别数`，
   而中文识别模型有 **18385** 个类别（英文模型只有 **438** 个，快 40 倍）。
   → 明确知道屏幕语言时，**务必在设置里指定语种**，不要用「自动检测」。
2. **行宽比行数更影响速度**：一条 50:1 的长文本行的时间步数是 7:1 短行的 7 倍。
3. **「最小文本高度」是最有效的开关**：调到 24px 后全屏从 1503 ms 降到 404 ms（3.7×），
   代价是放弃屏幕上人眼也读不清的极小文字。
4. 检测阶段只要 60~200 ms，不是瓶颈；`检测长边` 主要影响小字召回而非速度。

---

## 1.3 离线翻译（已实现）

在线接口不通时自动回退到本地模型，实现「在线加速 + 离线兜底」。

**模型**：Helsinki-NLP OPUS-MT（Marian），由 Xenova 转成 ONNX 并做 int8 动态量化。
每个语言对一个目录，约 108 MB：

```
models/translate/en-zh/{config.json, tokenizer.json, encoder.onnx, decoder.onnx}
models/translate/zh-en/{...}
```

**实测**（Ryzen 7 7700，CPU，int8）：

| 方向 | 原文 | 译文 | 耗时 |
|---|---|---|---|
| en→zh | Full screen OCR recognition and translation. | 完整的屏幕OCR识别和翻译。 | 134 ms |
| en→zh | Accuracy and speed are both important for a good user experience. | 准确性和速度对于良好的用户经验都很重要。 | 139 ms |
| zh→en | 全屏OCR识别翻译软件 | Full Screen OCR Recognition Translation | 111 ms |
| zh→en | 识别速度很快，准确率也很高。 | The rate of identification is fast and the accuracy is high. | 165 ms |
| zh→en | 支持中文、英文、日文、韩文等多种语言。 | The Chinese, English, Japanese, Korean and other languages are supported. | 191 ms |

模型加载约 550 ms（按需加载，只在用到某个方向时才载入）。

**实现要点**（这几个是踩过的坑）

1. **ONNX Runtime 每进程只允许一个 Environment**。OCR 引擎和翻译引擎必须共用，
   否则第二个直接抛 `only one environment is allowed per process`。
   已改成进程级 `OnceLock<Environment>` 单例。
2. **decoder 是 `decoder_model_merged` 结构**：通过 `use_cache_branch` 在"首次前向"
   与"增量前向"间切换。首次前向时**所有** `past_key_values.*`（含交叉注意力）
   都必须是 0 长度，K/V 由模型内部算出。
3. **增量分支下 `present.*.encoder.*` 返回的是空张量**。交叉注意力的 K/V 在整段解码中
   恒定不变，正确做法是首次前向取一次后固化复用 —— 每步回读会拿到 0 元素并崩在
   `Tensor::from_array` 上。
4. **分词器不引入 C 依赖**：OPUS-MT 的 `tokenizer.json` 用 SentencePiece `Precompiled`
   归一化，在 `tokenizers` crate 里需要 oniguruma（C 库）。这里改成
   `default-features = false` + 纯 Rust 的 `fancy-regex`，并在加载时把归一化替换成
   等价的 NFKC（对 `nmt_nfkc` 差异仅在少量标点映射），Windows 与 Android 都不需要额外 C 工具链。
5. **源语言从 OCR 结果推断**：OCR 每行都带回实际使用的识别模型（ch/en/korean/...），
   取出现最多的那个作为离线翻译的源语言，不需要用户手选。

**扩展更多语言对**：下载对应方向的模型放进 `models/translate/<src>-<tgt>/` 即可，
引擎启动时自动扫描。例如日→英就是 `ja-en`。

---



选型时实测了各免密钥接口在本机的连通性：

| 接口 | 结果 | 说明 |
|---|---|---|
| `edge.microsoft.com/translate/auth`（必应免密钥） | ❌ **HTTP 404** | 该端点已失效，早期方案全部不可用 |
| `fanyi.youdao.com/translate`（有道旧免密钥接口） | ❌ 返回 SPA 页面 | 已下线 |
| **`transmart.qq.com/api/imt`（腾讯交互翻译）** | ✅ **可用** | **免密钥、国内直连、支持一次多段、双向，实测 ~180 ms** |
| `translate.googleapis.com`（谷歌 gtx） | ✅ 可用 | 国内**必须走代理**，直连超时 |
| `api.openai.com` / `api-free.deepl.com` | ✅ 可达 | 需要 API Key |

因此**默认引擎是腾讯交互翻译**。另外注意：**Dart 的 `HttpClient` 默认不读取系统代理**，
所以谷歌 / OpenAI / DeepL 在设置里必须显式填写「HTTP 代理」（如 `127.0.0.1:7897`），
否则会静默超时——这是很多同类工具踩过的坑，已在设置页给出提示。

---



## 2. 目录结构

```
E:\dpg
├── core/                     Rust 推理内核
│   ├── src/
│   │   ├── det.rs            DB 文本检测（含两种预处理预设）
│   │   ├── rec.rs            CTC 文本识别（批处理 + 动态宽度）
│   │   ├── cls.rs            文本行方向分类（0°/180°）
│   │   ├── contours.rs       连通域提取（替代 cv2.findContours）
│   │   ├── geometry.rs       凸包 / 最小外接旋转矩形 / unclip
│   │   ├── image_utils.rs    双线性缩放（对齐 OpenCV）/ 仿射裁切
│   │   ├── engine.rs         引擎编排 + 多语种自动重试
│   │   ├── capture_win.rs    Windows GDI 截屏
│   │   ├── ffi.rs            C ABI（供 Flutter 调用）
│   │   └── bin/dpg_cli.rs    命令行基准测试工具
│   └── Cargo.toml
├── app/                      Flutter 应用（Windows + Android）
│   └── lib/
│       ├── core/native.dart         Dart FFI 绑定
│       ├── core/ocr_service.dart    引擎生命周期（isolate 隔离）
│       ├── core/translator.dart     在线翻译引擎
│       ├── ui/home_page.dart        控制面板
│       ├── ui/capture_overlay.dart  全屏框选 + 译文叠加层
│       └── app_controller.dart      状态机与流程
├── models/                   模型（由脚本下载，141 MB）
│   ├── ocr/PP-OCRv5/{det,cls,rec}/
│   └── bench/                基准测试图片
├── runtime/bin/onnxruntime.dll
└── tools/
    ├── download_models.ps1   下载模型（ModelScope 国内直连）
    ├── build_windows.ps1     一键构建打包
    └── env.ps1               开发环境变量
```

---

## 3. 环境准备

已在本机完成安装的组件：

| 组件 | 版本 | 位置 |
|---|---|---|
| Flutter | 3.47.7 (Dart 3.13.5) | `E:\dpg\.tools\flutter` |
| Rust | 1.99.0 (MSVC) | `%USERPROFILE%\.cargo` |
| VS Build Tools | 2022 (MSVC 14.44 + Win SDK 26100) | `D:\VSBuildTools` |
| ONNX Runtime | 1.31.0 | `E:\dpg\runtime\bin\onnxruntime.dll` |
| 模型 | PP-OCRv5 mobile ×12 语种 | `E:\dpg\models` |

新机器上从零搭建：

```powershell
# 1) 模型（约 141 MB，ModelScope 国内直连）
powershell -File tools\download_models.ps1

# 2) 内核 + 应用
pwsh -File tools\build_windows.ps1
```

---

## 4. 使用方式

启动 `app\build\windows\x64\runner\Release\dpg_app.exe` 后：

| 热键 | 功能 |
|---|---|
| `Ctrl+Alt+Q` | **框选翻译** — 冻结屏幕，拖拽选择区域，只识别该区域 |
| `Ctrl+Alt+W` | **全屏翻译** — 识别整个屏幕，把译文贴在原文位置 |
| `Ctrl+Alt+E` | 唤回控制面板 / 退出覆盖层 |
| `Esc` | 退出覆盖层 |

工作流程：按热键 → 应用先隐藏自身并截取整块虚拟桌面 → 把截图当作冻结背景显示 →
（框选模式下）拖拽选择 → Rust 内核 OCR → 在线翻译 → 在原文位置叠加译文标签。

> 截图前会隐藏窗口并等待 150 ms，避免把工具自己的界面拍进去。

---

## 5. 关键实现细节（精度相关）

这些参数是从 PaddleOCR / RapidOCR 官方源码逐项核对后落地的，**不是猜的**：

### 5.1 检测（DB）
模型自带 `inference.yml` 与 RapidOCR 实现存在差异，两种都做成了预设：

| 参数 | `official` 预设（默认） | `rapid` 预设 |
|---|---|---|
| 缩放 | `resize_long=960`，尺寸**向上对齐到 128** | `limit_side=736 / limit_type=min`，四舍五入到 32 |
| 归一化均值 | ImageNet `[0.485,0.456,0.406]` | `[0.5,0.5,0.5]` |
| box_thresh | 0.6 | 0.5 |
| unclip_ratio | 1.5 | 1.6 |
| 2×2 膨胀 | 否 | 是 |

两者都使用 **BGR 通道顺序**（`DecodeImage.img_mode: BGR`，且 `NormalizeImage` 不做通道交换）。

后处理链路：`thresh=0.3` → 连通域 → `minAreaRect` → `box_score_fast` → 框得分过滤
→ `unclip`（`distance = area × ratio / perimeter`，矩形外扩等价于长宽各加 `2d`）
→ 角点排序 → 由概率图尺寸线性映射回原图。

### 5.2 识别（CTC）
完全对齐 RapidOCR `TextRecognizer.resize_norm_img`：

* 输入高度 48，宽度 `= int(48 × max(320/48, 批内最大宽高比))`
* `resized_w = min(img_width, ceil(48 × w/h))`，右侧补 0
* **BGR 顺序**，归一化 `(x/255 − 0.5)/0.5` 即 `x/127.5 − 1`
* 输出已含 softmax → 直接 `argmax` 取类别、`max` 取置信度，**无需再算 softmax**
* CTC 折叠 = “与前一个原始类别不同且非 blank(0)”

**字典类别数自动探测**：RapidOCR 会在字典末尾追加一个空格类别。解析 ONNX
`metadata_props` 实测确认了这一点——**12 个模型的类别数全部等于「字典条目 + 2」**：

| 模型 | 输出类别数 | 字典条目 | 差值 |
|---|---|---|---|
| ch | 18385 | 18383 | +2 |
| en | 438 | 436 | +2 |
| korean | 11947 | 11945 | +2 |
| arabic | 749 | 747 | +2 |
| …其余 8 个 | — | — | 全部 +2 |

即排布为 `['blank', *字典, ' ']`。代码会**先探测模型真实类别数，再选择匹配的字典**：
优先用模型 `metadata_props["character"]` 里内嵌的字典，不匹配则回退到 `.txt` 文件，
两者都不匹配就直接报错——避免字典错位导致整行乱码。

### 5.3 方向分类
`inference.yml` 写的是 80×160 + ImageNet 归一化，RapidOCR 实现用的是等比缩放 + 右侧补零 +
`(x/127.5−1)`。两种都保留为预设，默认走 RapidOCR 变体。

### 5.4 竖排文本
裁切后若 `高/宽 ≥ 1.5`，按 `np.rot90`（逆时针 90°）旋转，与参考实现一致。

---

## 6. 速度优化

* **批处理 + 按宽高比排序**：识别阶段先按 `w/h` 排序再分批，同批内宽度接近，
  避免为一条长文本行把整批 padding 到很宽。
* **动态批宽**：批内宽度取 `max(320, 48×批内最大宽高比)`，短文本行不浪费算力。
* **连通域前置过滤**：面积过小的连通域直接跳过，减少最小外接矩形的计算量。
* **凸包下采样**：单个连通域超过 4000 像素时按步长采样，控制旋转卡壳开销。
* **多语种按需重试**：`auto` 模式先跑中文模型（覆盖中/英/日），只有置信度低于阈值的行
  才用其他语种模型重跑，且一次批量完成。默认候选为 `latin / korean / cyrillic`。
* **翻译侧**：同屏重复文本去重、LRU 缓存、批量请求（必应/DeepL/LLM 支持一次多段）。
* **isolate 隔离**：OCR 在独立 isolate 中执行，UI 不会卡顿。
* **截屏零编码**：GDI 直接产出 BGRA，不经过 PNG 编解码。

可调参数（控制面板内实时生效）：

| 参数 | 默认 | 作用 |
|---|---|---|
| 检测长边 | 960 | 调小主要影响小字召回，对速度影响有限 |
| **最小文本高度** | 0 | **最有效的提速开关**，调到 20~24 可快 3~4 倍 |
| 最大识别行数 | 0 | 约束全屏场景最坏延迟 |
| 文本置信度下限 | 0.5 | 调高可去噪，调低保留更多弱文本 |
| 多语种自动重试 | 开 | 关闭可提速（单一语种场景建议关闭） |
| 识别语言 | 自动检测 | **指定语种可大幅提速**（英文 438 类 vs 中文 18385 类） |
| 标签字号 / 不透明度 | 16 / 0.92 | 显示效果 |

---

## 7. 后续工作

### 7.1 离线翻译（接口已预留）
`app/lib/core/translator.dart` 中的 `Translator` 抽象接口即插即用。
计划路径：MarianMT（`opus-mt-zh-en` 等）或 NLLB-200-distilled-600M 的 int8 ONNX 版本，
用现有的 Rust 内核（已集成 ONNX Runtime）做推理；需要额外补一个 SentencePiece 分词器。
接入后按「离线兜底 + 在线加速」策略调度：无网络或在线超时时自动回落。

### 7.3 Android 端

**关键设计：覆盖层复用 Flutter UI，不需要系统级悬浮窗。**

Windows 端的覆盖层本质是一个「铺满屏幕、显示冻结截图作为背景」的普通窗口。
在 Android 上，一个全屏 Activity 就能做同样的事 —— 因此**无需
`SYSTEM_ALERT_WINDOW` 权限、无需 `TYPE_APPLICATION_OVERLAY` 悬浮窗、无需把
渲染逻辑用 Android Canvas 重写一遍**。`CaptureOverlay` 这个 widget 两端完全共用。

各层实现对照：

| 能力 | Windows | Android |
|---|---|---|
| 截屏 | Rust GDI `BitBlt` | `MediaProjection` + `VirtualDisplay` + `ImageReader` |
| 像素格式 | BGRA | RGBA（内核新增 `dpg_ocr_rgba` 入口） |
| 避免拍到自己 | `hide()` + 移出屏幕 + 等合成 | `moveTaskToBack()` → 截图 → 拉回前台 |
| 覆盖层 | 无边框置顶窗口 | 全屏 Activity（同一套 Flutter widget） |
| 触发 | 全局热键 | 应用内按钮（后续可加快捷方式/通知栏磁贴） |
| 权限 | 无 | `FOREGROUND_SERVICE_MEDIA_PROJECTION`（Android 14+ 强制） |

Android 14 (API 34) 起 `getMediaProjection()` 要求调用方已有
`foregroundServiceType="mediaProjection"` 的前台服务，否则直接抛
`SecurityException`——这是最容易踩的坑，已在 `MediaProjectionService` 中处理。

模型以**原生 assets** 打包（`android/app/src/main/assets/models`），
首次启动由 Kotlin 递归解包到 `filesDir`，不走 Flutter 的 asset 机制，
这样 Windows 构建不必也跟着打包一份模型。

构建：

```powershell
powershell -File tools\build_android.ps1                    # arm64-v8a
powershell -File tools\build_android.ps1 -BundleAllModels   # 带全部 12 语种
powershell -File tools\build_android.ps1 -Abi armeabi-v7a   # 旧设备
```

需要先准备（本机已装）：
JDK 17 (`C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot`)、
Android SDK (`E:\dpg\.tools\android\sdk`)、NDK r28c。

**踩过的坑（都已解决，记下来省时间）**

1. **`.ps1` 文件必须存成 UTF-8 with BOM**。Windows PowerShell 5.1 会把无 BOM 的脚本
   按 ANSI(GBK) 读，中文变成 mojibake 后可能吃掉引号，报出与真实原因完全无关的语法错误
   （本次表现为 `New-Item : Path 为 null`）。用编辑器改完脚本后记得重存 BOM。
2. **链接器要用 `core\.cargo\config.toml` 指定**，不要依赖
   `CARGO_TARGET_<T>_LINKER` 环境变量——在本机 PowerShell 下该变量不生效，会报
   `linker 'cc' not found`。
3. **Gradle 发行包走腾讯镜像**：`services.gradle.org` 的 307 跳转在本地代理下会 SSL 失败，
   改成 `https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip` 后 1.87 MB/s。
4. **Gradle 依赖走阿里云镜像**（已写入 `android/settings.gradle.kts`）。
5. **关闭 Kotlin 增量编译**（已写入 `android/gradle.properties`）：Windows 上偶发
   `Could not close incremental caches ... class-fq-name-to-source.tab`。
6. **模型 assets 必须保持 `ocr\PP-OCRv5\` 这层结构**，
   才能与 Rust 侧 `EngineConfig::standard` 的目录约定一致。


### 7.4 进一步提速（按收益排序）
1. **按语种选择模型**：把「自动检测」改为先跑英文（438 类）等小字典模型，
   低置信度行再用中文模型复认——对英文屏幕可快一个数量级。
2. **只重认变化区域**：连续翻译时缓存上一帧的识别结果，只对像素有变化的框重新推理。
3. **检测输入降采样 + ROI 复用**：全屏模式下先在小图上定位文本行，再按需放大识别。
4. **量化模型**：把 rec 模型做 int8 动态量化，预计再快 1.5~2 倍（需重新验证精度）。

### 7.3 Android 端
内核已是纯 Rust + ONNX Runtime，交叉编译只需补 target 与 ORT 的 Android `.so`。
UI 层还需：
* `MediaProjection` 申请录屏权限并取帧（替代 GDI 截屏）
* `TYPE_APPLICATION_OVERLAY` 悬浮窗渲染译文（替代 Windows 置顶窗口）
* 前台 Service 保活 + 快捷方式触发

### 7.4 其他
* 实时连续翻译模式（定时截屏 + 差分检测变化区域，只重识别变化部分）
* 竖排日文/中文的语序还原
* 多显示器分别框选

---

## 8. 已知限制

* 首次启动需要加载 12 个识别模型，约 1.3 秒（未做模型懒加载）。
* 全屏模式在密集桌面（95+ 行小字）下约 1.5 秒；建议调高「最小文本高度」
  或改用框选模式（典型 250 ms）。
* 覆盖窗口与截图的坐标映射使用整块虚拟桌面 + 统一缩放比，
  多显示器混合缩放（如 150% + 100%）下可能有偏差。
* 模型与运行时合计约 186 MB，尚未做裁剪（可按需只保留用到的语种模型，
  例如只留 ch+en 可省约 100 MB）。
* 谷歌 / OpenAI / DeepL 在 Dart 侧不走系统代理，必须在设置里手填代理地址。
* 腾讯交互翻译为公开接口，官方未承诺长期可用；DeepL / OpenAI 等 Key 型接口
  作为稳定备选。
