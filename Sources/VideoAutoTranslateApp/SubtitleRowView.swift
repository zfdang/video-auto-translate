import SwiftUI
import CoreMedia
import VideoAutoTranslateCore

public struct SubtitleRowView: View {
    @ObservedObject var item: SubtitleItem
    let isSelected: Bool
    var isPlaying: Bool = false
    let rowIndex: Int
    let isMultiSelected: Bool
    let canMergeWithNext: Bool
    let onSeek: () -> Void
    let onAudition: (AppState.AuditionTarget) -> Void
    let onSplit: (Int) -> Void
    let onToggleSelect: () -> Void
    let onMergeNext: () -> Void
    let onDelete: () -> Void
    let onFocus: () -> Void

    enum FieldType {
        case original
        case translated
    }

    @FocusState private var focusedField: FieldType?
    @State private var lastActiveField: FieldType? = nil
    @State private var lastCursorIndex: Int? = nil

    /// 根据用户当前焦点与光标位置智能判定试听目标
    /// 1. 若光标选择在下方译文框：播放翻译后的语音 (.translated)
    /// 2. 若光标选择在上方原文框或未选择任何框：播放原声音频 (.original)
    private func determineAuditionTarget() -> AppState.AuditionTarget {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            if textView.string == item.translatedText {
                return .translated
            } else if textView.string == item.originalText {
                return .original
            }
        }
        if let f = focusedField {
            return f == .translated ? .translated : .original
        }
        if let last = lastActiveField {
            return last == .translated ? .translated : .original
        }
        return .original
    }

    private func performSplitAtCursor() {
        var charIndex: Int? = nil
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.string == item.originalText {
            let loc = textView.selectedRange().location
            if loc != NSNotFound {
                charIndex = loc
            }
        }
        if charIndex == nil, let cached = lastCursorIndex {
            charIndex = cached
        }

        if let idx = charIndex, idx > 0, idx < item.originalText.count {
            onSplit(idx)
        } else {
            // 光标未处于字符中间时提示用户
            NSSound.beep()
        }
    }

    public var body: some View {
        let currentTarget = determineAuditionTarget()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // 1. 多选勾选圈 (可直观勾选多行进行批量合并)
                Button(action: onToggleSelect) {
                    Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(isMultiSelected ? .accentColor : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(isMultiSelected ? "取消勾选此行" : "勾选此行以多选合并 (支持 Shift 连续多选)")

                // 行号
                Text("#\(rowIndex + 1)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)

                // 时间轴范围胶囊标签
                Button(action: onSeek) {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "clock")
                            .font(.caption2)
                            .foregroundColor(isPlaying ? .green : .secondary)
                        Text("\(item.startTime.displayFormat) ➔ \(item.endTime.displayFormat)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isPlaying ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Spacer()

                // 试听单句按钮 (智能根据焦点判定试听原声或试听译文配音)
                Button(action: {
                    let target = determineAuditionTarget()
                    onAudition(target)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: item.isGeneratingAudio ? "waveform" : (currentTarget == .translated ? "speaker.wave.2" : "play.circle"))
                        Text(item.isGeneratingAudio ? "生成中" : (currentTarget == .translated ? "试听译文" : "试听原声"))
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(item.isGeneratingAudio)
                .help(currentTarget == .translated ? "试听当前行翻译后的新配音 (光标聚焦于下方译文)" : "试听当前行原视频原声音频片段 (光标聚焦于原文或未选)")

                // 向下合并按钮 (直接与下一行合并)
                if canMergeWithNext {
                    Button(action: onMergeNext) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.merge")
                            Text("向下合并")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("直接将当前字幕与下一行 (#\(rowIndex + 2)) 合并为一行")
                }

                // 拆分按钮 (在光标所在位置拆分)
                Button(action: performSplitAtCursor) {
                    Image(systemName: "scissors")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("在光标所在字词位置拆分此行字幕 (快捷键 Cmd+B)")
            }

            // 原文字幕编辑框 (英文/源语种)
            TextField("原文内容", text: $item.originalText)
                .focused($focusedField, equals: .original)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .cornerRadius(4)
                .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notif in
                    if let textView = notif.object as? NSTextView, textView.string == item.originalText {
                        let loc = textView.selectedRange().location
                        if loc != NSNotFound {
                            self.lastCursorIndex = loc
                        }
                    }
                }
                .onChange(of: focusedField) { _, newFocus in
                    if let f = newFocus {
                        self.lastActiveField = f
                        onFocus()
                    }
                }
                .onChange(of: item.originalText) { _, _ in
                    // R16: 修改原文后使词级映射及旧配音缓存失效
                    item.words = []
                    item.dubbedAudioURL = nil
                }

            // 译文字幕编辑框 (中文/目标语种)
            TextField("译文内容 (未翻译，可直接编辑或点击上方「字幕翻译」)", text: $item.translatedText)
                .focused($focusedField, equals: .translated)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.8))
                .cornerRadius(4)
                .onChange(of: focusedField) { _, newFocus in
                    if let f = newFocus {
                        self.lastActiveField = f
                        onFocus()
                    }
                }
                .onChange(of: item.translatedText) { _, _ in
                    // R16: 修改译文后使旧配音缓存失效
                    item.dubbedAudioURL = nil
                }
        }
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) :
            (isPlaying ? Color.green.opacity(0.06) : Color.clear)
        )
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.4) :
                    (isPlaying ? Color.green.opacity(0.3) : Color.gray.opacity(0.1)),
                    lineWidth: 1
                )
        )
        .contextMenu {
            if canMergeWithNext {
                Button(action: onMergeNext) {
                    Label("与下一行合并", systemImage: "arrow.triangle.merge")
                }
            }
            Button(action: performSplitAtCursor) {
                Label("在光标处拆分字幕 (Cmd+B)", systemImage: "scissors")
            }
            Divider()
            Button(action: onDelete) {
                Label("删除此行字幕", systemImage: "trash")
            }
        }
    }
}
