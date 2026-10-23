# 开发与验证

[返回 README](../README.md)

## 编译环境

使用 Apple Silicon Mac、macOS 14 或更高版本，以及安装在 `/Applications/Xcode.app` 的完整 Xcode（含 Swift 5.9 或更高版本）。项目使用 Swift Package Manager，无额外 Swift 包依赖。

首次打包需要联网获取独立 Python 3.12 和 `scripts/runtime-requirements.txt` 中的依赖。若安装了 `uv`，脚本会优先使用它获取 Python；否则从 python-build-standalone 下载。识别模型不包含在应用包中。

```bash
git clone https://github.com/zfdang/video-auto-translate.git
cd video-auto-translate
./build_app.sh
open dist/VideoAutoTranslate.app
```

脚本以 Release 模式编译，复制 ASR 脚本、内嵌 Python 环境和图标，生成 `dist/VideoAutoTranslate.app` 并进行 ad-hoc 签名。当前脚本固定使用上述 Xcode 路径及 arm64 构建产物。

仅编译或直接运行源码：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run VideoAutoTranslateApp
```

未打包运行时，识别环境配置见[安装与首次设置](getting-started.md#识别环境恢复)。

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
python3 scripts/test-release-metadata.py
python3 scripts/test-release-notes.py
```

Swift 测试覆盖字幕编辑、校对状态、时间轴、配音缓存、工程保存和导出等。部分测试依赖本地环境：Ollama 实时翻译测试在服务不可达时跳过；Edge TTS 实测需要可用的 Python 运行环境、`edge-tts` 依赖和网络。完整测试通过不代表已完成干净机器安装验收。

ASR 响应与时间戳契约测试可在独立环境运行：

```bash
python3 -m venv .build/asr-test
.build/asr-test/bin/python -m pip install fastapi==0.151.0 uvicorn==0.54.0 python-multipart==0.0.32
.build/asr-test/bin/python scripts/test-asr-results.py
```

## 真实视频时间轴回归

`Tests/VideoAutoTranslateCoreTests/Fixtures/paris-tour-timing.json` 记录了巴黎导览样例的 25 句原文、译文与配音时长。自动回归使用记录值，检查局部时间共享、语境外边界及配音复用，不依赖原视频或在线模型。

本机准备 `Tests/Fme9C5ShSr2fuWQ8_Translated.mp4` 和系统中文音色后，可额外运行真实配音、逐句试听、整片配音和导出验收；样例视频未包含在仓库中。

```bash
VAT_REAL_DUBBING_SAMPLE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RealSampleDubbingTests
```

产物保存到 `dist/timing-validation/`，包括成片、字幕、工程与逐句时间报告。局部语境分析使用测试配置中的 Ollama；不可用时回退到本地分组。

## 技术资料

- [技术架构](architecture.md)：SwiftUI、AVFoundation、AVAudioEngine 与本地推理服务。
- [时间轴算法](translation-timeline-algorithm.md)：局部语境分组与时间共享。
- [历史评审和验收记录](../reviews/README.md)：特定版本的验证证据，不代表当前发布版保证。
- [自动化与发布](workflows.md)：CI、打包与网站部署。
