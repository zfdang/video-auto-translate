# VideoAutoTranslate 技术架构设计

状态：设计基线，尚未实现。用户行为以 [PRD](PRD.md) 为准，界面及快捷键见 [UI 与交互设计](ui-design.md)。本文替代早期基于字符长度累加的拆分示例。

## 1. 架构与边界

采用 Swift / SwiftUI + MVVM，领域层以版本化命令处理字幕编辑，长任务由独立调度器执行。

```text
SwiftUI / AppKit 文本编辑器 / AVPlayer / 波形与时间轴
                       ↓ 用户命令、不可变视图快照
ProjectStore（串行状态所有者）
  ├─ EditCommand / UndoHistory / Validator
  ├─ Transcript / AlignmentSnapshot / SubtitleCue
  ├─ ProjectRepository / Autosave / AssetCache
  └─ PipelineCoordinator（带版本的结果消息）
         ├─ MediaReader / WaveformBuilder
         ├─ ASRProvider / AlignmentProvider
         ├─ TranslationProvider / ModelManager
         └─ TTSProvider / Separator / Mixer / Exporter
```

- UI 只发送命令，不直接修改领域对象。`ProjectStore` 通过串行 actor 管理项目；主线程 ViewModel 接收用于显示的快照。
- ASR、对齐、翻译、TTS、分离是不同能力接口，可以独立失败、重试或禁用，不把某个模型写进项目格式。
- MLX 路径以 CPU/GPU 为基础；不能因为运行在 Apple Silicon 上就假定会使用 ANE。Core ML 的实际计算单元另行测量。
- 原生交付不要求用户安装 Python；模型转换可在开发阶段执行，不能在用户运行时隐含依赖 Python。

## 2. 时间与工程格式

### 2.1 时间规则

运行时用 `CMTime` / `CMTimeRange` 和有理数比较；持久化保存 `value: Int64` 与 `timescale: Int32`。只接受有限、非负、epoch 为 0 的项目时间，timescale 必须大于零。禁止通过反复转成浮点秒再累加来编辑时间。

模型/API 返回浮点秒时，在适配层进行一次有限值校验及有理数转换，记录原始时间粒度；UI 格式化和模型接口允许使用浮点数。持久化精度不等于模型实际对齐精度。音频边界可以比视频帧更细；只有显式帧吸附时才按原始视频时间映射量化，变帧率媒体不能简单按固定帧率累加。

以下是可编译的序列化边界示例，不是完整领域模型；解码后必须经过项目校验器，不能把未经校验的数据直接交给编辑器。

```swift
import Foundation
import CoreMedia

struct StoredTime: Codable, Hashable, Sendable {
    let value: Int64
    let timescale: Int32

    init(_ time: CMTime) throws {
        guard time.isNumeric, time.epoch == 0,
              time.timescale > 0, time.value >= 0 else {
            throw TimeError.invalid
        }
        value = time.value
        timescale = time.timescale
    }

    func validatedTime() throws -> CMTime {
        guard timescale > 0, value >= 0 else { throw TimeError.invalid }
        return CMTime(value: value, timescale: timescale)
    }

    enum TimeError: Error { case invalid }
}

struct TextSpan: Codable, Hashable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
}

struct WordToken: Codable, Hashable, Sendable {
    let id: UUID
    let textSpan: TextSpan
    let start: StoredTime
    let end: StoredTime
}
```

`StoredTime` 的结构相等不代表时间相等（如 1/2 与 2/4）；排序、比较和相等性判断用验证后的 `CMTime`。`TextSpan` 是某一固定文本版本上的 UTF-16 范围，用于桥接 AppKit；执行编辑前必须转为合法的 Swift `String.Index`，并验证字素边界，禁止混用 UTF-16 偏移与 `String.count`。

### 2.2 数据实体

