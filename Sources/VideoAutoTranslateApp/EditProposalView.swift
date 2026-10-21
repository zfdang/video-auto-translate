import SwiftUI
import AVFoundation
import VideoAutoTranslateCore

struct EditProposalView: View {
    @ObservedObject var appState: AppState
    let proposal: AppState.EditProposal
    @State private var audition: AVPlayer?

    private var conflicts: Int { proposal.after.filter { $0.dubbingTimingIssue != nil }.count }

    private func play(_ url: URL) {
        audition?.pause()
        audition = AVPlayer(url: url)
        audition?.play()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.title).font(.title2)
            Text("预览修改前后的时间与内容；应用后可撤销。")
                .foregroundStyle(.secondary)
            if conflicts > 0 {
                Label("\(conflicts) 句配音超长。应用时间建议后，仍需精简译文或手动调时才能配音。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(proposal.after.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(index + 1) 句").font(.headline)
                            if let before = proposal.before.first(where: { $0.id == row.id }) {
                                Text("原来：\(before.startTime.displayFormat) → \(before.endTime.displayFormat)")
                                    .foregroundStyle(.secondary)
                            }
                            Text("建议：\(row.startTime.displayFormat) → \(row.endTime.displayFormat)")
                            Text(row.originalText).foregroundStyle(.secondary)
                            if !row.translatedText.isEmpty { Text(row.translatedText) }
                            if let audio = row.currentNaturalSpeech {
                                Text(String(format: "正常语速配音：%.2f 秒", audio.duration)).font(.caption)
                                HStack {
                                    Button("试听正常语速") { play(audio.url) }
                                    if row.hasCurrentAudio(voice: proposal.voice), let url = row.dubbedAudioURL {
                                        Button("试听匹配结果") { play(url) }
                                        Text(String(format: "建议语速：%.2f 倍", max(1, audio.duration / row.durationSeconds)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let issue = row.dubbingTimingIssue {
                                Text(issue).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { appState.editProposal = nil }
                    .keyboardShortcut(.cancelAction)
                Button("应用建议") { appState.applyEditProposal() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onDisappear { audition?.pause(); audition = nil }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 400, idealHeight: 560)
    }
}
