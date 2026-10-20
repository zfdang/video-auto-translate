# 全仓代码评审报告

- 评审时间：2026-10-20 开始，2026-10-21 完成（Asia/Singapore）。
- 审阅基线：`3eca59b8ecd48527fd2306a4949b40edd4112783`，当时的 `main`。本文中的行号均指该提交，不包含报告自身的改动。
- 范围：全部 32 个生产 Swift 文件、1 个 Swift 测试文件、2 个 Python 脚本、2 个 Shell 脚本，以及 Package.swift、资源、README 和三份设计文档。
- 交付方式：只增加评审报告和隔离复现材料，不修改生产代码，不升级模型，不改变用户服务配置，不合并 PR。

## 1. 结论

现有项目已经具备可运行的导入、识别、翻译、字幕编辑及视频导出链路。Release 构建和现有 8 个测试均通过；其中本机 Ollama 翻译和样本视频导出实际执行成功。不过，这些测试没有覆盖编辑数据安全、模型缺失、异常服务响应、任务交错和配音时长冲突。

本次记录 **33 项发现：13 项 P1、20 项 P2，无 P0**。其中包含实现缺陷及明确影响数据安全的核心能力缺口，不应把它们统称为 33 个安全漏洞。建议先修复输入文件保护、识别失败伪成功、编辑丢失、异步写回校验和崩溃路径，再继续扩展功能。

目前不宜将应用视为可放心处理唯一媒体副本、可恢复长时间编辑或可直接部署到干净 Mac 的稳定版本。这个判断来自下文具体触发条件，不代表所有正常输入都会失败。

### 优先级与证据说明

- **P1**：可导致源文件/人工内容丢失、崩溃、核心结果伪造、未经授权的本地操作，或阻断主要交付能力，应优先修复。
- **P2**：特定输入、任务交错、配置或交互下的功能错误、资源生命周期问题和验证缺口。
- **动态确认**：调用基线代码进行了隔离验证；原始摘要见[验证记录](2026-10-21-evidence.md)和[结果文件](evidence/2026-10-21-probes.jsonl)。
- **注入验证**：保留实际业务逻辑，用确定性假回调/假服务替代外部依赖。它证明该控制流存在问题，不等同于真实模型或 GUI 的完整测试。
- **静态确认**：代码路径足够明确，但没有实际执行该场景。依赖 UI 点击传播或具体系统行为的部分另行标明。

## 2. 发现索引

| ID | 等级 | 发现 | 证据 |
| --- | --- | --- | --- |
| R01 | P1 | 视频导出会先删除目标；同路径时删除源视频 | 动态 |
| R02 | P1 | ASR 缺失或推理失败后返回示例文本，伪装为识别成功 | 动态 |
| R03 | P1 | 更换媒体后，旧任务能把结果写入新项目 | 静态 |
| R04 | P1 | 无工程保存/恢复及脏状态保护，编辑只能驻留内存 | 静态、能力缺口 |
| R05 | P1 | 拆分直接清空人工译文，且无结构化撤销 | 动态＋静态 |
| R06 | P1 | 词级拆分映射错误，兜底仍能产生零时长和词归属错位 | 动态 |
| R07 | P1 | 迟到翻译会覆盖任务执行期间的人工修改 | 动态 |
| R08 | P1 | 翻译返回重复 ID 时触发不可捕获的运行时崩溃 | 动态 |
| R09 | P1 | 配音混音使用完整原声，未实现人声替换 | 静态 |
| R10 | P1 | 变速限幅后直接裁短配音，丢失尾部语音 | 动态 |
| R11 | P1 | TTS 写入错误可多次 resume 同一个 continuation，导致崩溃 | 注入验证 |
| R12 | P1 | 本地管理 API 无认证并允许任意 Origin 修改目录/启动下载 | ASGI 注入验证 |
| R13 | P1 | 打包未提供 Python 运行环境，依赖开发者的其他项目 | 静态 |
| R14 | P2 | 行内拆分按钮把操作交给全局选中项，而非当前行 | 静态；GUI 路由待验证 |
| R15 | P2 | 合并不检查连续性；嵌套区间还会缩短结果 | 动态＋静态 |
| R16 | P2 | 编辑文本/时间后不使对齐和配音缓存失效 | 动态＋静态 |
| R17 | P2 | 翻译响应缺失/不匹配 ID 时仍报告整批完成 | 动态 |
| R18 | P2 | 重叠配音插入同一轨道会推移既有片段，破坏时间轴 | 动态 |
| R19 | P2 | 目标语言未传入 TTS，所有生成默认使用中文音色 | 静态 |
| R20 | P2 | 试听 AVPlayer 没有持久持有，生命周期不覆盖播放 | 静态 |
| R21 | P2 | 同步模型推理阻塞 ASGI 事件循环，使健康/管理接口停顿 | 注入验证 |
| R22 | P2 | Sidecar 超时/退出后仍报 running，停止流程无等待上限 | 静态 |
| R23 | P2 | 首次下载不启动服务；网络错误被吞掉并遗留下载中状态 | 静态 |
| R24 | P2 | 仓库下载的取消按钮不能取消后台任务 | 静态 |
| R25 | P2 | 模型路径、服务地址在 UI/服务间不同步，重启后失效 | 静态 |
| R26 | P2 | 目录存在就被视为模型就绪，半成品也能通过检测 | 动态 |
| R27 | P2 | 时间转换有毫秒误差，对超大值会崩溃且不校验区间 | 动态 |
| R28 | P2 | 导出跨 await 读取活跃项目和可变字幕，未固定快照 | 静态 |
| R29 | P2 | 嵌套 ObservableObject 变化未转发，状态和预览可能不刷新 | 静态 |
| R30 | P2 | 播放持续改写编辑选中项并自动滚动，打断校对 | 静态 |
| R31 | P2 | “仅译文”输出静默回填原文，与所选语言模式不符 | 动态 |
| R32 | P2 | E2E 脚本可在翻译失败后成功退出，不能验证 Swift 全链路 | 静态 |
| R33 | P2 | ASR model 配置被服务端忽略，模型列表与实际执行不符 | 静态 |

