import SwiftUI
import CoreMedia
import VideoAutoTranslateCore

public struct SubtitleRowView: View {
    @ObservedObject var item: SubtitleItem
    let isSelected: Bool
    var isPlaying: Bool = false
    let onSeek: () -> Void
    let onAudition: () -> Void
    let onSplit: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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

                // 试听单句配音按钮
                Button(action: onAudition) {
                    HStack(spacing: 2) {
                        Image(systemName: item.isGeneratingAudio ? "waveform" : "play.circle")
                        Text(item.isGeneratingAudio ? "生成中" : "试听")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(item.isGeneratingAudio)

                // 拆分按钮
                Button(action: onSplit) {
                    Image(systemName: "scissors")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("从中间拆分此行字幕")
            }

            // 原文字幕编辑框 (英文/源语种)
            TextField("原文内容", text: $item.originalText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .cornerRadius(4)
                .onChange(of: item.originalText) { _, _ in
                    // R16: 修改原文后使词级映射及旧配音缓存失效
                    item.words = []
                    item.dubbedAudioURL = nil
                }

            // 译文字幕编辑框 (中文/目标语种)
            TextField("译文内容 (未翻译，可直接编辑或点击上方「字幕翻译」)", text: $item.translatedText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.8))
                .cornerRadius(4)
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
    }
}
