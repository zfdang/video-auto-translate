import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoAutoTranslateCore

public struct ExportView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var job: ExportJob
    @Environment(\.dismiss) private var dismiss
    @State private var subtitleMode: SubtitleExportMode = .bilingual
    @State private var videoSubtitleMode: SubtitleExportMode = .bilingual
    @State private var audioMode: VideoAudioExportMode = .original
    @State private var allowSkipping = false
    @State private var duration: Double?
    @State private var fileMessage = ""
    @State private var fileError = false

    public init(appState: AppState) { self.appState = appState; self.job = appState.exportJob }
    private var fileReport: ExportValidationReport { SRTExporter().validate(items: appState.project.subtitles, mode: subtitleMode, mediaDuration: duration) }
    private var videoReport: ExportValidationReport {
        SRTExporter().validate(items: videoSubtitleMode == .none && audioMode == .original ? [] : appState.project.subtitles,
            mode: audioMode != .original ? .bilingual : videoSubtitleMode, mediaDuration: duration)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导出成果").font(.title2)
                Spacer()
                Button(job.isRunning ? "关闭面板（任务继续）" : "关闭") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("字幕文件") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("内容", selection: $subtitleMode) {
                                ForEach(SubtitleExportMode.allCases.filter { $0 != .none }) { Text($0.displayName).tag($0) }
                            }.pickerStyle(.segmented)
                            issues(fileReport)
                            HStack {
                                Button("导出 SRT") { saveFile("srt") }
                                Button("导出 WebVTT") { saveFile("vtt") }
                            }.disabled(fileReport.validCount == 0 || (fileReport.hasIssues && !allowSkipping) || appState.project.isProcessing)
                        }.padding(8)
                    }
                    GroupBox("成品视频") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading) {
                                    Text("音频").font(.headline)
                                    Picker("音频来源", selection: $audioMode) {
                                        ForEach(VideoAudioExportMode.allCases) { Text($0.displayName).tag($0) }
                                    }.pickerStyle(.radioGroup).labelsHidden()
                                }
                                VStack(alignment: .leading) {
                                    Text("内嵌字幕").font(.headline)
                                    Picker("字幕内容", selection: $videoSubtitleMode) {
                                        ForEach(SubtitleExportMode.allCases) { Text($0.displayName).tag($0) }
                                    }.pickerStyle(.radioGroup).labelsHidden()
                                }
                            }
                            Text("本次选择：\(audioMode.displayName) · \(videoSubtitleMode.displayName)")
                                .font(.caption).foregroundColor(.secondary)
                            Text(audioMode == .translated ? "仅包含新配音，不加入原语言人声或背景音乐。" : audioMode == .overlay ? "保留完整原声（包括原人声），说话时降低原声音量；尚未提供人声分离。" : "直接保留原视频的音轨与声道。")
                                .font(.caption).foregroundColor(.secondary)
                            issues(videoReport)
                            Button("合成并导出 MP4") { saveVideo() }
                                .buttonStyle(.borderedProminent)
                                .disabled(job.isRunning || appState.project.isProcessing || appState.project.videoURL == nil || (videoReport.hasIssues && !allowSkipping) || (audioMode != .original && videoReport.validCount == 0))
                        }.padding(8)
                    }
                    if fileReport.hasIssues || videoReport.hasIssues {
                        Toggle("我明确接受跳过列出的问题行（将在结果中显示数量）", isOn: $allowSkipping)
                    }
                    if !fileMessage.isEmpty {
                        Label(fileMessage, systemImage: fileError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(fileError ? .red : .green).font(.caption)
                    }
                    if job.isRunning {
                        ProgressView(value: job.progress)
                        Text(job.message).font(.caption)
                        Button("取消导出") { job.cancel() }
                    } else if !job.message.isEmpty {
                        Label(job.message, systemImage: job.error != nil ? "exclamationmark.triangle.fill" : job.outputURL != nil ? "checkmark.circle.fill" : "info.circle")
                            .foregroundColor(job.error != nil ? .red : .secondary).font(.caption)
                        if let output = job.outputURL { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                    }
                }
            }
        }.padding(20).frame(width: 620, height: 640)
        .task {
            if let url = appState.project.videoURL { duration = try? await AVURLAsset(url: url).load(.duration).secondsValue }
        }
        .onChange(of: subtitleMode) { _, _ in allowSkipping = false }
        .onChange(of: audioMode) { _, _ in allowSkipping = false }
        .onChange(of: videoSubtitleMode) { _, _ in allowSkipping = false }
    }
    private func issues(_ report: ExportValidationReport) -> some View {
        VStack(alignment: .leading) {
            Text("可交付 \(report.validCount)/\(report.totalCount) 句").font(.caption)
            ForEach(report.issues) { issue in
                Button("定位第\(issue.row)句：\(issue.reason)") { appState.project.selectedSubtitleID = issue.itemID; dismiss() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
    private func saveFile(_ ext: String) {
        let report = fileReport
        let rejected = Set(report.issues.map(\.itemID))
        let snapshot = appState.createSubtitlesSnapshot().filter { !allowSkipping || !rejected.contains($0.id) }
        let mode = subtitleMode
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .text]
        panel.nameFieldStringValue = "subtitles." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SRTExporter().saveToFile(items: snapshot, to: url, mode: mode, allowSkippingIssues: false)
            fileError = false
            fileMessage = "已保存；明确跳过 \(allowSkipping ? fileReport.issues.count : 0) 句"
        } catch { fileError = true; fileMessage = error.localizedDescription }
    }
    private func saveVideo() {
        guard let video = appState.project.videoURL else { return }
        let report = videoReport
        let frozenBackground = appState.project.audioURL
        let voice = appState.project.llmConfig.targetLanguageVoiceCode
        guard allowSkipping || !report.hasIssues else { return }
        let rejected = Set(report.issues.map(\.itemID))
        let rows = appState.createSubtitlesSnapshot().filter { !allowSkipping || !rejected.contains($0.id) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "translated_video.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !url.pointsToSameFile(as: video) else { fileError = true; fileMessage = "请使用与源视频不同的输出文件"; return }
        job.start(video: video, background: frozenBackground, rows: rows, voice: voice,
            audioMode: audioMode, subtitleMode: videoSubtitleMode, destination: url, skipped: allowSkipping ? rejected.count : 0)
    }
}
