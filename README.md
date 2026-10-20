# VideoAutoTranslate (macOS 原生视频自动字幕与语言替换工作站)

<p align="center">
  <img src="assets/app-icon.png" width="128" height="128" alt="VideoAutoTranslate 应用图标">
</p>

专为 **macOS Apple Silicon (ARM64)** 原生打造的高性能、超轻量（安装包仅约 1.4MB）本地视频字幕制作与多语言配音工作站。

---

## 🌟 核心特性

1. **纯本地视频处理，拒绝臃肿链路**：
   - 不依赖任何外部网络视频下载器（不集成 `yt-dlp`），专注于处理用户本地已有的音视频文件；
   - 彻底摆脱网络反爬、Cookie 失效等问题。
2. **端云协同，本地 Qwen 优先 (Local-First)**：
   - **听（ASR 识别）**：本地芯片级加速的 **Qwen3-ASR** 与 **Qwen3-ForcedAligner** 模型，提取毫秒级逐词时间戳；
   - **译（语义翻译）**：**默认优先连接本地 Ollama (Qwen2.5)**，100% 离线、免费、无隐私顾虑；同时无缝支持在线大模型（如 DeepSeek、OpenAI、Claude 等）作为云端备选；
   - **说（语言替换配音）**：保留原视频环境背景音，新语言配音利用系统级 `AVAudioUnitTimePitch` 智能自适应伸缩对齐原画面，配合背景音自动闪避混音（Audio Ducking）。
3. **灵活的模型存储与一键下载管理**：
   - **多种存储路径支持**：
     - **共享缓存目录**（`~/.cache/huggingface/hub`）：与其他 AI 工具共用，不重复占用磁盘空间；
     - **应用独立目录**（`~/Library/Application Support/VideoAutoTranslate/models`）：隔离独立存储；
     - **自定义目录**：自由指定外置高速 SSD 或 NAS 挂载路径，带实时磁盘可用空间感知。
   - **国内极速下载加速**：内置支持 `hf-mirror.com`、Hugging Face 官方源及魔搭社区，支持在新设备上一键下载 Qwen3-ASR 与 Aligner 模型。
4. **按需延迟托管（Lazy Sidecar）**：
   - 应用启动时不预占显存与端口；
   - 首个转录任务触发时自动静默拉起推理引擎并保持热驻留，后续任务秒级响应；
   - 应用退出时自动释放销毁，不残留任何孤儿进程。
5. **原生剪辑级交互**：
   - 基于时间轴的行内双语字幕即时修改；
   - 词级毫秒智能拆分（`Cmd+B`）与多选相邻字幕合并（`Cmd+J`）；
   - **单句局部增量配音**：修改某一句，0.5 秒内仅重算该句并即时试听，无需整部视频从头重算。

---

## 🏗️ 技术架构

- **UI 界面**：SwiftUI (原生 macOS 14/15 交互，ProMotion 120Hz 流畅刷新)
- **多媒体引擎**：AVFoundation (AVPlayer, AVAssetReader, AVVideoComposition)
- **音频变速引擎**：AVAudioEngine + AVAudioUnitTimePitch (保持音调不变的高性能离线变速渲染)
- **硬件加速编解码**：Apple VideoToolbox (M系列芯片硬编硬解)
- **自然语言处理**：Apple NaturalLanguage.framework (语义边界与断句分析)

---

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
