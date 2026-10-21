# 用户体验、功能与 UI 评审验证记录

对应[主报告](2026-10-21-ux-functional-review.md)。日期 2026-10-21（Asia/Singapore），基线 `b33597ce9127683882c345d5f07a19e83fbebdc7`。

## 范围与方法

| 范围 | 审阅内容 | 验证方法 |
| --- | --- | --- |
| App（9 个 Swift 文件） | 工作流、字幕列表/行、预览、帮助、设置、导出、窗口生命周期及 AppState | 追踪全部操作入口与状态；从基线编译真实 SwiftUI 样例；针对关键控制流编译 AppState probe |
| Core Models/Manager | 文本、CMTime、词映射、缓存、持久化、文件身份、拆分/合并/重配音 | 正常测试＋首词、Unicode、译文分配、序列化反例 |
| Core ASR | sidecar 生命周期、路径/依赖、模型扫描下载、请求解析、断句与模拟引擎 | 静态审阅；假推理验证无对齐响应；未下载/运行真实识别模型 |
| Core LLM | HTTP 客户端、模型探测/拉取、翻译容错、分句、时间匹配 | 本机现有测试＋本地确定性 HTTP 响应，验证丢项、序号、改词、重复及迟到响应 |
| Core Audio/TTS/Exporter | 提取、变速、系统语音、混音、字幕导出与视频压制 | 现有真实 TTS/样本压制测试；追踪实际缓存、跳过、截取及错误处理 |
| Tests | 两份 Swift 测试（含新增 UserJourneySimulator）、Python E2E | 实际运行 XCTest；区分复制的模拟控制器与真实 AppState/GUI |
| 构建发布 | Package.swift、build_app.sh、图标脚本、发布元数据/说明/打包及两个 workflow | Release scratch 构建；发布脚本测试；Shell 语法检查；不执行发布和打包覆盖 |
| 设计与说明 | README、PRD、architecture、ui-design | 按用户流程比对实际能力，明确 bug 与尚未实现能力的边界 |

生产 Swift 共 36 个（App 9、Core 27）。报告里的“全面”指当前仓库范围的系统审阅，不代表所有设备、格式、输入和真实模型组合都已动态覆盖。

## 运行环境与现有检查

macOS 15.8.1、Apple Silicon。本次构建和测试显式使用 `/Applications/Xcode.app/Contents/Developer` 的 Swift 6.2.4；默认命令行工具链为 6.2.3，两者不混淆。

| 检查 | 结果 | 保存记录 |
| --- | --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 25 个 XCTest，0 失败，27.550 秒；构建 9.17 秒 | [swift-tests.log](evidence/ux-2026-10-21/swift-tests.log) |
| `swift build -c release --scratch-path /tmp/vat-comprehensive-build`（同上 DEVELOPER_DIR） | 成功，29.95 秒；AudioExtractor 的非 Sendable 捕获警告仍在 | [release-build.log](evidence/ux-2026-10-21/release-build.log) |
| `python3 scripts/test-release-metadata.py` | 通过版本编号、Singapore 日期及浅克隆边界检查 | [release-metadata.log](evidence/ux-2026-10-21/release-metadata.log) |
| `python3 scripts/test-release-notes.py` | 9 个测试通过 | [release-notes.log](evidence/ux-2026-10-21/release-notes.log) |
| Python AST、Shell 语法 | scripts 下 Python 语法、四份 Shell 脚本检查通过 | AST 结果含在 probe；Shell 仅解析、不执行构建/打包 |

保存的构建/测试日志将仓库绝对路径替换为 `<repo>`，并清除行尾空白；诊断内容和结果不变。

XCTest 中本机 Ollama 返回“人工智能正在改变世界。”，样本视频字幕压制实际执行约 12.631 秒，UserJourney 的系统 TTS 文件成功生成。UserJourney 的 ASR 只探测服务后直接填入样例，翻译直接赋值，最后导出 SRT；不能据此称为真实识别/翻译/成片完整 GUI E2E。

## 确定性反例

使用 [run_review_probes.py](repro/ux-2026-10-21/run_review_probes.py) 编译 [ReviewProbe.swift](repro/ux-2026-10-21/ReviewProbe.swift)，保留实际 Core 和 AppState 逻辑。输出为 [probes.jsonl](evidence/ux-2026-10-21/probes.jsonl)，共 1 条基线记录、10 条 probe 记录。一个 probe 可含多条观测；runner 完整退出不意味着产品通过。

