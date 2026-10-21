import SwiftUI

/// 使用帮助与快捷键指南视图
public struct HelpView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: HelpTab = .shortcuts

    enum HelpTab: String, CaseIterable, Identifiable {
        case shortcuts = "快捷键速查"
        case workflow = "工作流与用法"
        case faq = "常见问题解答"

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
                    Text("了解视频自动转译全流程、编辑技巧与快捷键指南")
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
                .frame(width: 300)

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
                    case .shortcuts:
                        shortcutsSection
                    case .workflow:
                        workflowSection
                    case .faq:
                        faqSection
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 720, height: 580)
    }

    // MARK: - 快捷键速查

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            shortcutGroup(
                title: "字幕快速切分与编辑",
                icon: "scissors",
                items: [
                    (keys: ["⌘", "B"], name: "光标处切分字幕", desc: "在当前原文编辑框的光标所在字符位置切分为两句，按声学词级时间戳物理对齐时间轴"),
                    (keys: ["⌘", "Z"], name: "撤销操作 (Undo)", desc: "撤销刚才的切分、合并、文字编辑或智能分句操作"),
                    (keys: ["⇧", "⌘", "Z"], name: "重做操作 (Redo)", desc: "恢复刚才被撤销的动作"),
                    (keys: ["⌘", "点击"], name: "多选相邻字幕", desc: "按住 ⌘ 连续点击 2~3 行相邻字幕，右上方【合并】按钮随即点亮可点击"),
                    (keys: ["Return"], name: "完成输入", desc: "提交当前文本框的编辑并失去焦点")
                ]
            )

            shortcutGroup(
                title: "播放控制与试听",
                icon: "play.circle",
                items: [
                    (keys: ["Space"], name: "播放 / 暂停视频", desc: "播放器聚焦时控制视频播放；字幕编辑焦点下正常输入空格"),
                    (keys: ["点击「试听」"], name: "原声片段试听", desc: "精准播放当前这一行字幕对应的原始原声音频片段，方便校对听感")
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

    // MARK: - 工作流与用法

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            workflowStepCard(
                step: "1",
                title: "导入视频",
                icon: "film",
                summary: "拖拽视频文件或点击左上角【更换视频】",
                details: "支持 MP4、MOV、MKV、AVI 等主流视频格式。导入后程序会自动解析画面规格与音频流，并载入播放器预览。"
            )

            workflowStepCard(
                step: "2",
                title: "语音转录 (ASR)",
                icon: "waveform.badge.magnifyingglass",
                summary: "使用 Apple Silicon 本地硬件加速提取高精度词级时间戳",
                details: "点击顶部【语音转录】按钮。底层集成 Qwen3-ASR 与 Qwen3-ForcedAligner，自动识别中/英/法等语种，并为每一个字词生成毫秒级物理起止时间戳。"
            )

            workflowStepCard(
                step: "3",
                title: "字幕翻译与智能分句",
                icon: "character.bubble",
                summary: "结合影视上下文进行自然流畅意译，支持大模型智能规整断句",
                details: "选择目标语言后点击【字幕翻译】。支持本地 Ollama (如 qwen2.5:latest) 或云端 API，按批次连贯意译并内置四重容错解析。若原始 ASR 断句不佳，随时可点击字幕列表右上角【智能分句】让大模型重新规划断句并回对物理时间戳。"
            )

            workflowStepCard(
                step: "4",
                title: "自动配音与智能混音 (TTS)",
                icon: "speaker.wave.3",
                summary: "多语言原生音色合成，动态变速拉伸对齐与背景音智能闪避",
                details: "点击【自动配音】为翻译后的文案合成全新音轨。程序会根据原台词物理时长自动做时间拉伸 (Time Stretching)，实现音画精准对齐，并自动压低原视频原声以保证听感舒适。"
            )

            workflowStepCard(
                step: "5",
                title: "成果导出",
                icon: "square.and.arrow.up",
                summary: "双语/单语字幕文件导出与全新音画压制高清成片",
                details: "点击【导出成片】可导出标准 SRT / WebVTT 字幕（支持双语对照、仅译文或仅原文），或压制输出包含硬字幕与新语言配音的高清视频文件，具备同路径覆盖安全拦截保护。"
            )
        }
    }

    private func workflowStepCard(
        step: String,
        title: String,
        icon: String,
        summary: String,
        details: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text(step)
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .font(.subheadline)
                    Text(title)
                        .font(.headline)
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

    // MARK: - 常见问题解答

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            faqCard(
                question: "每一行右侧的「试听」按钮播放的是原声还是翻译后的配音？",
                answer: "程序会根据您的当前光标与焦点智能判断：\n1. 若光标位于下方的【译文】输入框：播放翻译后的 TTS 新配音（按钮动态切换为「试听译文」）；\n2. 若光标位于上方的【原文】输入框，或未聚焦任何输入框：播放原视频中该句对应的【真实原声】音频片段（按钮动态切换为「试听原声」）。"
            )

            faqCard(
                question: "右侧剪刀图标是如何切分句子的？从哪里切断？",
                answer: "剪刀图标和快捷键 Cmd+B 是完全一致的功能：它直接从您当前在文本输入框中【光标所在的字符位置】将句子切开。切分后，程序会根据底层词级时间戳自动为切出的两段句子分配声学物理起止时间，无需手动计算。"
            )

            faqCard(
                question: "为什么有时「合并」按钮是灰色的？如何合并两行或三行？",
                answer: "为了确保字幕时间轴的物理连续性，合并功能要求提前选中【2 行或 3 行连续且相邻】的字幕。您可以按住 ⌘ (Command) 键依次点击相邻的两三行字幕，当满足相邻条件时，工具栏的「合并」按钮即可点击。"
            )

            faqCard(
                question: "原始识别出来的字幕断句不合理（例如把 very 和 important 拆分两行）怎么办？",
                answer: "在语音转录完成后，点击字幕列表右上角工具栏的【智能分句】按钮。大模型会通读整篇文本，按照语法逻辑在最合适的地方重新断句，程序会自动将大模型切分出的完整语义行映射回底层词级物理时间戳，重构精准的起止时间。"
            )

            faqCard(
                question: "如果我手动修改了某行字幕或译文，重新翻译或智能分句会被覆盖吗？",
                answer: "绝对不会。程序内置了严格的代际快照保护机制（Snapshot Shield），任何由您手动编辑过的原文或译文都会被标记保护，后续由大模型发起的批量翻译或规整，绝不会覆盖您的人工修改成果。"
            )

            faqCard(
                question: "使用本地 Ollama 翻译需要做哪些准备？",
                answer: "请先确保本地已安装并运行 Ollama（可在终端运行 ollama run qwen2.5:latest 下载 7B 模型）。程序启动时会自动探测 127.0.0.1:11434 端口的可用模型并提供在设置中切换。"
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
}