| 实体 | 主要字段与职责 |
| --- | --- |
| Project | schemaVersion、projectID、单调 revision、源媒体引用及指纹、轨道顺序、配置引用 |
| TranscriptSnapshot | 不可变识别原文、识别语言、引擎/模型版本、分块来源 |
| AlignmentSnapshot | 不可变 sourceText、sourceRevision、词的文本范围和全局媒体时间、语言/模型版本、可用/过期/不支持状态 |
| SubtitleCue | 稳定 cueID、trackID、顺序、sourceText/sourceRevision、targetText/targetRevision、显示 start/end、独立 timingRevision、人工边界保护、对齐引用、翻译状态及锁定状态 |
| CueAlignmentBinding | cueID、sourceRevision、snapshotID、词 ID 与当前原文范围的映射；拆分/合并后重新映射，不修改历史快照 |
| PendingTranslation | 原 cue 的译文及版本、拆分来源、尚待分配的子 cueID；保存恢复必须完整 |
| GeneratedArtifact | 输入指纹、阶段、资源相对路径、实际时长、状态、引擎/模型/音色版本 |
| EditTransaction | 操作 ID、修改前后值、创建/删除 ID、选择恢复信息、人工保护及派生状态 |

原文、词时间和字幕显示时间分开保存。译文不共享原文的字符索引，也不假定逐词一一对应。字幕序号仅是显示编号，不能作为持久化标识或异步结果的目标键。

工程使用带扩展名 `.vatproject` 的目录包：`manifest.json`、版本化领域数据、`assets/` 派生资源及缩略图/波形缓存。源媒体默认外部引用，提供可移植副本选项；沙盒模式使用 security-scoped bookmark，并支持失效后重新授权。源文件指纹不匹配时要求确认，不复用旧对齐。

自动保存串行化不可变项目快照，先写临时文件再原子替换，保留最后成功检查点。清理生成缓存不能删除源媒体、未分配译文或撤销历史仍引用的资源。schema 迁移先备份，未来版本文件以只读方式提示兼容性问题。

## 3. 编辑内核

### 3.1 不变量与校验

- `0 ≤ start < end ≤ mediaDuration`，新拆分区间至少 100ms。
- 词范围必须落在其绑定的文本版本内且位于合法字素边界；词时间必须可验证，重叠词不能直接作为自动拆分边界。
- 同轨道正常编辑不能新增重叠；导入遗留冲突进入问题列表。修复允许降低原有冲突，不要求用户一次消除全项目问题。
- 一个 cue 可处于待对齐或待翻译状态，这不是禁止保存的理由。导出校验按输出轨道/语言区分阻塞错误与警告。
- 修改通过“读取当前版本 → 构造候选 → 验证受影响区域 → 原子提交”，失败不留下部分变化。

### 3.2 拆分流程

`SplitIntent` 包含 cueID、预期版本、入口（文本/播放头）、期望文字位置或时间。先计算 `SplitProposal`，再根据是否存在歧义或译文分配需求决定直接提交或进入预览。

1. 确认焦点、输入法组合状态、源文本版本及 alignment binding 有效；过期映射不能参与自动选择。
2. 从词的显式文本范围获得候选，标点/空格归属通过文本切片规则确定；任何自动 trim 都不得改变文字归属而不更新映射。
3. 词内光标选最近词边界，距离相同选前边界，并预览吸附后的文字断点。词间停顿默认以两词之间的时间中点为切点；无可靠时间时进入人工时间选择。
4. 检查两边非空、最小时长、媒体范围及邻接约束。首尾位置或无有效候选返回明确原因，禁止退回到 `startTime` 伪造断点。
5. 构造两个新 cueID 和来源关系，原 cue 进入事务历史。左区间 `[start, split)`，右区间 `[split, end)`；词引用分配到对应子句，文本范围按子句重新映射。
6. 已有译文由用户独立选择译文断点；暂缓时创建 PendingTranslation，两个子句 targetText 留空但带明确待分配状态，原译文保留在工程及历史中。不得按字符比例生成假对应。
7. 新 cue 的配音状态失效，单次事务提交并选中右句；撤销恢复原 ID、全部文本、时间和资源引用。

### 3.3 合并、移动与边界调整