## 3. P1 详细发现

### R01 视频导出先删除目标，可删除源视频

**位置**：[VideoComposer.swift:41–47](../Sources/VideoAutoTranslateCore/Exporter/VideoComposer.swift#L41-L47)，[ExportView.swift:148–180](../Sources/VideoAutoTranslateApp/ExportView.swift#L148-L180)。

- **触发**：导出时选择源视频路径；或者目标已有有效视频，但新导出因无轨道/素材错误失败。
- **问题**：`compose` 在读取源媒体、验证轨道之前无条件 `removeItem(outputURL)`。输入输出相同则先删输入；不同路径失败也会损失原有目标。
- **验证**：用临时目录中的可丢弃 sentinel 文件作同路径输入/输出，调用后虽然抛出读取错误，文件已经不存在。没有对用户媒体执行此操作。
- **建议**：比较标准化路径和文件身份，拒绝输出指向任何输入资源；先导出到同目录临时文件，成功校验后再原子替换已授权目标。音频工具中的类似预删除策略也应统一保护。
- **回归**：同路径、符号链接指向输入、已存在目标＋导出失败、取消、成功替换；均需检查旧文件是否保留。

### R02 ASR 的生产回退路径伪造识别结果

**位置**：[asr_server.py:328–475](../scripts/asr_server.py#L328-L475)，尤其 427–475；[AppState.swift:164–178](../Sources/VideoAutoTranslateApp/AppState.swift#L164-L178)。

- **触发**：未安装 mlx-audio、没有模型、推理异常，或没有得到非空文本等。
- **问题**：服务返回固定英文 `demo_sentences` 和按音频时长生成的时间戳，结构与正常识别成功完全相同；客户端直接显示“识别完成”并允许继续翻译和导出。
- **验证**：在临时 3 秒静音 WAV 上强制无模型，得到 `Welcome to the native video`，共 5 个词。这不是识别误差，而是确定性的示例文本。
- **建议**：生产路径失败必须返回明确状态；模拟结果只能通过显式开发模式启用，并带不可混淆的标记。没有对齐的识别文本应保留为“待对齐”，不能使用固定 5 秒区间假装有效。
- **回归**：无运行时、无权重、空语音、模型异常、对齐异常、真实正常语音分别验证；任何失败不能产生未标记的示例字幕。

### R03 旧转录任务可污染后来打开的视频

**位置**：[AppState.swift:124–131](../Sources/VideoAutoTranslateApp/AppState.swift#L124-L131)、[139–179](../Sources/VideoAutoTranslateApp/AppState.swift#L139-L179)，[MainView.swift:54–63](../Sources/VideoAutoTranslateApp/MainView.swift#L54-L63)、[86–94](../Sources/VideoAutoTranslateApp/MainView.swift#L86-L94)。

- **触发**：视频 A 识别中，通过更换视频、拖放或打开文件事件载入视频 B。
- **问题**：`openVideo` 重置同一个 `project`，但不取消旧任务。旧任务恢复时直接设置当前 `project.audioURL/subtitles/isProcessing/progress`，没有 projectID/generation 校验。A 的识别字幕与音频可能出现在 B 的画面下；reset 还使新任务可以同时启动。
- **建议**：持有任务句柄，媒体切换建立新 generation，取消旧任务；每个 await 后及最终提交时检查归属。仅在 UI 禁用按钮不能替代写回校验，外部打开事件仍可能发生。
- **回归**：使用延迟假服务执行 A→B，确保 A 的迟到结果、错误及进度均不能写入 B；同时验证取消后可继续操作。

### R04 无工程持久化，长时间编辑无法恢复

**位置**：[ProjectState.swift:4–32](../Sources/VideoAutoTranslateCore/Models/ProjectState.swift#L4-L32)、[AppState.swift:124–131](../Sources/VideoAutoTranslateApp/AppState.swift#L124-L131)、[VideoAutoTranslateApp.swift:65–82](../Sources/VideoAutoTranslateApp/VideoAutoTranslateApp.swift#L65-L82)。

- **触发**：关闭应用、意外退出、更换视频或再次转录。
- **问题**：工程只存于内存，未找到工程写入/读取、自动保存、恢复入口或未保存确认。SubtitleItem 的 Codable 并不意味着实际保存了工程；SRT 导出也不能恢复词映射、设置和编辑历史。
- **性质**：这是明确影响编辑安全的 M1 能力缺口，并非某个已存在保存函数的实现错误。设计文档已经要求保存恢复。
- **建议**：引入版本化工程格式、原子检查点及脏状态提示；至少在覆盖/切换前允许保存或取消。清晰区分“导出字幕”与“保存工程”。
- **回归**：编辑、拆分、译文待处理及媒体引用保存后重开；模拟写入失败、异常退出和源媒体移动。

### R05 拆分丢失已有译文，无法结构化撤销

**位置**：[SubtitleManager.swift:53–67](../Sources/VideoAutoTranslateCore/Manager/SubtitleManager.swift#L53-L67)，[AppState.swift:258–284](../Sources/VideoAutoTranslateApp/AppState.swift#L258-L284)。

- **触发**：对翻译或人工校对完成的字幕点击拆分。
- **问题**：两个新项显式设置 `translatedText: ""`，随后原项从数组删除；未保留待分配译文和拆分事务，也没有为拆分/合并注册撤销。原生 TextField 自身的文字撤销不能恢复被替换的字幕结构。
- **验证**：输入带“人工译文”的项，任意有效拆分后两项译文均为空。
- **建议**：拆分提案中独立确认译文断点；暂缓时持久保存原译文。创建可撤销的完整编辑事务，恢复原 ID、文本、时间与派生状态。
- **回归**：译文语序变化、人工修改后拆分、暂缓分配、拆分/合并撤销重做、保存重开。

### R06 词级拆分无法保持文本与时间的对应关系

**位置**：[SubtitleManager.swift:15–50](../Sources/VideoAutoTranslateCore/Manager/SubtitleManager.swift#L15-L50)，[WordToken.swift:5–20](../Sources/VideoAutoTranslateCore/Models/WordToken.swift#L5-L20)。

- **问题**：按 token 文本长度累加定位，未计入拼接空格和标点映射；光标可以劈开词，但词仍全部归属另一边。非法断点又被强行替换为时间中点，并未重新校验最小时长或词归属。
- **验证**：`Hello world` 在 index=10 拆成 `Hello worl` / `d`，`world` token 却完整留在左句，且兜底切点为 2 秒而非词边界。1ms 的 `ab` 拆分得到 0ms 和 1ms 两句。
- **建议**：存储某一原文版本上的显式文本范围；生成词边界候选与拆分提案，缺失/失效映射进入人工调时。拒绝无效区间，不能用中点掩盖失败。
- **回归**：词内、空格、标点、emoji、组合字符、极短句、缺词、词时间重叠和原文修改后的拆分。

### R07 迟到翻译覆盖人工修改

**位置**：[SubtitleTranslator.swift:64–69](../Sources/VideoAutoTranslateCore/LLM/SubtitleTranslator.swift#L64-L69)、[100–116](../Sources/VideoAutoTranslateCore/LLM/SubtitleTranslator.swift#L100-L116)，[SubtitleRowView.swift:52–66](../Sources/VideoAutoTranslateApp/SubtitleRowView.swift#L52-L66)。

- **触发**：翻译请求发出后，用户继续修改同一句原文或译文。
- **问题**：请求读取旧原文，返回时只按 ID 写入同一个可变对象；没有输入指纹、版本或人工锁定校验。
- **验证**：延迟本地假服务响应，在等待时将原文改为 `User corrected source`，译文改为 `User manual translation`；返回后人工译文变成基于旧原文的结果。
- **建议**：请求携带 sourceRevision、targetRevision 和 generation；写回时校验，并将过期结果保留为可选建议而非覆盖。
- **回归**：原文变更、人工译文变更、重译、拆分、撤销及删除之后的迟到响应。

### R08 重复翻译 ID 直接使进程崩溃

**位置**：[SubtitleTranslator.swift:106–115](../Sources/VideoAutoTranslateCore/LLM/SubtitleTranslator.swift#L106-L115)。

- **问题**：外部模型响应未经唯一性校验就传给 `Dictionary(uniqueKeysWithValues:)`。重复 ID 触发 fatalError，无法由上层 do/catch 捕获，全部未保存编辑随进程退出丢失。
- **验证**：假服务为一个 ID 返回两条译文，隔离子进程以信号 5 退出，提示 `Fatal error: Duplicate values for key`。
- **建议**：在写入前验证 ID 唯一、属于请求集合且字段类型正确；重复应成为可重试错误，禁止静默任选一条。
- **回归**：重复 ID、未知 ID、ID 大小写变化、空译文和完整正常集合。

### R09 新语言配音没有替换原人声

**位置**：[AppState.swift:149–152](../Sources/VideoAutoTranslateApp/AppState.swift#L149-L152)、[229–232](../Sources/VideoAutoTranslateApp/AppState.swift#L229-L232)，[ExportView.swift:164–173](../Sources/VideoAutoTranslateApp/ExportView.swift#L164-L173)，[AudioMixer.swift:80–95](../Sources/VideoAutoTranslateCore/Audio/AudioMixer.swift#L80-L95)。

- **问题**：传给 `backgroundAudioURL` 的是为识别提取的完整 16kHz 单声道音频，不是分离的背景。混音只将其闪避到 0.35，再叠上新声音；原说话人仍存在，且原背景立体声和高频信息已经降采样丢失。
- **建议**：显式区分识别副本、原声、分离背景和新配音。分离未实现时提供准确标注的“原声叠加”模式，不宣称替换人声；最终背景从原始质量路径获得。
- **回归**：带原人声、音乐及立体声定位的样本，分别检查听感和声道；验证替换模式确实不把完整识别音轨当作背景。

### R10 配音超时被直接截断

**位置**：[SubtitleManager.swift:129–137](../Sources/VideoAutoTranslateCore/Manager/SubtitleManager.swift#L129-L137)，[TimePitchEngine.swift:27–28](../Sources/VideoAutoTranslateCore/Audio/TimePitchEngine.swift#L27-L28)，[AudioMixer.swift:60–69](../Sources/VideoAutoTranslateCore/Audio/AudioMixer.swift#L60-L69)。

- **问题**：变速倍率被限在 0.5～2.0，无法保证生成音频能塞进窗口；混音再用 `min(snippetDuration, item.duration)` 只插入前半部分，没有冲突提示。
- **验证**：4 秒合成信号请求 8 倍变速，实际得到约 2.085 秒；放入 0.5 秒字幕窗口后，混音结果只有 0.5 秒，超过窗口的音频消失。
- **建议**：测量实际伸缩时长并标记超时，要求缩短译文、确认借用空白或调时；不能通过裁剪伪造对齐成功。
- **回归**：长译文、极短窗口、限幅上下界、引擎尾延迟和邻句冲突；校验末尾语音完整。

### R11 TTS 错误路径可多次完成 continuation

**位置**：[SystemTTSService.swift:48–70](../Sources/VideoAutoTranslateCore/TTS/SystemTTSService.swift#L48-L70)。

- **触发**：创建音频文件或写入某个 PCM buffer 失败，但合成器继续提供后续 buffer/结束回调。
- **问题**：catch 直接 resume throwing，却没有终态标记或停止后续回调；frameLength=0 还会再次 resume returning。
- **验证边界**：临时复制基线服务，注入“一段 PCM＋结束回调”，使用不存在的输出父目录，复现 `SWIFT TASK CONTINUATION MISUSE`，子进程信号 5。未调用真实系统语音服务或故意填满磁盘。
- **建议**：建立线程安全的 exactly-once 完成状态，首错后停止/忽略后续回调并清理文件；同时处理取消、无有效音频和异常 buffer。
- **回归**：首块失败、中途失败、失败后的结束回调、重复结束、取消及正常生成。

### R12 本地管理服务缺少应用边界保护

**位置**：[asr_server.py:29–35](../scripts/asr_server.py#L29-L35)、[156–162](../scripts/asr_server.py#L156-L162)、[194–198](../scripts/asr_server.py#L194-L198)、[271–281](../scripts/asr_server.py#L271-L281)。

- **问题**：CORS 允许所有来源/方法/请求头并允许凭据；管理 API 不要求凭证，接受任意目录、repo 和 mirror。默认只监听 loopback，并不能区分本应用、其他本地进程或被浏览器允许访问本地网络的网页。
- **验证边界**：在进程内 ASGI 客户端使用 `Origin: https://review.invalid`，POST 修改临时模型目录，得到 200、允许该 Origin 的响应头，并实际创建目录。没有用浏览器绕过其本地网络访问限制，也没有执行外部仓库下载。
- **影响**：服务应用层允许未授权修改配置、发起下载及占用磁盘/计算资源。不要把本验证扩大解释为任意浏览器必然可无提示攻击或已经证明代码执行。
- **建议**：仅绑定 loopback；托管时生成随机会话令牌，Swift 请求携带认证；取消任意来源 CORS，管理路由校验允许的模型、镜像和目录范围，限制任务并发和上传大小。
- **回归**：无令牌、错误令牌、不受信 Origin、任意目录/镜像、重复任务及授权请求。

### R13 应用打包不具备干净机器上的 ASR 运行条件

**位置**：[ASRSidecarManager.swift:66–80](../Sources/VideoAutoTranslateCore/ASR/ASRSidecarManager.swift#L66-L80)、[102–105](../Sources/VideoAutoTranslateCore/ASR/ASRSidecarManager.swift#L102-L105)，[build_app.sh:20–25](../build_app.sh#L20-L25)，[asr_server.py:22–25](../scripts/asr_server.py#L22-L25)。

- **问题**：解释器优先是另一个开发项目的 venv，找不到才尝试外部 Python；打包只复制脚本，没有提供 Python、FastAPI、uvicorn、multipart、mlx-audio 等运行时，也没有依赖清单/锁定版本或初始化流程。
- **影响**：本机运行依赖已安装开发环境，不能证明 `.app` 在另一台 Mac 可使用识别/下载。ASR 服务启动错误又被重定向到 `/dev/null`，用户难以定位。
- **建议**：明确支持交付模式：捆绑并固定依赖的运行时、可验证的受管安装流程，或真正原生引擎。去掉私人工作区依赖，启动前做依赖检查并保存诊断日志；README 如实说明外部依赖及体积。
- **回归**：没有任何开发目录、Python 包和缓存的干净用户环境中，验证首次准备、离线重启和失败提示。

## 4. P2 详细发现

### R14 行内拆分没有绑定当前行 ID

**位置**：[SubtitleListView.swift:91–95](../Sources/VideoAutoTranslateApp/SubtitleListView.swift#L91-L95)，[AppState.swift:259–265](../Sources/VideoAutoTranslateApp/AppState.swift#L259-L265)。

按钮使用当前行的长度计算 mid，但实际执行函数重新查找全局 selectedSubtitleID。选中 A 而触发 B 的处理闭包时，会拆 A 或因索引不合法无动作。是否每种真实点击都会先触发行 onTapGesture 未做 GUI 自动化验证，不能依赖事件传播来保证数据目标。应直接传入 `item.id`；回归选中 A 后点击 B 的剪刀、播放自动选中另一行及搜索过滤场景。

### R15 合并允许非连续字幕，时间范围计算也不完整

**位置**：[AppState.swift:275–283](../Sources/VideoAutoTranslateApp/AppState.swift#L275-L283)，[SubtitleManager.swift:73–92](../Sources/VideoAutoTranslateCore/Manager/SubtitleManager.swift#L73-L92)。

任意选中集合都可合并，没有检查中间是否存在未选项。选择第 1 和第 3 句会创建覆盖第 2 句的长字幕，而第 2 句还存在。按 start 排序后使用最后一项的 end，也不是所有区间的最大终点；动态输入 `[0,10]` 与 `[1,2]` 合并得到 `[0,2]`。应先检查轨道顺序及连续性，显式处理已有重叠；结果不能丢失任何选中内容覆盖区间。补充反向选择、非连续、嵌套区间及长停顿回归。

### R16 文本与时间修改不更新派生状态

**位置**：[SubtitleItem.swift:8–16](../Sources/VideoAutoTranslateCore/Models/SubtitleItem.swift#L8-L16)，[SubtitleRowView.swift:52–66](../Sources/VideoAutoTranslateApp/SubtitleRowView.swift#L52-L66)，[AppState.swift:244–250](../Sources/VideoAutoTranslateApp/AppState.swift#L244-L250)。

原文修改后 words 保持原样，译文或时间变化后 dubbedAudioURL 仍指向旧结果；试听只检查 URL 是否存在。动态直接编辑后可观察到旧 tokens 和缓存 URL 均被保留。这里与 R07 不同：即使没有任何进行中的请求，已经完成的生成结果也会过期。应按原文、译文、音色、时间分别维护版本/指纹及依赖失效；原始 TTS 与伸缩缓存分开。回归编辑后试听、调时后导出和修改原文后拆分。

### R17 缺失/未知翻译 ID 被当作成功

**位置**：[SubtitleTranslator.swift:109–116](../Sources/VideoAutoTranslateCore/LLM/SubtitleTranslator.swift#L109-L116)、[143–155](../Sources/VideoAutoTranslateCore/LLM/SubtitleTranslator.swift#L143-L155)，[AppState.swift:199–202](../Sources/VideoAutoTranslateApp/AppState.swift#L199-L202)。

解析到任意非空 entries 就继续，只更新匹配项，不检查请求 ID 是否全部返回，空/错误项也没有失败状态。动态只返回 unknown-id 时，translate 正常返回且原译文不变，上层仍会报全部完成。应验证准确 ID 集合及字符串类型，记录逐句失败并支持重试；不能将字典/数字通过 `String(describing:)` 冒充译文。回归部分缺失、全部未知、错误类型及第二批失败后第一批结果保留。

### R18 重叠配音在单轨插入时推移已有片段

**位置**：[AudioMixer.swift:39–42](../Sources/VideoAutoTranslateCore/Audio/AudioMixer.swift#L39-L42)、[49–71](../Sources/VideoAutoTranslateCore/Audio/AudioMixer.swift#L49-L71)。

所有片段通过同一个 composition track 的 insertTimeRange 插入，插入会推移该轨已有内容。动态将两段 2 秒信号放在 0 秒和 1 秒，输出时长为 4 秒而不是时间轴应有的 3 秒。应在入混音前拒绝不支持的重叠，或分配不同轨道叠混；闪避区间也要合并后生成统一包络，避免紧邻区间的相互覆盖。回归连续、重叠、乱序和短间隔片段，校验实际发音起点。

### R19 TTS 默认中文，与目标语言设置脱节

**位置**：[AppState.swift:219–222](../Sources/VideoAutoTranslateApp/AppState.swift#L219-L222)、[244–247](../Sources/VideoAutoTranslateApp/AppState.swift#L244-L247)，[SubtitleManager.swift:101–104](../Sources/VideoAutoTranslateCore/Manager/SubtitleManager.swift#L101-L104)，[SystemTTSService.swift:39–44](../Sources/VideoAutoTranslateCore/TTS/SystemTTSService.swift#L39-L44)。

全片与单句调用都未传 voice，始终使用 zh-CN；选日语、英语等不会选择对应系统音色。找不到音色还静默退回中文。应保存目标语言代码与用户音色，生成时显式传入并校验；无音色应提供可操作错误。回归非中文和自定义语言、缺失音色及缓存指纹变化。

### R20 单句试听播放器生命周期过短

**位置**：[AppState.swift:249–252](../Sources/VideoAutoTranslateApp/AppState.swift#L249-L252)。

AVPlayer 只存于局部 tempPlayer，play 后函数立即返回，未由状态对象持有，也未管理播放结束或互斥。不能保证它存活到音频播放完成。建议单独持有 auditionPlayer，管理停止/结束、视频暂停和连续试听。此项为生命周期静态检查，尚未在所有系统版本上验证可听表现。

### R21 模型推理阻塞本地服务事件循环

**位置**：[asr_server.py:298–317](../scripts/asr_server.py#L298-L317)，[328–363](../scripts/asr_server.py#L328-L363)。

async 路由直接运行同步 generate/模型加载，没有线程或串行推理执行器。注入 350ms 同步推理后，原定 20ms 的事件循环定时器实际约 357ms 才执行，健康和管理请求也共享该循环。真实推理期间可能被客户端误判离线。应将推理移到受控执行队列，保持 health 响应，并限制并发以保护模型与内存。不能只把路由改为无限并发线程而不管理模型使用。

### R22 Sidecar 生命周期不可靠

**位置**：[ASRSidecarManager.swift:134–153](../Sources/VideoAutoTranslateCore/ASR/ASRSidecarManager.swift#L134-L153)、[177–184](../Sources/VideoAutoTranslateCore/ASR/ASRSidecarManager.swift#L177-L184)。

16 次健康检查失败后仍设 running 并返回 true；未检查子进程提前退出，也未保存启动失败日志。ensureRunning 没有合并并发启动请求，多个窗口/操作可能启动多个实例。stop 使用无期限 waitUntilExit，且 AppDelegate 在退出主线程调用，繁忙服务拒绝或延迟退出时可卡住关闭。应设真实就绪条件、串行启动状态机、terminationHandler、超时和有界终止策略；区分外部服务与本应用拥有的进程。回归立即退出、端口冲突、慢启动、繁忙退出及两个并发启动。

### R23 首次模型下载没有准备服务且吞掉网络错误

**位置**：[AppState.swift:327–334](../Sources/VideoAutoTranslateApp/AppState.swift#L327-L334)，[ModelStorageManager.swift:181–197](../Sources/VideoAutoTranslateCore/ASR/ModelStorageManager.swift#L181-L197)。

应用使用 lazy sidecar，但点击“立即下载”不 ensureRunning，直接 POST 本地管理接口。服务未启动时网络抛错被 try? 吞掉；状态已预先设 downloading，界面可能一直显示启动中。应在仓库下载前准备服务，统一 catch→failed，同时展示失败原因；无模型首次安装不应必须先触发转录。回归全新启动直接下载、连接拒绝、超时及重试。

### R24 “取消”不能取消仓库下载

**位置**：[ModelStorageManager.swift:195–241](../Sources/VideoAutoTranslateCore/ASR/ModelStorageManager.swift#L195-L241)，[asr_server.py:271–295](../scripts/asr_server.py#L271-L295)。

预设全是仓库模型，但 cancelDownload 仅取消单文件 URLSessionTask 并修改 UI 状态；没有服务端取消接口，也不持有 polling Task。后台仍占带宽/磁盘，并能随后把状态改回下载中/就绪。轮询的 while true 对非终态无总期限，try? sleep 也吞掉取消。应返回任务 ID，真实支持暂停/取消并等待确认；不支持时不要显示具有该语义的取消按钮。补充取消后不继续写入、服务消失和终态一致性验证。

### R25 模型目录与服务配置缺少一致性

**位置**：[SettingsView.swift:93–108](../Sources/VideoAutoTranslateApp/SettingsView.swift#L93-L108)，[AppState.swift:290–299](../Sources/VideoAutoTranslateApp/AppState.swift#L290-L299)，[ModelStorageManager.swift:166–173](../Sources/VideoAutoTranslateCore/ASR/ModelStorageManager.swift#L166-L173)，[ASRSidecarManager.swift:128](../Sources/VideoAutoTranslateCore/ASR/ASRSidecarManager.swift#L128)，[asr_server.py:50](../scripts/asr_server.py#L50)。

自定义路径 TextField 只改 project 配置，不同步 manager；浏览按钮才执行完整同步。服务同步/下载地址硬编码 8765，忽略用户的 ASR URL。设置变更时服务未运行会被忽略，之后启动不传 --models-dir，也未重新同步；下载到自定义路径的模型可能找不到。配置本身也未持久化。应建立单一配置来源、明确识别端点与管理端点，启动后同步并验证生效。回归手输路径、外置盘、修改服务端口和重启后的模型查找。

### R26 模型就绪检测不验证完整性

**位置**：[ModelStorageManager.swift:103–117](../Sources/VideoAutoTranslateCore/ASR/ModelStorageManager.swift#L103-L117)，[asr_server.py:80–98](../scripts/asr_server.py#L80-L98)。

Swift 看见仓库目录就 ready；Python 非空目录即返回，即使里面只有 refs、锁或半下载内容。动态在 Swift 得到“0.0 MB 已就绪”，Python 也能把仅有 refs/main 的目录当作模型路径。应验证快照引用、配置、分片索引、权重存在与完整性，并区分 downloaded/verified/loadable；失败/取消不能产生 ready。对 git clone 备用路径也要检查 LFS 指针是否已物化，不能仅凭退出码认定完成。

### R27 时间工具存在精度和输入验证问题

**位置**：[TimeTypes.swift:10–32](../Sources/VideoAutoTranslateCore/Models/TimeTypes.swift#L10-L32)、[46–61](../Sources/VideoAutoTranslateCore/Models/TimeTypes.swift#L46-L61)，[LocalASRService.swift:167–190](../Sources/VideoAutoTranslateCore/ASR/LocalASRService.swift#L167-L190)。

浮点乘法和截断导致已有精确 CMTime 再格式化丢 1ms：1001ms 导出为 1.000s，1003ms 导出为 1.002s。超大但合法 Double（1e300）转 Int64 直接崩溃；ASR 响应未校验范围，CodableCMTime 也允许零 timescale/负数。SRT 导出还接受 end<start，动态输出了反向区间。应在边界验证有限性、可表示范围和媒体时长，使用有理数缩放及明确舍入，导出前再校验。回归各毫秒值、边界舍入、极端数值、无效 timescale、负数与反向区间。

### R28 导出没有固定项目快照

**位置**：[ExportView.swift:148–181](../Sources/VideoAutoTranslateApp/ExportView.swift#L148-L181)，[VideoComposer.swift:43–130](../Sources/VideoAutoTranslateCore/Exporter/VideoComposer.swift#L43-L130)。

视频 URL 在打开保存面板前捕获，subtitles/audioURL/语言模式则在后续 Task 和混音 await 前后重新读取当前状态。数组中的 SubtitleItem 又是可变引用。已有翻译任务可在此期间写入，新媒体也可通过外部事件打开，导致同一导出混合不同版本的画面、音频和字幕。应在确认导出时创建不可变 DTO 快照并固定媒体指纹、语言和配音资产版本；导出任务可独立取消，不以窗口状态代替数据隔离。回归导出同时翻译完成、编辑和打开新视频。

### R29 嵌套发布没有穿透到实际观察者

**位置**：[AppState.swift:9](../Sources/VideoAutoTranslateApp/AppState.swift#L9)、[23–24](../Sources/VideoAutoTranslateApp/AppState.swift#L23-L24)，[SettingsView.swift:6](../Sources/VideoAutoTranslateApp/SettingsView.swift#L6)、[152–204](../Sources/VideoAutoTranslateApp/SettingsView.swift#L152-L204)，[VideoPlayerView.swift:8–24](../Sources/VideoAutoTranslateApp/VideoPlayerView.swift#L8-L24)。

SettingsView 观察 AppState，而进度由其 modelStorageManager 内部发布；@Published 包装引用并不转发子对象的 objectWillChange。字幕行观察 item，所以行编辑能变，但播放器浮层、筛选和工作流完成标记主要观察父级，也可能停留在旧状态直到别的发布触发。应在使用处直接观察相应对象，或通过领域快照统一发布；不要用 Array(project.subtitles) 强行刷新来替代状态建模。该项尚未逐控件做 GUI 自动化验证。

### R30 播放高亮与编辑选中状态混用

**位置**：[AppState.swift:94–108](../Sources/VideoAutoTranslateApp/AppState.swift#L94-L108)，[SubtitleListView.swift:98–116](../Sources/VideoAutoTranslateApp/SubtitleListView.swift#L98-L116)。

播放器每 100ms 查找当前句并改 selectedSubtitleID；列表一旦该 ID 改变就居中滚动。用户校对旧句、滚动搜索或准备拆分时，播放会重新选择并拉回当前发音行。应分离 playingCueID、selectedCueIDs 和编辑焦点；编辑/手动滚动时暂停跟随并提供恢复按钮。回归播放中修改前句、多选、查找和单句试听。

### R31 仅译文导出静默混入原文

**位置**：[SRTExporter.swift:41–43](../Sources/VideoAutoTranslateCore/Exporter/SRTExporter.swift#L41-L43)、[69–71](../Sources/VideoAutoTranslateCore/Exporter/SRTExporter.swift#L69-L71)，[VideoComposer.swift:143–145](../Sources/VideoAutoTranslateCore/Exporter/VideoComposer.swift#L143-L145)。

译文为空时直接使用原文；用户选择“仅目标语言”仍可能得到混合语言文件或硬字幕，无法区分未翻译与有意保留。动态无译文的英文句在 translatedOnly 下照样导出英文。应在导出前列出缺译项，让用户修复或明确选择跳过/回填；该选择应覆盖文件和视频两条管道。回归部分缺译、全部缺译及用户明确保留原文。

### R32 E2E 与单元测试存在假阳性和覆盖缺口

**位置**：[test_e2e.py:136–159](../scripts/test_e2e.py#L136-L159)、[213–248](../scripts/test_e2e.py#L213-L248)，[VideoAutoTranslateCoreTests.swift:97–99](../Tests/VideoAutoTranslateCoreTests/VideoAutoTranslateCoreTests.swift#L97-L99)、[156–182](../Tests/VideoAutoTranslateCoreTests/VideoAutoTranslateCoreTests.swift#L156-L182)。

Python 翻译异常只打印 warning、填空译文，最后仍输出“全流程测试全部成功”并以 0 退出；没有断言每行翻译成功、内容来自真实识别或字幕非空。它重写了断句/翻译/SRT 逻辑，并未运行 Swift 编辑器、Swift 导出或配音，不能证明应用全链路。Swift 测试缺样本/服务时直接 return，测试报告会将其算作通过而非跳过；视频仅查文件大小不查画面/音轨。应拆分离线确定性测试与显式集成测试，使用 XCTSkip，失败用非零退出，验证内容、时间和媒体轨道。当前 8 项通过不能代替这些验证。

### R33 ASR model 配置没有影响真实模型选择

**位置**：[LocalASRService.swift:106–109](../Sources/VideoAutoTranslateCore/ASR/LocalASRService.swift#L106-L109)，[asr_server.py:183–190](../scripts/asr_server.py#L183-L190)、[328–333](../scripts/asr_server.py#L328-L333)，[SettingsView.swift:309](../Sources/VideoAutoTranslateApp/SettingsView.swift#L309)。

客户端发送用户配置 model，服务函数却总是定位固定的 Qwen3-ASR-1.7B-8bit 和固定 aligner。/v1/models 还声明 0.6B 与 whisper-small，但没有实现对应分支。应维护真实能力注册表，按请求选择模型；不支持的模型返回明确错误，不能静默换用其他模型或进入 R02 的示例回退。回归不同模型 ID、未知 ID 与真实可用模型列表。

## 5. 模块覆盖与设计符合性

| 模块 | 审阅文件 | 主要结果 |
| --- | --- | --- |
| 应用/UI（8） | AppState、MainView、SettingsView、ExportView、SubtitleListView、SubtitleRowView、VideoPlayerView、VideoAutoTranslateApp | R03–R05、R07、R14、R19–R20、R23、R25、R28–R30 |
| 编辑/模型（8） | SubtitleManager；ASRConfiguration、LLMConfiguration、ModelStorageConfig、ProjectState、SubtitleItem、TimeTypes、WordToken | R04–R06、R15–R16、R27 |
| ASR（6） | ASREngineProtocol、ASRSidecarManager、LocalASRService、ModelStorageManager、NaturalLanguageSegmenter、QwenASREngine | R02、R13、R21–R27、R33 |
| LLM（3） | OpenAICompatibleClient、SubtitleTranslator、OllamaProbe | R07–R08、R17；服务配置与探测见待完善项 |
| 音频/TTS（5） | AudioExtractor、TimePitchEngine、AudioMixer、TTSServiceProtocol、SystemTTSService | R09–R11、R16、R18–R20 |
| 导出（2） | SRTExporter、VideoComposer | R01、R10、R27–R28、R31 |
| Python（2） | asr_server.py、test_e2e.py | R02、R12–R13、R21、R24–R26、R32–R33 |
| 测试/构建/资源 | XCTest 文件、Package.swift、build_app.sh、build_icon.sh、图标、忽略规则、LICENSE | 测试可运行；运行时不自包含，R13、R32 |
| 文档 | README、PRD、architecture、ui-design | 设计要求明显领先于当前实现，需要区分已实现/计划能力 |

### 已有可保留基础

- ASR 已使用明确的本地服务适配器，识别与断句代码可分离测试。
- 翻译请求携带稳定 UUID，批次执行和错误类型已形成基础；补齐集合及版本校验比重新设计协议更直接。
- 时间模型已经为 CMTime 提供显式 Codable 包装，不再依赖自动合成。
- 资源、核心库、应用层已分目录，适合逐步收敛边界；图标包含可重建脚本。
- SRT 文件写入使用 atomic 选项，优于视频导出的预删除方式，可以统一为安全输出策略。

### 设计明确要求但尚未落地的能力（与故障发现区分）

1. **核心编辑**：没有波形时间轴、可编辑起止时间、词边界提案、双语拆分预览、手动调时、问题面板和结构化撤销；Cmd+B / Cmd+J 的菜单及焦点快捷键也未实现。现在的“时间轴列表”实际上是只显示时间的字幕列表。
2. **工程恢复与配置**：没有 `.vatproject`、schema 迁移、媒体引用恢复、缓存生命周期、Keychain 或持久化设置。API key 当前在可 Codable 的配置中，但未发现实际明文写盘路径，因此不将“密钥已明文泄露”列为已确认安全问题。
3. **翻译质量控制**：无术语表、跨批次滑动上下文、人工锁定、失败/待复核状态；maxConcurrency 可在 UI 调节，但实现仍是串行批次，设置目前不生效。
4. **配音**：无背景人声分离、音色选择、超时解决流程和试听/导出统一状态；混音完成后 runFullDubbing 的结果 URL 未存入工程，导出会重新混音。
5. **断句与格式**：NaturalLanguageSegmenter 实际使用停顿/标点/字符规则，导入 NaturalLanguage 不等于已使用语义断句；未实现最大持续时间、阅读速度和通用语言排版校验。韩语、标点和更多 CJK 范围需要专门样例。
6. **交付说明**：README 的轻量安装体积、零运行时依赖、毫秒准确度、0.5 秒配音、120Hz 等表述缺乏当前实现和测量支撑。打包脚本确实只输出 dist 下的 `.app`，未发现生成 ZIP 的步骤，符合最新打包偏好。

### 需要边界测试进一步定量的风险

- `LocalASRService.swift:103–136` 将整个 WAV 读入 Data 并组装 multipart；`asr_server.py:309–313` 再整段读入并写临时文件。上传未设置大小上限，真实推理也没有应用层分块/背压和内存预算。代码已经不满足设计中的有界输入目标，但本轮没有测量小时级媒体峰值，不能据此直接声称某长度必然 OOM。
- 抽取音频、原始 TTS、变速文件、预混音和最终混音没有统一生命周期；部分文件只通过临时 URL 引用，未发现完成/失败/取消后的完整回收策略。需要测量重复处理的磁盘增长，再定义缓存配额和保留策略。
- `QwenASREngine.swift:56–80` 仍是随机时长的示例词实现，当前 AppState 使用 LocalASRService，没有把该类当作活跃生产路径重复计入 R02；它不应被误认为已完成的原生识别后端。
- 视频导出固定到舍入后的整数 nominalFrameRate，HDR/变帧率/镜像旋转是否满足目标保真度需通过媒体矩阵验证；当前测试未做像素、色彩或长期同步检查。
- ModelScope 被当作 Hugging Face endpoint 传入同一下载函数；不同服务的仓库映射与协议兼容性尚无集成验证。实际下载前应核实各源适配，而不是将枚举选项存在当作可用证明。

## 6. 验证结果及未覆盖范围

### 已执行

- `swift test`：8 项、0 失败，约 17.35 秒；本机 Ollama 返回真实中文，现有视频 fixture 存在，视频测试实际导出两个文件。
- 独立 scratch 目录 Release 构建：通过，约 12.44 秒；AudioExtractor 的 reader、readerOutput、writer、writerInput 有 4 处 non-Sendable capture 警告。它们需要收敛隔离边界，但本次未证明其本身导致运行时数据竞争，不单列为已复现崩溃。
- 两个 Shell 脚本语法检查、两个 Python 脚本 AST 语法检查：通过。
- 临时输入、假翻译服务、ASGI 和合成音频探针：复现源文件删除、错误拆分、译文丢失、重复 ID 崩溃、迟到覆盖、假转录、半模型就绪、CORS 管理写入、事件循环停顿、配音截断与重叠推移等。
- TTS exactly-once 错误：通过确定性假 PCM/结束回调验证，不依赖系统音色或真实磁盘故障。

### 没有执行或不应从本次结果推导的结论

- 未重新下载/加载真实 ASR 权重，未做完整真实视频 ASR＋翻译＋配音＋成片的 GUI 流程；避免占用正在使用的引擎和修改模型缓存。
- 未运行原 Python E2E 脚本，因为它默认写入已有 fixture 路径且验证标准不足；对此进行了源码审阅，不把它记作已通过。
- 未验证字幕烧录的逐帧可见性、字形/RTL、全屏预览、竖屏/HDR/变帧率保真、音画长期同步、长视频峰值内存、断电恢复或最低配置设备。
- 未做真实浏览器到 loopback 的攻击测试；R12 为服务应用层边界复现，不声称绕过浏览器/OS 权限。
- 未在干净 Mac/其他用户账户上部署，未做签名、公证、Gatekeeper 或 App Store 验证。构建成功不能等同于可分发。
- 未做 GUI 焦点、菜单、输入法、VoiceOver 或多窗口自动化。R14/R20/R29 等明确标出了行为验证边界。
- 未对 Python 生态依赖做漏洞数据库扫描；仓库没有锁定清单，不能据此推断依赖无漏洞。

## 7. 建议修复顺序与验收门槛

### 第一批：保护输入与编辑成果

修复 R01、R02、R04–R08、R11。建立禁止覆盖输入的统一输出层，移除生产示例回退；落实工程检查点、编辑事务、词映射、版本校验及响应验证。门槛：异常路径不删除用户文件，不丢人工文本，不崩溃，不把模拟/失败结果报告为成功。

### 第二批：收敛任务与运行时边界

修复 R03、R12–R13、R21–R26。实现可取消、有 generation 的任务协调器和可验证的 sidecar 状态机，统一存储与服务配置，隔离管理接口，准备清晰的首次安装方案。门槛：新用户可安装模型；切换项目或取消不会污染新状态；错误能定位，任务有明确终态。

### 第三批：校准配音、导出与交互

修复 R09–R10、R14–R20、R27–R31、R33，并按 UI 设计实现真正可操作的时间轴。门槛：末尾语音不被截断，发音位置符合时间轴；目标语言、预览和导出一致；编辑时播放不抢选中状态。

### 第四批：可信验证与文档

修复 R32，建立离线回归、显式可跳过的集成测试、干净环境打包测试和视觉/音频验收。README 标注完成度，所有性能指标附设备、样本及冷/热启动条件。复测以新增故障用例和已修复项为单位，不以单次 happy path 通过作为发布依据。

以上建议没有自动实施；本次 PR 的生产代码应保持与审阅基线一致。
