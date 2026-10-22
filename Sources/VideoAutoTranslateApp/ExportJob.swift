import Foundation
import AVFoundation
import Combine
import VideoAutoTranslateCore

@MainActor public final class ExportJob: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var progress = 0.0
    @Published public private(set) var message = ""
    @Published public private(set) var error: String?
    @Published public private(set) var outputURL: URL?
    private var task: Task<Void, Never>?

    public func start(video: URL, background: URL?, rows: [SubtitleItem], voice: String, audioMode: VideoAudioExportMode, subtitleMode: SubtitleExportMode, destination: URL, skipped: Int, ttsService: TTSServiceProtocol? = nil) {
        guard !isRunning else { return }
        let snapshot = rows.map { $0.snapshot() }
        isRunning = true
        progress = 0
        error = nil
        outputURL = nil
        message = "正在准备导出…"
        task = Task {
            do {
                var audio: URL?
                defer { if let audio { try? FileManager.default.removeItem(at: audio) } }
                try Task.checkCancellation()
                if audioMode != .original {
                    let manager = SubtitleManager()
                    let tts = ttsService ?? EdgeTTSService()
                    for (index, row) in snapshot.enumerated() {
                        try Task.checkCancellation()
                        message = "生成配音 \(index + 1)/\(snapshot.count)"
                        if !row.hasCurrentAudio(voice: voice) { try await manager.reDub(item: row, ttsService: tts, voice: voice) }
                        guard row.hasCurrentAudio(voice: voice) else { throw TTSError.synthesisFailed("配音未完成，未导出不完整成片") }
                        progress = Double(index + 1) / Double(max(1, snapshot.count)) * 0.5
                    }
                    try Task.checkCancellation()
                    message = "正在混音…"
                    let mixed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                    audio = mixed
                    try await AudioMixer().mix(backgroundAudioURL: audioMode == .overlay ? (background ?? video) : nil, subtitles: snapshot, to: mixed)
                }
                try Task.checkCancellation()
                progress = 0.75
                message = "正在渲染视频…"
                try await VideoComposer().compose(videoURL: video, newAudioURL: audio, outputURL: destination, subtitles: snapshot, subtitleMode: subtitleMode)
                try Task.checkCancellation()
                outputURL = destination
                progress = 1
                message = "已导出 \(destination.lastPathComponent)；字幕 \(subtitleMode == .none ? 0 : snapshot.count) 句，明确跳过 \(skipped) 句"
            } catch is CancellationError { message = "导出已取消" }
            catch { self.error = error.localizedDescription; message = "导出失败：\(error.localizedDescription)" }
            isRunning = false
            task = nil
        }
    }

    public func cancel() { task?.cancel(); message = "正在取消导出…" }
}