| Probe | 实际结果 | 对应报告 |
| --- | --- | --- |
| undo | Before→After→undo 后仍为 After | U02 |
| load-undo | 加载工程 B 后撤销，字幕变回 Project A | U02；测试文件仅临时创建 |
| core / 首词 | Hello world third fourth 在 index2 切成 Hello world third / fourth | U07 |
| core / Unicode | 😀a bc 的 b 前 UTF16 光标=4，切成 😀a b / c | U07；界面把该 loc 直接传 Character 索引的路径为静态确认 |
| core / 有界时轴 | 1 秒内 5 行匹配后，后三行均为 0.75–1.0，出现 3 次重叠 | U06 |
| core / 无媒体上限 | 4–5 秒的末句、长译文，结束变为 6.2 秒 | U06；界面确实未传 videoDuration |
| core / 拆分译文 | 整段人工译文留左，右空 | U12 |
| core / 导出 | 仅译文未翻译行输出 [待翻译]；validate 同时报 valid=1、untranslated=1 | U16 |
| core / 凭据 | 工程序列化未包含假 sentinel key | 已修复旧 FU04 的有效路径 |
| translation | id=0/1 两条只写入第一句；仅返回首句 UUID 也正常成功 | U13 |
| segment-content | 输入 Hello/world，输出原文 Goodbye moon，词 token 仍为 Hello/world | U05 |
| segment-stale | A 分句等待时打开 B，B 被写入 Project A，译文为空 | U03、U05 |
| align-stale | A 匹配等待时打开 B，B 被写入 Project A 及其人工译文，并显示成功 | U03 |
| duplicate-timeline | 相同 id=0 两次，子进程 fatalError、退出 -5 | U04；主评审进程未崩溃，禁用 core dump |
| asr-no-alignment | 正常 text、无词/片段时间，返回整句 start=0、end=5 | U09；替换实际模型，不是质量测试 |
| python-syntax | 所有 scripts/*.py 可解析 | 语法不等同于路由/依赖验证 |

### 复现入口

在该基线 checkout 根目录执行，macOS/Xcode 必需：

```sh
/path/to/python reviews/repro/ux-2026-10-21/run_review_probes.py
```

Python 需要现成的 fastapi、uvicorn、python-multipart；本轮使用已有外部 venv 的 Python 3.12.13，不安装依赖。Core 编译会使用当前 checkout 的 `.build`；副本和执行文件在临时目录。结果第一行输出 HEAD，未来复现需核对；对其他基线不能直接套用本次结论。

AppState 临时源码只移除 init 中的 sidecar/Ollama/ASR 三个探测 await，避免测试干扰本机服务。未改取消、回调、工程状态、撤销、分句和匹配逻辑。假服务只监听随机 loopback 端口；不访问付费 API。

Python ASR 验证把模型查找和生成替换为假对象，不读取音频、不加载权重；调用真实 run_local_transcription 的无对齐返回分支。路径 `/review/nonexistent-audio` 是占位输入，不指向用户素材。

## GUI 样例及操作记录

[build_review_app.py](repro/ux-2026-10-21/build_review_app.py) 从基线 App 全部源码和 Core 对象编译临时 `VideoReview.app`。只做两处可审计调整：移除初始化服务探测；在 MainView init 注入 20 秒合成视频和 8 行双语样例，配置为不可连接的 loopback 假服务。所有控件布局、业务函数、搜索/合并闭包、导出和设置代码保持原样。

脚本需要 ffmpeg，只生成临时媒体；不修改用户配置、生产源码或 dist。通过原生应用 UI 操作并捕获窗口，结束后已退出该临时应用。没有操作其他应用内容，也没有向外部服务发送样例。

| 证据 | 界面状态与观测 |
| --- | --- |
| [01-main.png](evidence/ux-2026-10-21/01-main.png) · [AX](evidence/ux-2026-10-21/01-main.ax.txt) | 初始 8 行，仅 3 行有译文，翻译已出现绿勾；默认窗口顶部左右内容被裁切，列表工具栏缩略，长句单行截断。 |
| [02-filter-before-merge.png](evidence/ux-2026-10-21/02-filter-before-merge.png) · [AX](evidence/ux-2026-10-21/02-filter-before-merge.ax.txt) | 搜索 Hello everyone，仅原始第 1、3 行可见，显示重编号 #1/#2，第一行仍有“向下合并”。 |
| [03-filter-hidden-merge.png](evidence/ux-2026-10-21/03-filter-hidden-merge.png) · [AX](evidence/ux-2026-10-21/03-filter-hidden-merge.ax.txt) | 合并后第一行新增隐藏行 This line has no translation yet.，终点从 1.8 变 3.8；原第 3 行仍单独存在。 |
| [04-search-empty.png](evidence/ux-2026-10-21/04-search-empty.png) | 改搜 zzzz-no-match-review，仍有工程字幕，却提示“尚未提取字幕”。 |
| [05-export.png](evidence/ux-2026-10-21/05-export.png) · [AX](evidence/ux-2026-10-21/05-export.ax.txt) | 未生成全片配音，选择目标语言导出；摘要却是“保留原音轨”。关闭没有禁用；本轮没有发起成片导出。 |
| [06-language-settings.png](evidence/ux-2026-10-21/06-language-settings.png) | 默认简体中文被显示为自定义语言，API Key 为空；最大并发控件存在但无执行引用。 |

过程中还执行过一次样例单句译文试听，生成了系统 TTS 临时文件。它不等于全片配音，但工具栏当时已出现配音完成勾；U20 的代码依据是 contains 判断。本次没有故意制造 TTS 磁盘错误，也没有测试真实并发抢播。

## 证据限制及完成检查

- U10、U14、U15、U21、U23、U24 等含静态推断，主报告未把它们写成已经观测到的真实长片故障。每项均提供应补的用户验收场景。
- 未做真实 ASR 模型质量、干净 Mac 安装、完整听感、中文输入法组词、VoiceOver 全流程或所有媒体格式测试；没有测量或保证 0.5 秒试听延迟。
- 本轮保留历史报告；新报告不以旧证据自动证明当前失败。旧故障已修复的路径明确承认，未把 .tmp 音频后缀再列为故障。
- 当前改动只在 reviews 内；未修改生产源码、依赖、发布设置、图标、模型、dist 或用户媒体；未运行 ZIP/DMG 打包、签名发布或合并操作。
- 报告链接、源码行号范围、24 项索引与优先级计数、JSON/脚本语法及 Git 空白检查均核对后提交。
