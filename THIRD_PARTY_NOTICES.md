# 第三方组件与模型许可

本仓库的**源代码**采用 MIT（见 [LICENSE](LICENSE)）。
但运行本软件还需要以下第三方组件和模型，它们各有各的许可证。
**对外分发（尤其是商业分发）之前，请逐项确认。**

---

## 一、推理运行时

| 组件 | 版本 | 许可证 | 说明 |
|---|---|---|---|
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 1.31.0 | MIT | 随安装包分发 `onnxruntime.dll` |
| [Flutter](https://github.com/flutter/flutter) | 3.47.7 | BSD-3-Clause | UI 框架 |
| [Ollama](https://github.com/ollama/ollama) | 0.40.4 | MIT | 本地大模型推理后端（安装时下载，未随包分发） |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | — | MIT | 经 Ollama 间接使用 |

## 二、OCR 模型

| 模型 | 来源 | 许可证 |
|---|---|---|
| PP-OCRv5 mobile det / cls / rec（全部 12 个语种） | [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) / [RapidAI](https://github.com/RapidAI/RapidOCR) | **Apache-2.0** |

Apache-2.0 允许商用与再分发，但需要：

1. 保留版权声明与许可证副本；
2. 若修改过模型文件，需注明。

> 本仓库**不包含**模型文件，需按 README 自行下载。

## 三、翻译模型

| 模型 | 来源 | 许可证 | 注意 |
|---|---|---|---|
| **Hunyuan-MT-7B** | [腾讯混元](https://github.com/Tencent-Hunyuan/Hunyuan-MT) | **腾讯混元社区许可证** | ⚠️ **非 OSI 开源**。对商用、分发、用户规模有条件限制，请阅读原文 |
| OPUS-MT en↔zh（Marian int8） | [Helsinki-NLP](https://huggingface.co/Helsinki-NLP) | **CC-BY-4.0** | 需要**署名** |
| Hunyuan-MT-7B GGUF 量化 | [mradermacher](https://huggingface.co/mradermacher/Hunyuan-MT-7B-GGUF) | 沿用上游许可证 | 量化本身不改变许可证 |

**Hunyuan-MT-7B 是可选项**——用户不勾选「一起安装本地 AI 翻译」时不会下载，
软件仍可用在线 API（腾讯 / DeepSeek 等）或内置离线模型工作。

## 四、在线翻译服务

软件支持接入以下服务，各服务的**服务条款与隐私政策由其各自规定**，
使用者需自行遵守：

| 服务 | 说明 |
|---|---|
| 腾讯交互翻译 | 免密钥接口，非官方 API，可能随时变更 |
| Google Translate | 免密钥接口 |
| DeepL | 需自备 API Key |
| OpenAI 兼容大模型 | DeepSeek / 硅基流动 / 智谱 / Kimi / 通义千问 / OpenAI 等，需自备 Key |

> ⚠️ **隐私提醒**：使用在线翻译时，屏幕上被识别出的文字会发送到对应服务商。
> 处理敏感内容请改用内置离线模型。

## 五、其他

| 组件 | 许可证 |
|---|---|
| [flutter_acrylic](https://pub.dev/packages/flutter_acrylic) | MIT |
| [window_manager](https://pub.dev/packages/window_manager) | MIT |
| [hotkey_manager](https://pub.dev/packages/hotkey_manager) | MIT |
| [screen_retriever](https://pub.dev/packages/screen_retriever) | MIT |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | BSD-3-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause |
| [http](https://pub.dev/packages/http) | BSD-3-Clause |
| [tokenizers](https://github.com/huggingface/tokenizers) (Rust) | Apache-2.0 |
| [image](https://github.com/image-rs/image) (Rust) | MIT / Apache-2.0 |
| [rayon](https://github.com/rayon-rs/rayon) (Rust) | MIT / Apache-2.0 |

---

## 如果你要分发

**可以放心分发**：ONNX Runtime、Flutter、PaddleOCR 模型、各 Dart/Rust 依赖。

**需要额外确认**：

- **Hunyuan-MT-7B** — 先去读一遍腾讯混元社区许可证，确认你的用途在允许范围内。
  不想处理的话，装的时候不勾选它即可，软件功能完整。
- **OPUS-MT 离线模型** — 需要在文档或「关于」里署名 Helsinki-NLP。

**建议做法**：在软件「关于」页面列出上表，附上各许可证原文链接。
