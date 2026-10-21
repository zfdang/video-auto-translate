import SwiftUI
import AppKit
import VideoAutoTranslateCore

public struct ExportView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var subtitleFileMode: SubtitleExportMode = .bilingual
    @State private var videoAudioMode: VideoAudioExportMode = .translated
    @State private var videoSubtitleMode: SubtitleExportMode = .bilingual
    @State private var isExporting: Bool = false
    @State private var exportMessage: String = ""
    @State private var allowSkippingIssues = false
    private var validation: ExportValidationReport { SRTExporter().validate(items: appState.project.subtitles, mode: subtitleFileMode) }

    private var hasTranslations: Bool {
        appState.project.subtitles.contains(where: { !$0.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var hasDubbing: Bool {
        appState.project.subtitles.contains(where: { $0.dubbedAudioURL != nil })
    }

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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if validation.hasIssues {
                        VStack(alignment: .leading) {
                            Text("导出检查：\(validation.validCount)/\(validation.totalCount) 句可交付").font(.headline)
                            ForEach(validation.issues) { issue in
                                Button("定位第\(issue.row)句：\(issue.reason)") {
                                    appState.project.selectedSubtitleID = issue.itemID
                                    dismiss()
                                }.buttonStyle(.link)
                            }
                            Toggle("我明确选择跳过以上问题行", isOn: $allowSkippingIssues)
                        }
                    }
                    // 方案 1: 导出独立字幕文件
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1. 导出独立字幕文件 (.srt / .vtt)")
                            .font(.headline)

                        HStack(spacing: 14) {
                            Picker("字幕内容", selection: $subtitleFileMode) {
                                Text("双语对照").tag(SubtitleExportMode.bilingual)
                                Text("仅译文").tag(SubtitleExportMode.translatedOnly)
                                Text("仅原文").tag(SubtitleExportMode.originalOnly)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 280)

                            Spacer()

                            Button("导出 SRT") {
                                saveSubtitleFile(extensionType: "srt")
                            }
                            .disabled(appState.project.subtitles.isEmpty || (validation.hasIssues && !allowSkippingIssues))

                            Button("导出 WebVTT") {
                                saveSubtitleFile(extensionType: "vtt")
                            }
                            .disabled(appState.project.subtitles.isEmpty || (validation.hasIssues && !allowSkippingIssues))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    // 方案 2: 导出成品视频 (左右双列卡片)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("2. 导出成品视频 (.mp4)")
                                .font(.headline)
                            Spacer()
                            if hasDubbing {
                                Label("含自动配音", systemImage: "waveform")
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

                        Divider()

                        // 左右双列选项布局：左列语音，右列字幕
                        HStack(alignment: .top, spacing: 14) {
                            // 左列：语音选择
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(.accentColor)
                                    Text("语音")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }

                                if hasDubbing || hasTranslations {
                                    Picker("", selection: $videoAudioMode) {
                                        Text("自动翻译的语言").tag(VideoAudioExportMode.translated)
                                        Text("原始语言").tag(VideoAudioExportMode.original)
                                    }
                                    .pickerStyle(.radioGroup)
                                    .labelsHidden()

                                    Text(videoAudioMode == .translated ? "合成目标语言配音与闪避背景音乐（导出时自动补全整片配音）" : "保留视频原声语音轨")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 2)
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("原始语言")
                                            .font(.body)
                                        Text("未检测到翻译或配音，将使用原视频原声")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )

                            // 右列：字幕选择
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "captions.bubble.fill")
                                        .foregroundColor(.accentColor)
                                    Text("内嵌字幕")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }

                                Picker("", selection: $videoSubtitleMode) {
                                    Text("双语对照").tag(SubtitleExportMode.bilingual)
                                    Text("仅目标语").tag(SubtitleExportMode.translatedOnly)
                                    Text("仅原始语").tag(SubtitleExportMode.originalOnly)
                                    Text("没有字幕").tag(SubtitleExportMode.none)
                                }
                                .pickerStyle(.radioGroup)
                                .labelsHidden()

                                Text(subtitleModeDescription(videoSubtitleMode))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                        }

                        Divider()

                        HStack {
                            Spacer()
                            Button(action: exportDubbedVideo) {
                                HStack(spacing: 6) {
                                    Image(systemName: "film.fill")
                                    Text("合成并导出全新视频 MP4")
                                }
                                .padding(.horizontal, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .disabled(appState.project.videoURL == nil || isExporting)
                            Spacer()
                        }
                    }
                    .padding(14)
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
                        .padding(.horizontal, 4)
                    }

                    Spacer()
                }
                .padding()
            }
        }
        .frame(width: 580, height: 600)
        .onAppear {
            if hasDubbing || hasTranslations {
                videoAudioMode = .translated
            } else {
                videoAudioMode = .original
            }
        }
    }

    private func subtitleModeDescription(_ mode: SubtitleExportMode) -> String {
        switch mode {
        case .bilingual:
            return "画面底部同时压制译文与原文对照字幕"
        case .translatedOnly:
            return "画面仅压制显示翻译后的目标语言字幕"
        case .originalOnly:
            return "画面仅压制显示原始语言字幕"
        case .none:
            return "不内嵌任何字幕，输出纯净画面视频"
        }
    }

    private func saveSubtitleFile(extensionType: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "subtitles.\(extensionType)"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                let exporter = SRTExporter()
                do {
                    try exporter.saveToFile(items: appState.project.subtitles, to: url, mode: subtitleFileMode, allowSkippingIssues: allowSkippingIssues)
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
                // R01 / FU02: 校验输出路径与源视频不同（包括符号链接父目录别名）
                if destinationURL.pointsToSameFile(as: sourceVideo) {
                    exportMessage = "导出目标路径不能与原视频文件相同，请选择其他文件名或目录"
                    return
                }

                // R28: 冻结当前工程音频素材引用
                let frozenSourceAudio = appState.project.audioURL
                let currentAudioMode = videoAudioMode
                let currentSubtitleMode = videoSubtitleMode

                isExporting = true
                exportMessage = "正在准备合成导出任务..."

                Task {
                    do {
                        let shouldUseDubbedAudio = (currentAudioMode == .translated) && (hasDubbing || hasTranslations)
                        var audioToUse: URL? = nil

                        if shouldUseDubbedAudio {
                            await MainActor.run {
                                exportMessage = "正在为全片字幕生成/校验完整配音切片..."
                            }

                            // 1. 确保所有字幕配音完整生成，缺失时即时补齐，彻底杜绝后半段失声
                            try await appState.ensureAllSubtitlesDubbed { current, total in
                                Task { @MainActor in
                                    exportMessage = "正在为全片合成配音切片 (\(current)/\(total))..."
                                }
                            }

                            await MainActor.run {
                                exportMessage = "正在执行音频无损伸缩与闪避混音..."
                            }

                            let tempDir = FileManager.default.temporaryDirectory
                            let mixedAudio = tempDir.appendingPathComponent("final_mix_\(UUID().uuidString).m4a")

                            // 使用已确保具备完整配音切片的工程字幕列表
                            try await appState.audioMixer.mix(
                                backgroundAudioURL: frozenSourceAudio,
                                subtitles: appState.project.subtitles,
                                to: mixedAudio
                            )
                            audioToUse = mixedAudio
                        }

                        await MainActor.run {
                            exportMessage = "正在渲染画面字幕与音频，并执行硬件硬编导出..."
                        }

                        try await appState.videoComposer.compose(
                            videoURL: sourceVideo,
                            newAudioURL: audioToUse,
                            outputURL: destinationURL,
                            subtitles: appState.project.subtitles,
                            subtitleMode: currentSubtitleMode
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
