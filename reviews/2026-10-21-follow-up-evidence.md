# main 复评验证记录

对应[复评报告](2026-10-21-follow-up-review.md)，基线 `10ff89c94ef03f4ec5ed11e542aaad496958d044`，2026-10-21，Asia/Singapore。

## 环境和执行结果

本机 Apple Silicon（MacBookPro18,1，32 GiB）、macOS 15.8.1、Xcode 中的 Swift 6.2.4；隔离 API 验证使用现有外部虚拟环境 Python 3.12.13。使用已有环境不代表 app 已捆绑该环境。

| 检查 | 结果 | 解释 |
| --- | --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | 14 tests，0 failures，18.753 秒 | 本机 Ollama 实际返回“人工智能正在改变世界。”；样本视频导出测试实际执行成功。最后 Swift Testing 显示的 0 tests 是另一测试运行器输出，不能用它替代 XCTest 的 14 项结果。 |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --scratch-path /tmp/vat-followup-release` | 成功，18.05 秒 | AudioExtractor.swift:108–112 有捕获非 Sendable AVFoundation 对象的 4 项编译警告；未将构建成功解释为无并发风险。 |
| 隔离复现 runner | 完整退出 0，记录 19 项 probe（另有 1 条基线记录） | 包含一个预期信号 5 子进程；runner 完成不等于产品测试通过。 |

原始结构化摘要：[2026-10-21-follow-up-probes.jsonl](evidence/2026-10-21-follow-up-probes.jsonl)。只将临时模型路径替换为 `<temporary-model-path>`，其余观测结果保留。未记录真实 API Key。

## 复现方式

在该基线 checkout 中，从仓库根目录运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /path/to/python reviews/repro/run_followup_probes.py
```

需要 macOS、Xcode、Python 的 fastapi、uvicorn、httpx、python-multipart；别名视频验证另需 ffmpeg，否则明确记录 skipped。不安装依赖、不下载模型；调用已有测试环境。

新增材料是 [runner](repro/run_followup_probes.py)、[Core probe](repro/FollowupProbe.swift)、[AppState probe](repro/FollowupAppProbe.swift)，复用首轮的 [AudioProbe](repro/AudioProbe.swift) 和 [共享辅助函数/假翻译服务](repro/run_probes.py)。Swift Core 在独立临时 scratch 目录构建；网络假服务只监听随机 loopback 端口。

runner 会直接编译当前 checkout，必须核对记录首行 baseline。报告以本次记录为准；未来修复后观测结果可以不同。不要在生产环境执行首轮 runner 来代替这次复评。

## 动态和注入结果

