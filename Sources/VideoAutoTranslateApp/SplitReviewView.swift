import SwiftUI

struct SplitReviewView: View {
    @ObservedObject var appState: AppState
    let draft: AppState.SplitDraft
    @State private var left = ""
    @State private var right = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认拆分与译文分配").font(.title2)
            if !draft.source.translatedText.isEmpty {
                Text("原译文（确认前保持完整）").font(.headline)
                Text(draft.source.translatedText).textSelection(.enabled)
            }
            if draft.source.words.isEmpty {
                Label("无字词锚点：以下时间按文字比例估算，确认后请在调时面板试听并修正。", systemImage: "exclamationmark.triangle").foregroundColor(.orange)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text(draft.left.originalText)
                    Text("结束：\(draft.left.endTime.displayFormat)").font(.caption)
                    if !draft.source.translatedText.isEmpty { TextEditor(text: $left).frame(height: 100).border(.secondary) }
                }
                VStack(alignment: .leading) {
                    Text(draft.right.originalText)
                    Text("起点：\(draft.right.startTime.displayFormat)").font(.caption)
                    if !draft.source.translatedText.isEmpty { TextEditor(text: $right).frame(height: 100).border(.secondary) }
                }
            }
            Text("请将译文分配到两句；如需稍后处理，取消会保留原字幕和完整译文。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("取消") { appState.splitDraft = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认拆分") { appState.applySplitDraft(left: left, right: right) }
                    .disabled(!draft.source.translatedText.isEmpty && (left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 640)
    }
}