- 合并按项目轨道顺序排序并验证连续性。区间为首 cue.start 至末 cue.end，词时间保持原样；文本按语言规则拼接并重建范围映射。待分配译文记录重定向到新 cue，不丢失来源。
- 普通边界拖动只更新所选 cue；整句拖动起止等量移动；共享边界仅限首尾相接的同轨相邻两句，交界两侧作为同一事务更新。
- 拖动过程在临时交互状态计算和显示，不反复保存、触发翻译或堆积撤销项；松开提交，Escape 取消。提交时重新验证起始版本，冲突时要求重新操作。
- 吸附默认屏幕距离 6px，可在设置中调整；同距离时依次选择词边界、邻句边界、停顿中点、视频帧，候选必须通过约束检查。Alt/Option 暂停吸附。缩放改变时间容差，不改变精度。
- 手工调时设置边界保护。重新对齐只更新可用锚点或生成建议，不隐式改变受保护显示时间。

### 3.4 改字、撤销与并发

原文编辑提交时递增 sourceRevision，通过文本 diff 尝试重映射未修改范围；不能证明有效的 token 标记失效，并为受影响语音区间加上下文运行局部对齐。改变译文递增 targetRevision；调时递增 timingRevision，避免仅调整时间就重复调用 TTS。

UndoManager 面向编辑事务；连续打字可分组合并，拖动、拆分和合并各是一条记录。后台任务完成不自动注册用户撤销项；应用建议才形成编辑事务。撤销恢复语义内容但项目 revision 始终递增，新的任务代次不得复用，避免旧请求在撤销后恰好匹配旧版本。

每次任务携带 projectID、cueID、stage、generationID、输入内容指纹。结果写回需同时验证目标存在、generationID 仍有效及输入指纹一致；否则丢弃结果，可保留为未绑定缓存，不能复活已删除 cue 或覆盖人工编辑。取消只是减少工作，写回校验仍必须执行。

## 4. 媒体与模型管道

### 4.1 音频读取、波形与对齐

- `AVURLAsset` 异步加载信息，`AVAssetReader` 分块解码，背压限制 PCM 缓冲。ASR 适配器按其输入要求重采样；对齐器独立声明采样率，不直接复用不兼容特征。
- 统一保留媒体全局时间；分块结果恢复原始偏移，重叠窗口进行词去重及边界协调。VAD 删去静音的压缩时间不得直接作为视频时间。
- 对齐模型窗口限制通过可配置分块满足，跨块边界需验证。不支持对齐的语言降级为句级，不捏造词时间。
- 波形离线构建多层级 min/max 峰值缓存，时间轴只读取可视区；UI 不在主线程解码全音频或绘制全部字幕。
- ModelManager 管理下载、校验、版本、离线缓存和内存预算。模型尽量跨任务复用；ASR、对齐及本地 LLM 按测得内存串行或限并发，不能默认同时常驻 8GB 设备。

### 4.2 自动断句

在有效词边界上计算停顿、标点、语义、阅读速度及行宽代价，再满足最大持续时间和最小片段约束。连续讲话超过上限时选择合适词边界继续分段，文字全部保留；无法同时满足时保留内容并发出可读性问题，禁止只缩短结束时间。

识别预设可以参考保守/标准/弱音场景，但参数按 Qwen/VAD 实测调优，不照搬 Whisper 阈值。归一化仅用于识别副本，不能改变最终原声混音。

### 4.3 翻译

Ollama 探测使用 `/api/tags`；OpenAI 兼容服务用其对应适配器，规范化 Base URL，避免重复 `/v1`。原生协议不同的服务另设适配器，不承诺单一协议覆盖所有厂商。

批次请求包含稳定 cueID、上下文、术语表及目标语言，返回按 ID 解析并校验缺失、重复、空结果与异常说明文字。锁定译文跳过覆盖。失败保存可重试状态，不以原文充当成功结果。限流退避、超时和取消由 PipelineCoordinator 管理；不同服务的推理开关等参数由适配器声明，不能给所有模型发送同一组非标准字段。

### 4.4 配音与依赖失效

