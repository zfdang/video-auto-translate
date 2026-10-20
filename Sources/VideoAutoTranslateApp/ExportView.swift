import SwiftUI
import AppKit
import VideoAutoTranslateCore

public struct ExportView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var subtitleMode: SubtitleExportMode = .bilingual
    @State private var isExporting: Bool = false
    @State private var exportMessage: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导出成果")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // 方案 A: 导出字幕文件
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 导出字幕文件 (.srt / .vtt)")
                        .font(.headline)

                    Picker("语言格式", selection: $subtitleMode) {
                        Text("双语对照").tag(SubtitleExportMode.bilingual)
                        Text("仅译文").tag(SubtitleExportMode.translatedOnly)
                        Text("仅原文").tag(SubtitleExportMode.originalOnly)
                    }
                    .pickerStyle(.radioGroup)

                    HStack {
                        Button("导出 SRT 文件") {
                            saveSubtitleFile(extensionType: "srt")
                        }
                        Button("导出 WebVTT 文件") {
                            saveSubtitleFile(extensionType: "vtt")
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // 方案 B: 导出全新配音视频
                VStack(alignment: .leading, spacing: 10) {
                    Text("2. 导出多语言替换配音视频 (.mp4)")
                        .font(.headline)
                    Text("包含原始视频画面、新语言自然配音、自适应语速对齐与背景音自动闪避混音。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: exportDubbedVideo) {
                        HStack {
                            Image(systemName: "film")
                            Text("合成并导出全新视频 MP4")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.project.videoURL == nil || isExporting)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if !exportMessage.isEmpty {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }

                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 420)
    }

    private func saveSubtitleFile(extensionType: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "subtitles.\(extensionType)"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let exporter = SRTExporter()
                do {
                    try exporter.saveToFile(items: appState.project.subtitles, to: url, mode: subtitleMode)
                    exportMessage = "字幕已成功保存至: \(url.lastPathComponent)"
                } catch {
                    exportMessage = "保存字幕失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportDubbedVideo() {
        guard let sourceVideo = appState.project.videoURL else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dubbed_video.mp4"

        panel.begin { response in
            if response == .OK, let destinationURL = panel.url {
                isExporting = true
                exportMessage = "正在渲染混音并执行硬件加速编码..."

                Task {
                    do {
                        let tempDir = FileManager.default.temporaryDirectory
                        let mixedAudio = tempDir.appendingPathComponent("final_mix_\(UUID().uuidString).m4a")

                        try await appState.audioMixer.mix(
                            backgroundAudioURL: appState.project.audioURL,
                            subtitles: appState.project.subtitles,
                            to: mixedAudio
                        )

                        try await appState.videoComposer.compose(
                            videoURL: sourceVideo,
                            newAudioURL: mixedAudio,
                            outputURL: destinationURL
                        )

                        await MainActor.run {
                            isExporting = false
                            exportMessage = "视频已成功合成并导出！"
                        }
                    } catch {
                        await MainActor.run {
                            isExporting = false
                            exportMessage = "导出失败: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}
