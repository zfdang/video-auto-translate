# VideoAutoTranslate (macOS 原生视频自动字幕与语言替换工作站)

<p align="center">
  <img src="assets/app-icon.png" width="128" height="128" alt="VideoAutoTranslate 应用图标">
</p>

专为 **macOS Apple Silicon (ARM64)** 原生打造的原生本地视频字幕制作与多语言配音工作站。

---

## 🌟 核心特性

1. **纯本地视频处理，拒绝臃肿链路**：
   - 不依赖任何外部网络视频下载器（不集成 `yt-dlp`），专注于处理用户本地已有的音视频文件；
   - 彻底摆脱网络反爬、Cookie 失效等问题。
2. **端云协同，本地 Qwen 优先 (Local-First)**：
   - **听（ASR 识别）**：本地芯片级加速的 **Qwen3-ASR** 与 **Qwen3-ForcedAligner** 模型，提取毫秒级逐词时间戳；
   - **译（语义翻译）**：**默认优先连接本地 Ollama (Qwen2.5)**，100% 离线、免费、无隐私顾虑；同时无缝支持在线大模型（如 DeepSeek、OpenAI、Claude 等）作为云端备选；
   - **说（语言替换配音）**：支持纯目标语言配音，或原声压低叠加（包含原人声，尚无人声分离）。在「匹配译文时间轴」中实测当前音色的配音时长，逐句锚定原位置，最多借用后方 0.5 秒空白，并在需要时完成最多 1.15 倍的温和调速。可试听、预览并确认应用；后续生成、试听和导出复用结果，不再调整语速或起始位置。短句保留自然静音，超长句明确提示精简译文或手动调时，配合背景音自动闪避混音（Audio Ducking）。
   - **时间轴边界**：原字幕相邻重叠不超过 30ms 时，仅收紧前一句的可用结束位置，保留原始时间戳和后一句起点；较大重叠或修正后不足 100ms 的片段需人工处理。独立调用匹配而未提供视频时长时，最后一句不向后借时。
3. **灵活的模型存储与一键下载管理**：
   - **多种存储路径支持**：
     - **共享缓存目录**（`~/.cache/huggingface/hub`）：与其他 AI 工具共用，不重复占用磁盘空间；
     - **应用独立目录**（`~/Library/Application Support/VideoAutoTranslate/models`）：隔离独立存储；
     - **自定义目录**：自由指定外置高速 SSD 或 NAS 挂载路径，带实时磁盘可用空间感知。
   - **国内极速下载加速**：内置支持 `hf-mirror.com`及 Hugging Face 官方源，支持在新设备上一键下载 Qwen3-ASR 与 Aligner 模型。
4. **按需延迟托管（Lazy Sidecar）**：
   - 应用启动时不预占显存与端口；
   - 首个转录任务触发时自动静默拉起推理引擎并保持热驻留，后续任务秒级响应；
   - 应用退出时自动释放销毁，不残留任何孤儿进程。
5. **原生剪辑级交互**：
   - 基于时间轴的行内双语字幕即时修改；
   - 词级毫秒智能拆分（`Cmd+B`）与多选相邻字幕合并（`Cmd+J`）；
   - **单句局部增量配音**：修改某一句后可仅重算该句，无需整部视频从头重算；若正常配音超出当前时间，先重新匹配时间轴。

---

## 🏗️ 技术架构

- **UI 界面**：SwiftUI (原生 macOS 14/15 交互，ProMotion 120Hz 流畅刷新)
- **多媒体引擎**：AVFoundation (AVPlayer, AVAssetReader, AVVideoComposition)
- **音频变速引擎**：AVAudioEngine + AVAudioUnitTimePitch (保持音调不变的高性能离线变速渲染)
- **硬件加速编解码**：Apple VideoToolbox (M系列芯片硬编硬解)
- **自然语言处理**：Apple NaturalLanguage.framework (语义边界与断句分析)

---

## 首次运行

应用主体不包含 Python 和模型。在「设置 → ASR 服务」点击「准备识别环境（需联网）」，会在用户应用支持目录创建独立环境。需要已安装 Python 3.10–3.13（建议 3.12，可在界面选择解释器），以及下载依赖和模型所需的网络与数 GB 磁盘空间。完成后在「ASR 模型」下载识别及对齐模型。准备和引擎日志均可在设置中打开；环境准备可取消重试。

翻译需要本地已运行的 Ollama 及模型，或用户配置的在线服务。完成依赖/模型准备后，本地模式可离线运行；尚未完成干净机器安装验收。

## 🚀 编译与运行

### 1. 一键编译并打包为原生 App（推荐）
在项目根目录下执行：
```bash
./build_app.sh
```
该脚本会自动以 Release 模式编译并打包成标准的 macOS 应用，生成于 **`dist/VideoAutoTranslate.app`**。

您可直接通过命令或在 Finder 中双击运行：
```bash
open dist/VideoAutoTranslate.app
```

### 2. 运行工程单元测试
包含对本地 Ollama Qwen2.5 的真实翻译调用测试：
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

---

## 📚 详细设计文档

- 📋 [**产品与功能需求文档 (PRD.md)**](docs/PRD.md)：详细业务场景、功能清单、交互流程与配置规范。
- 🏗️ [**技术架构设计文档 (architecture.md)**](docs/architecture.md)：系统分层架构、数据结构（基于精确 `CMTime`）、核心处理管道与 Swift 原生工程实现细节。
- 🎨 [**UI 与交互设计文档 (ui-design.md)**](docs/ui-design.md)：工作台线框、双语编辑、拆分预览、快捷键与无障碍。