| 变化 | 必须失效/复核 | 可以复用 |
| --- | --- | --- |
| 原文修改 | 受影响对齐、翻译待复核；原文发音模式下 TTS | 未受影响词、源音频 |
| 译文/音色/语言修改 | 对应句 TTS、伸缩、混音 | 源对齐、背景分离 |
| 时间窗口修改 | 伸缩、调度、混音 | 文本与音色相同的原始 TTS |
| 闪避参数修改 | 混音 | 原始/变速后 TTS、背景分离 |
| 拆分/合并 | 新 cue 对齐映射、翻译复核、配音绑定 | 不可变源词时间、分离背景 |

合成原音频时长为 Dtts，目标窗口为 Dtarget，初始速率为 clamp(Dtts / Dtarget, 0.6, 1.8)。`AVAudioEngine` 离线渲染后测量真实 Dout；当 Dout > Dtarget 时标记超时，由用户选择压缩译文、借用可用空白或修改窗口，禁止裁去语音。短于窗口的配音保留尾部静音，不强迫过度慢放。

Core ML 人声分离的具体模型、转换和授权由 M0/M3 验证；Demucs 是候选，不能把未提供的转换产物视为可用依赖。混音保留背景立体声与原始采样率，依据真实配音区间合并闪避包络，处理攻击/恢复、响度及峰值。试听与导出使用同一包络和时间映射。

### 4.5 任务与导出

阶段状态：idle / queued / running / succeeded / failed / cancelled / stale；失败携带阶段、用户可理解原因及重试入口。允许只重试失败片段。长任务活动断言仅在任务执行期间持有，结束或取消后释放，不能应用一启动就长期禁止休眠。

SRT/VTT 以快照导出，在最终格式化时量化到毫秒并再次校验，避免极短区间经舍入后变成零时长。项目保留更高精度。导出先写临时目标，完成后原子交付；取消/失败清理半成品并保留工程。

视频导出区分软字幕封装、无需重编码的复用和需要重编码的硬字幕。能力矩阵涵盖容器、字幕编码、旋转、色彩/HDR、变帧率及音轨；不能用“VideoToolbox 支持”替代完整管道验证。

## 5. 技术验证与回归范围

M0 固定 Swift 包版本/提交与模型权重版本，验证签名应用内 Metal 资源加载、离线启动、授权、不同语言和长音频；输出设备与峰值内存报告后确定最低系统及内存要求。

编辑内核回归覆盖：Unicode/空格映射、词内拆分、空词/失效词、译文重排、反向及非连续选择、长停顿、边界限制、撤销后的迟到任务、工程保存恢复。UI 验收覆盖输入法、焦点快捷键、缩放吸附、跟随暂停及 VoiceOver。完整场景与性能目标见 PRD；这些是待实现验收条件，不代表当前仓库已有测试通过。

## 6. 外部参考与采用边界

- [Qwen3-ASR 官方项目](https://github.com/QwenLM/Qwen3-ASR)：识别与对齐是独立能力，对齐语言与窗口范围需分别核实。
- [MLX](https://github.com/ml-explore/mlx)：CPU/GPU 和统一内存路径；不推导为 ANE 自动加速。
- [mlx-audio-swift](https://github.com/hehehai/mlx-audio-swift)：原生 ASR/对齐集成候选，集成前固定版本并验证模型、资源打包及许可证。
- [AutoSubtitle 转录实现（审阅版本）](https://github.com/Linwei-Chen/AutoSubtitle/blob/78cfb92140f830f82e3b49e649db29d2ce5f5083/engines/whisper_engine.py)：参考词间停顿、识别场景预设与模型复用；不采用丢弃词时间或只截短显示时间的做法。
- [AutoSubtitle 任务实现（审阅版本）](https://github.com/Linwei-Chen/AutoSubtitle/blob/78cfb92140f830f82e3b49e649db29d2ce5f5083/main.py)：参考阶段进度和逐文件错误隔离；改进取消、检查点和翻译失败状态。仅作设计参考，不复制其代码；若后续复用需先核实授权文件。
