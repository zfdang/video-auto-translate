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

    private func performSplitAtCursor() {
        var charIndex: Int? = nil
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.string == item.originalText {
            let loc = textView.selectedRange().location
            if loc != NSNotFound {
                charIndex = SubtitleManager.characterOffset(in: item.originalText, utf16Offset: loc)
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

                // 试听原声按钮 (播放原视频对应时间戳的原声音频)
                Button(action: {
                    onAudition(.original)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "play.circle")
                        Text("试听原声")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .help("试听当前行原视频原声音频片段")

                // 试听译文按钮 (播放/合成翻译后的配音语音)
                let hasTranslation = !item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: {
                    onAudition(.translated)
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: item.isGeneratingAudio ? "waveform" : "speaker.wave.2")
                        Text(item.isGeneratingAudio ? "生成中" : "试听译文")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(item.isGeneratingAudio || !hasTranslation)
                .help(hasTranslation ? "试听当前行翻译后的新配音语音" : "暂无译文，请先执行字幕翻译")

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
                    if focusedField == .original, let textView = notif.object as? NSTextView, textView.string == item.originalText {
                        let loc = textView.selectedRange().location
                        if loc != NSNotFound {
                            self.lastCursorIndex = SubtitleManager.characterOffset(in: item.originalText, utf16Offset: loc)
                        }
                    }
                }
                .onChange(of: focusedField) { _, newFocus in
                    if let f = newFocus {
                        self.lastActiveField = f
                        onFocus()
                    }
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

            if item.translationNeedsReview {
                Label("译文待复核：原文或目标语言已改变", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
                Button("已确认译文属于当前目标语言") { item.translationNeedsReview = false }
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
            Button(action: { onAudition(.original) }) {
                Label("试听原声", systemImage: "play.circle")
            }
            if !item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: { onAudition(.translated) }) {
                    Label("试听译文配音", systemImage: "speaker.wave.2")
                }
            }
            Divider()
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