| Probe | 观测 | 对应结论 |
| --- | --- | --- |
| core：拆分 | index2：He / llo world，Hello token 留左；index10：Hello worl / d，边界 2.92 秒，右侧无 token | FU03；有效词边界 index6 正常，极短句现已拒绝。 |
| core：工程 | 假 API Key 出现在 JSON；恢复后 audioURL 为 nil | FU04、R04 部分。仅序列化 API 验证，没有声称保存界面已存在。 |
| core：时间 | 1.001 秒正确输出 00:00:01,001；0.0001–0.0002 秒输出零时长 cue | R27 修复有效部分及 FU07 残留。 |
| core：模型 | config 为 {}、权重零字节，Swift ready(0.0 MB) | FU09。 |
| core：导出 | 两句只输出有译文的一句，无错误返回 | FU08。 |
| core：语言 | 自定义 French 得到 en-US | R19 部分。 |
| audio | 请求 8 倍仍受限，4 秒输入变为约 2.085 秒；0.5 秒 cue 混音保留 2.085 秒 | R10 原混音裁剪路径已改善；并非完成时长冲突处理。 |
| audio | 两段 2 秒音频分别放在 0、1 秒，混音 3 秒 | R18 原时间轴推移问题修复。 |
| duplicate | 正常返回 One，无崩溃 | R08 崩溃路径修复；不等于响应校验完整。 |
| missing | 只有 unknown-id 的响应仍返回 success，Initial 未变 | R17 仍存在。 |
| stale | 请求期间修改原文与非空译文，结果仍为 Manual | R07 新保护有效部分。 |
| clear | 请求期间清空已有译文，迟到响应改成 Generated from old source | FU06。 |
| cancel | 对实际请求 Task 取消，网络返回 cancelled，Initial 未变 | 底层 Task 取消有效，对比应用入口。 |
| app-cancel | cancelAllTasks 后仍更新译文并显示翻译完成；手动改文字 isDirty=false | FU05、R04。 |
| format-huge | 解码 Int64.max 秒后格式化，Fatal error，退出 -5 | FU07。进程隔离且禁用 core dump，未令 GUI 崩溃。 |
| alias-export | 父目录 symlink 别名导出被接受，原视频字节改变 | FU02。仅操作临时 ffmpeg 合成视频。 |
| tts-callback-success | 合成回调写入 24000 frames，文件头 caff | R11 正向路径有效；`.tmp` 后缀未造成之前怀疑的故障，排除该误报。 |
| tts-callback-write-error | 不存在的父目录触发写入错误，后续结束回调没有再次 resume 崩溃 | R11 原错误路径修复。 |
| no-model-production | mlx_audio 不可用时抛明确错误 | R02 默认不再伪造字幕。 |
| explicit-mock | 显式开 mock 后 is_mock=true | R02。 |
| empty-weight-model | Python 查找接受零字节权重 | FU09，和 Swift 结果相同。 |
| as-is-asr-route | HTTP 500，name 'asyncio' is not defined | FU01，在未注入 asyncio 前发起。 |
| untrusted-origin-storage | ASGI POST 200、实际创建临时目录，Access-Control-Allow-Origin 缺失 | R12 认证仍缺；不是浏览器 CORS 绕过证明。 |
| untrusted-origin-preflight | 400 | 不可信来源的 JSON 预检现已被拒绝，记录修复效果。 |
| thread-offload-with-import-injected | 两请求均 200，max_parallel_inferences=2 | 仅测试预期 offload 路径无准入控制；不是当前接口成功，也没有使用真实模型并发。 |

其中 core 和 audio 各在一条结构化结果中汇总多个观测；表格按业务场景展开。

## 注入边界和未覆盖范围

1. AppState 临时源码副本仅移除 init 中的三个服务探测调用，避免干扰本机服务；任务属性、取消、generation、翻译和状态写回逻辑均未修改。使用延迟 HTTP 假翻译服务。
2. TTS 临时源码副本只将系统 synthesizer 替为确定性 PCM/结束回调，保留文件写入、锁、终态和错误代码。没有验证真实系统音色、长时间发音或系统 TTS 取消。
3. Python 导入时提供空 mlx_audio stub，并禁用真实推理。生产失败路径、显式 mock、目录扫描和真实 ASGI 路由逻辑保持原样；因此验证的是错误处理与路由，不是真实识别质量。
4. storage 验证将 Path.home 临时替为隔离目录，避免在用户 home 写入；直接 ASGI 客户端没有浏览器执行策略。不可信 Origin 的实际浏览器访问还受预检和本地网络限制，不能据此声称任意网页都可成功执行管理请求。
5. 并发推理观测发生在显式给模块注入 asyncio 后，用 sleep 假推理替换模型调用。它只证明修补导入后当前控制流允许两次并发，不证明 MLX 实例已经故障。
6. 未做全套 GUI 点击、窗口关闭/崩溃恢复、真实 ASR 模型推理、干净 Mac 安装、真实人声分离或完整长视频听感验收。静态关闭的原始发现均按代码路径判断，不冒充端到端测试。
7. 没有构建/覆盖 dist 应用或 ZIP；没有下载模型、调用付费服务、停止本机服务或修改用户媒体。测试临时媒体和 scratch 构建相互隔离。
