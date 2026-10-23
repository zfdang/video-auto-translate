# 安装与首次设置

[返回 README](../README.md)

## 运行要求

- macOS 14 或更高版本，Apple Silicon（M 系列芯片）。当前打包流程仅面向 arm64。
- 首次安装运行依赖、下载识别模型和本地翻译模型时需要联网，并预留数 GB 磁盘空间；实际占用取决于所选模型。
- 使用本地翻译时需另行安装并启动 Ollama，下载所需模型。

## 下载应用

从 [GitHub Releases](https://github.com/zfdang/video-auto-translate/releases/latest) 下载 arm64 的 DMG 或 ZIP。打开 DMG 后将应用拖入「应用程序」，或解压 ZIP 后移动应用。`SHA256SUMS.txt` 可用于校验下载文件。

当前构建使用 ad-hoc 签名，未经过 Apple Developer ID 签名和公证。macOS 可能拦截首次打开；确认下载来源后，可在「系统设置 → 隐私与安全性」中允许打开。不要关闭系统的全局安全保护。

发布包包含独立 Python 运行环境，正常使用无需另行安装 Python；识别和对齐模型需要另外下载。干净机器的完整安装流程仍待单独验收。

## 配置识别、翻译与配音

1. 打开「设置 → ASR 服务」，确认内置运行环境就绪。到「ASR 模型」下载识别与对齐模型；已检测到本地模型时可直接使用。可选 Hugging Face 官方源或 `hf-mirror.com`。
2. 在「大语言模型 (LLM)」中连接已启动的 Ollama，选择已下载模型，默认配置为 `qwen2.5:latest`；或填写在线 OpenAI 兼容服务的地址、模型和密钥。
3. 在「语音合成 (TTS)」中选择引擎与音色并试听。Edge TTS 需要联网，无需 API Key；系统 TTS 使用已安装的系统音色。

模型支持以下存储位置：

| 位置 | 路径 |
| --- | --- |
| Hugging Face 共享缓存 | `~/.cache/huggingface/hub` |
| 应用独立目录 | `~/Library/Application Support/VideoAutoTranslate/models` |
| 自定义目录 | 在设置中选择，例如外置 SSD |

全流程离线使用需要提前准备识别与对齐模型、本地 Ollama 模型，以及目标语言的系统音色，并选择系统 TTS。在线翻译和 Edge TTS 始终需要网络。

## 识别环境恢复

直接运行未打包源码，或内置环境不可用时，在「ASR 服务」选择 Python 3.10–3.13（建议 3.12），点击「准备识别环境（需联网）」。应用会在用户应用支持目录中创建独立环境。准备过程可取消重试，环境准备与引擎日志可从设置打开。

随后按 [README 中的工作流程](../README.md#工作流程) 完成视频制作。
