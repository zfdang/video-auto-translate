import SwiftUI

/// 使用帮助与快捷键指南视图
public struct HelpView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: HelpTab = .workflow

    enum HelpTab: String, CaseIterable, Identifiable {
        case workflow = "工作流与用法"
        case faq = "常见问题解答"
        case shortcuts = "快捷键速查"

        var id: String { rawValue }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("使用帮助与快捷键")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("了解视频自动转译全流程、智能断句调时技巧与快捷键指南")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Picker("", selection: $selectedTab) {
                    ForEach(HelpTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // 内容展示区
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .workflow:
                        workflowSection
                    case .faq:
                        faqSection
                    case .shortcuts:
                        shortcutsSection
                    }
                }
                .padding(24)
            }
            .id(selectedTab)
        }
        .frame(width: 740, height: 600)
    }

    // MARK: - 1. 工作流与用法

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            workflowStepCard(
                step: "1",
                title: "导入视频",
                icon: "film",
                summary: "拖拽视频文件或点击顶部【更换视频】载入媒体",
                details: "支持 MP4、MOV、MKV、AVI 等主流视频格式。导入后程序自动解析画面规格与音轨，载入播放器预览。支持随时保存工程与自动状态恢复。"
            )

            workflowStepCard(
                step: "2",
                title: "语音转录与词对齐 (ASR)",
                icon: "waveform.and.mic",
                summary: "使用 Apple Silicon 本地硬件加速提取毫秒级逐词时间戳",
                details: "选择原语言（或默认自动识别），点击【语音转录】。底层由本地 Qwen3-ASR 与 Qwen3-ForcedAligner 驱动，精确捕捉每一个单词或单字的物理起止时间戳。"
            )

            workflowStepCard(
                step: "★",
                title: "智能分句（大模型语义重构）",
                icon: "sparkles",
                summary: "在翻译前执行：通读上下文语义重新断句，并回对物理词边界",
                details: "语音转录完成后，若识别出的断句较碎或断在固定短语中间，可点击字幕列表顶部的【智能分句】。大模型会按自然语法逻辑规划完整句子，并毫秒级吸附底层词对齐时间戳。若需局部调整，也可使用剪刀图标 (⌘+B) 在光标处拆分或多选合并。",
                isHighlight: true
            )

            workflowStepCard(
                step: "3",
                title: "字幕翻译 (LLM)",
                icon: "character.book.closed.fill",
                summary: "大模型结合影视上下文深度连贯意译为目标语言",
                details: "在步骤 3 菜单选择目标语言后点击【字幕翻译】。支持本地 Ollama (如 qwen2.5:latest) 或云端 API，按批次连贯意译并内置四重容错解析，生成口语化双语字幕。"
            )

            workflowStepCard(
                step: "★",
                title: "匹配译文时间轴（局部语境同步）",
                icon: "waveform.badge.clock",
                summary: "同语境句子共享时间，保持每组开头和结尾同步",
                details: "字幕翻译完成后、配音前，点击字幕列表顶部的【匹配译文时间轴】。系统使用所选音色生成并缓存正常语速音频，将同语境的相邻句子分组，保持每组的开头和结尾与原视频一致；组内每句起止位置可以调整，让长短句共享时间。短句自然说完后留白；必要时在本步骤自动适配语速，偏快只作提示，每句都会准备可播放配音。预览前后时间并试听匹配结果后再应用，可撤销。生成、试听和导出复用确认后的配音，不会重新调整语速或起始时间。",
                isHighlight: true
            )

            workflowStepCard(
                step: "4",
                title: "自动配音与智能混音 (TTS) [可选]",
                icon: "speaker.wave.2.fill",
                summary: "合成全新母语级配音，自适应语速对齐与背景音自动闪避",
                details: "点击【自动配音】为翻译后的字幕合成语音。程序基于匹配后的时间区间微调语速，并自动压低原视频原声（音频闪避 Ducking）与配音交融。也可以点击单行右侧的「译文」按钮试听单句配音效果。此步骤为可选，可直接进入第 5 步导出字幕或视频。"
            )

            workflowStepCard(
                step: "5",
                title: "成果导出",
                icon: "square.and.arrow.up.fill",
                summary: "导出双语/单语字幕文件，或压制音画同步高清成片",
                details: "点击【导出成片】可导出标准双语/单语 SRT 字幕，或压制输出包含硬字幕与新配音的高清视频。导出面板提供纯译文配音、保留原声压低叠加、原音轨三种音频导出模式，并具备同路径覆盖安全保护。"
            )
        }
    }

    private func workflowStepCard(
        step: String,
        title: String,
        icon: String,
        summary: String,
        details: String,
        isHighlight: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isHighlight ? Color.purple.opacity(0.18) : Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text(step)
                    .font(.system(size: isHighlight ? 15 : 16, weight: .bold))
                    .foregroundColor(isHighlight ? .purple : .accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(isHighlight ? .purple : .accentColor)
                        .font(.subheadline)
                    Text(title)
                        .font(.headline)
                    if isHighlight {
                        Text("关键进阶")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .foregroundColor(.purple)
                            .cornerRadius(4)
                    }
                }

                Text(summary)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Text(details)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
    }

    // MARK: - 2. 常见问题解答

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            faqCard(
                question: "什么时候使用「智能分句」？",
                answer: "请在「步骤 2: 语音转录」完成后、点击「步骤 3: 字幕翻译」之前使用。\n原始语音识别断句有时较为零散或切断了固定词组。点击【智能分句】后，大模型会通读全文并依据语法完整度重构长短句，并精确吸附回底层的声学词物理时间戳。注意：为保护译文劳动成果，已有译文时建议使用行内剪刀拆分与合并进行局部调整。"
            )

            faqCard(
                question: "什么是「匹配译文时间轴」？为什么要在配音前点击它？",
                answer: "请在「步骤 3: 字幕翻译」完成后、点击「步骤 4: 自动配音」之前使用。\n系统会实测当前音色的正常发音时长，而非按全片或局部平均分配时间。同语境的临近句子组成局部 cluster，每组的开头和结尾固定在原视频位置，组内句子的起止时间可以调整，共享时间预算，平衡语速。明显停顿和组的外边界保持不变，不会全片累积漂移。语速偏快时仍能试听和继续生成、导出，不需要逐句手动处理。组内时间安排和必要调速均在匹配步骤完成，可试听确认后应用；后续配音生成不再调整语速或起始位置。字幕内容不会被自动改写。"
            )

            faqCard(
                question: "右侧剪刀图标是如何切分字幕的？",
                answer: "剪刀图标和快捷键 Cmd+B 对应相同的功能：\n必须在【原文字幕】输入框中将光标置于字词之间（非首尾），点击剪刀图标即可在此处切开为前后两句。切分时时间轴物理对齐，原译文完整保留在前半句，后半句译文留空（后续重新翻译即可填充）。"
            )

            faqCard(
                question: "每一行右侧的「原声」和「译文」按钮是做什么的？",
                answer: "1. 点击「原声」：精准播放原视频中该行对应的真实原声音频片段，方便核对听感与发音；\n2. 点击「译文」：在当前行已有翻译时出现，点击即可单独试听该句合成后的 TTS 译文配音，用于快速校验译文发音与语速。"
            )

            faqCard(
                question: "为什么有时工具栏上的「合并」按钮是灰色的？如何多选合并？",
                answer: "为了保证字幕时间轴的连续性，合并功能要求提前选中【2 行或多行连续且相邻】的字幕。您可以点击每行最左侧的【圆形勾选框】，或按住 ⌘ (Command) 键依次点击相邻行字幕，当满足多选相邻条件时，顶部的【合并】按钮即可点亮点击。"
            )

            faqCard(
                question: "如果我手动修改了某行字幕或译文，重新翻译或智能分句会被覆盖吗？",
                answer: "重新翻译会跳过已有且未标记需复核的译文，只处理未翻译或因原文修改而需要复核的行。修改原文后，请校对对应译文：直接修改译文即可确认；若译文无需改字，点击该行「确认译文」。拆分、合并会保留未确认状态，字幕和视频导出使用同样的校对要求。请求发出后再手动修改的原文或译文，不会被该批返回结果覆盖。已有译文时，智能分句会提示停止；请使用行内拆分或合并做局部调整。"
            )

            faqCard(
                question: "使用本地 Ollama 翻译需要做哪些准备？",
                answer: "请确保本地已安装并运行 Ollama（可在终端执行 ollama run qwen2.5:latest 下载 7B 模型）。程序启动时会自动探测 127.0.0.1:11434 端口的可用模型，也可在设置中自由切换云端 API 或本地模型。"
            )
        }
    }

    private func faqCard(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.subheadline)
                Text(question)
                    .font(.subheadline)
                    .fontWeight(.bold)
            }

            Text(answer)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
    }

    // MARK: - 3. 快捷键速查

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            shortcutGroup(
                title: "字幕快速切分与编辑",
                icon: "scissors",
                items: [
                    (keys: ["⌘", "B"], name: "光标处拆分字幕", desc: "在当前原文编辑框的光标所在字符位置切分为两句，按声学词级时间戳物理对齐时间轴"),
                    (keys: ["⌘", "Z"], name: "撤销操作 (Undo)", desc: "撤销刚才的切分、合并、文字编辑或智能分句操作"),
                    (keys: ["⇧", "⌘", "Z"], name: "重做操作 (Redo)", desc: "恢复刚才被撤销的操作"),
                    (keys: ["⌘", "点击"], name: "多选相邻字幕", desc: "按住 ⌘ 连续点击 2~3 行相邻字幕，右上方【合并】按钮随即点亮可点击"),
                    (keys: ["Return"], name: "完成输入", desc: "提交当前文本框的编辑并失去焦点")
                ]
            )

            shortcutGroup(
                title: "播放控制与试听",
                icon: "play.circle",
                items: [
                    (keys: ["Space"], name: "播放 / 暂停视频", desc: "播放器聚焦时控制视频播放；字幕编辑焦点下正常输入空格"),
                    (keys: ["点击「原声」"], name: "单句原声试听", desc: "精准播放当前行字幕对应的原始原声音频片段，方便校对听感"),
                    (keys: ["点击「译文」"], name: "单句配音试听", desc: "单独播放该行合成后的新语种配音，用于快速校验译文发音与语速")
                ]
            )

            shortcutGroup(
                title: "全局与系统快捷键",
                icon: "command",
                items: [
                    (keys: ["⌘", ","], name: "打开偏好设置", desc: "打开模型下载、本地 ASR 引擎端口与 Ollama / 云端模型设置"),
                    (keys: ["⌘", "Shift", "E"], name: "导出成片与字幕", desc: "打开双语字幕导出与音画压制导出面板")
                ]
            )
        }
    }

    private func shortcutGroup(
        title: String,
        icon: String,
        items: [(keys: [String], name: String, desc: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            VStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { idx in
                    let item = items[idx]
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            ForEach(item.keys, id: \.self) { k in
                                keyCapView(text: k)
                            }
                        }
                        .frame(width: 140, alignment: .leading)

                        Text(item.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(width: 130, alignment: .leading)

                        Text(item.desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .cornerRadius(8)
                }
            }
        }
    }

    private func keyCapView(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
    }
}
