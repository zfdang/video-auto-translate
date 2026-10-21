import SwiftUI
import VideoAutoTranslateCore

struct EditProposalView: View {
    @ObservedObject var appState: AppState
    let proposal: AppState.EditProposal
    private var pacingIssues: Set<UUID> { TimelineAligner.pacingIssues(items: proposal.after, language: appState.project.llmConfig.targetLanguage) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览：\(proposal.title)").font(.title2)
            Text("原字幕 \(proposal.before.count) 句 → 建议 \(proposal.after.count) 句；确认前不改变工程。")
            if !pacingIssues.isEmpty {
                Label("\(pacingIssues.count) 句可能语速过快，需缩短译文或调时；建议不保证真实发音已适配。", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange).font(.caption)
            }
            List(Array(proposal.after.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 16) {
                    if proposal.before.indices.contains(index) {
                        VStack(alignment: .leading) {
                            Text("原第\(index + 1)句 \(proposal.before[index].startTime.displayFormat)–\(proposal.before[index].endTime.displayFormat)").font(.caption)
                            Text(proposal.before[index].originalText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading) {
                        Text("建议第\(index + 1)句 \(row.startTime.displayFormat)–\(row.endTime.displayFormat)").font(.caption)
                        Text(row.originalText)
                        if !row.translatedText.isEmpty { Text(row.translatedText).foregroundColor(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 4)
            }
            HStack {
                Button("取消，保留原字幕") { appState.editProposal = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用建议") { appState.applyEditProposal() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 720, height: 520)
    }
}
