import SwiftUI
import AppKit
import VideoAutoTranslateCore

public struct ExportView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var subtitleFileMode: SubtitleExportMode = .bilingual
    @State private var videoSubtitleMode: SubtitleExportMode = .bilingual
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

            VStack(alignment: .leading, spacing: 18) {
                // 方案 A: 导出独立字幕文件
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 导出独立字幕文件 (.srt / .vtt)")
                        .font(.headline)

                    Picker("语言格式", selection: $subtitleFileMode) {
                        Text("双语对照").tag(SubtitleExportMode.bilingual)
                        Text("仅译文").tag(SubtitleExportMode.translatedOnly)
                        Text("仅原文").tag(SubtitleExportMode.originalOnly)
                    }
                    .pickerStyle(.radioGroup)

                    HStack(spacing: 12) {
                        Button("导出 SRT 文件") {
                            saveSubtitleFile(extensionType: "srt")
                        }
                        .disabled(appState.project.subtitles.isEmpty)

                        Button("导出 WebVTT 文件") {
                            saveSubtitleFile(extensionType: "vtt")
                        }
                        .disabled(appState.project.subtitles.isEmpty)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // 方案 B: 导出成品视频
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("2. 导出成品视频 (.mp4)")
                            .font(.headline)
                        Spacer()
                        if appState.project.subtitles.contains(where: { $0.dubbedAudioURL != nil }) {
                            Label("含新语言配音", systemImage: "waveform")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("保留原音轨", systemImage: "speaker.wave.2")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("合成高清视频画面、音频轨道，并按需执行硬件加速内嵌字幕压制。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("内嵌字幕语言：")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Picker("内嵌字幕语言", selection: $videoSubtitleMode) {
                            Text("双语对照 (译文 + 原文)").tag(SubtitleExportMode.bilingual)
                            Text("仅目标语言 (译文)").tag(SubtitleExportMode.translatedOnly)
                            Text("仅原始语言 (原文)").tag(SubtitleExportMode.originalOnly)
                            Text("不内嵌字幕 (无字幕画面)").tag(SubtitleExportMode.none)
                        }
                        .pickerStyle(.radioGroup)
                    }
                    .padding(.vertical, 2)

                    Button(action: exportDubbedVideo) {
                        HStack {
                            Image(systemName: "film.fill")
                            Text("合成并导出全新视频 MP4")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.project.videoURL == nil || isExporting)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if !exportMessage.isEmpty {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        Text(exportMessage)
                            .font(.caption)
                            .foregroundColor(isExporting ? .accentColor : .primary)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .frame(width: 520, height: 500)
    }

    private func saveSubtitleFile(extensionType: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "subtitles.\(extensionType)"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let exporter = SRTExporter()
                do {
                    try exporter.saveToFile(items: appState.project.subtitles, to: url, mode: subtitleFileMode)
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
        panel.nameFieldStringValue = "translated_video.mp4"

        panel.begin { response in
            if response == .OK, let destinationURL = panel.url {
                // R01: 校验输出路径与源视频不同
                if destinationURL.standardizedFileURL == sourceVideo.standardizedFileURL {
                    exportMessage = "导出目标路径不能与原视频文件相同，请选择其他文件名或目录"
                    return
                }

                // R28: 冻结当前工程快照，防止导出期间异步翻译或人工修改导致混合错乱
                let frozenSourceAudio = appState.project.audioURL
                let frozenSubtitles = appState.project.subtitles.map { item in
                    SubtitleItem(
                        id: item.id,
                        startTime: item.startTime,
                        endTime: item.endTime,
                        originalText: item.originalText,
                        translatedText: item.translatedText,
                        words: item.words,
                        dubbedAudioURL: item.dubbedAudioURL
                    )
                }
                let currentMode = videoSubtitleMode

                isExporting = true
                exportMessage = "正在渲染画面字幕与音频，并执行硬件硬编导出..."

                Task {
                    do {
                        let hasDubbing = frozenSubtitles.contains(where: { $0.dubbedAudioURL != nil })
                        var audioToUse: URL? = nil

                        if hasDubbing {
                            let tempDir = FileManager.default.temporaryDirectory
                            let mixedAudio = tempDir.appendingPathComponent("final_mix_\(UUID().uuidString).m4a")

                            try await appState.audioMixer.mix(
                                backgroundAudioURL: frozenSourceAudio,
                                subtitles: frozenSubtitles,
                                to: mixedAudio
                            )
                            audioToUse = mixedAudio
                        }

                        try await appState.videoComposer.compose(
                            videoURL: sourceVideo,
                            newAudioURL: audioToUse,
                            outputURL: destinationURL,
                            subtitles: frozenSubtitles,
                            subtitleMode: currentMode
                        )

                        await MainActor.run {
                            isExporting = false
                            exportMessage = "视频已成功合成并导出至: \(destinationURL.lastPathComponent)"
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
