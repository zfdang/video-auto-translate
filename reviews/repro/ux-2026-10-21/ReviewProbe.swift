import Foundation
import AVFoundation
import VideoAutoTranslateCore

@main struct ReviewProbe {
    @MainActor static func main() async throws {
        func cue(_ text: String, _ translation: String = "", _ start: Double = 0, _ end: Double = 2) -> SubtitleItem {
            SubtitleItem(startTime: .from(seconds: start), endTime: .from(seconds: end), originalText: text, translatedText: translation)
        }
        let mode = CommandLine.arguments[1]
        let base = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "http://127.0.0.1:1"
        func config(_ route: String) -> LLMConfiguration {
            LLMConfiguration(providerType: .onlineCustom, onlineBaseURL: base + "/" + route, onlineModel: "review", targetLanguage: "zh")
        }
        if mode == "undo" {
            let app = AppState()
            app.project.subtitles = [cue("Before")]
            app.project.subtitles[0].originalText = "After"
            app.undo()
            print("text after undo=\(app.project.subtitles[0].originalText); expected Before")
        } else if mode == "load-undo" {
            let app = AppState()
            app.project.subtitles = [cue("Project A")]
            app.recordUndoSnapshot()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-project-\(UUID()).vatproject")
            defer { try? FileManager.default.removeItem(at: url) }
            try ProjectState(subtitles: [cue("Project B")]).encodeDocument().write(to: url)
            try app.loadProject(from: url)
            app.undo()
            print("loaded B then undo=\(app.project.subtitles.map(\.originalText))")
        } else if mode == "core" {
            let manager = SubtitleManager()
            let text = "Hello world third fourth"
            let parts = text.split(separator: " ")
            let words = parts.enumerated().map { i, w in WordToken(text: String(w), startTime: .from(seconds: Double(i)), endTime: .from(seconds: Double(i)+0.8)) }
            let item = cue(text, "完整人工译文", 0, 4); item.words = words
            let split = manager.split(item: item, atCharIndex: 2)!
            print("first-word split index2=\(split.0.originalText)|\(split.1.originalText), translation=\(split.0.translatedText)|\(split.1.translatedText)")
            let unicode = "😀a bc"
            let utf16Index = (unicode as NSString).range(of: "b").location
            let unicodeSplit = manager.split(item: cue(unicode), atCharIndex: utf16Index)!
            print("emoji cursor before b, UTF16=\(utf16Index), split=\(unicodeSplit.0.originalText)|\(unicodeSplit.1.originalText)")
            let aligner = TimelineAligner()
            let short = (0..<5).map { cue("row\($0)", "这是一段很长的翻译结果", Double($0)*0.2, Double($0)*0.2+0.15) }
            let aligned = aligner.matchTimelineToTranslation(items: short, videoDuration: 1)
            print("bounded crowded timeline=" + aligned.map { "\($0.startTime.secondsValue)-\($0.endTime.secondsValue)" }.joined(separator: ","))
            print("bounded timeline overlaps=\((1..<aligned.count).filter { aligned[$0].startTime < aligned[$0-1].endTime }.count)")
            let last = cue("original", String(repeating: "长", count: 30), 4, 5)
            let noBound = aligner.matchTimelineToTranslation(items: [last])
            print("5s video last subtitle without duration bound ends=\(noBound[0].endTime.secondsValue)")
            let exporter = SRTExporter()
            let missing = cue("Not translated")
            print("translated-only unfinished output=" + exporter.exportSRT(items: [missing], mode: .translatedOnly).replacingOccurrences(of: "\n", with: "|"))
            let report = exporter.validate(items: [missing], mode: .translatedOnly)
            print("validation total=\(report.totalCount), valid=\(report.validCount), untranslated=\(report.untranslatedCount)")
            var project = ProjectState(); project.llmConfig.onlineAPIKey = "review-sentinel"
            print("project key excluded=\(!String(data: try project.encodeDocument(), encoding: .utf8)!.contains("review-sentinel"))")
        } else if mode == "translation" {
            let items = [cue("First"), cue("Second")]
            try await SubtitleTranslator().translate(items: items, config: config("zero-based"))
            print("zero-based result=" + items.map(\.translatedText).joined(separator: "|"))
            let partial = [cue("First"), cue("Second")]
            try await SubtitleTranslator().translate(items: partial, config: config("partial"))
            print("partial returns success, result=" + partial.map(\.translatedText).joined(separator: "|"))
        } else if mode == "segment-content" {
            let words = [WordToken(text: "Hello", startTime: .from(seconds: 0), endTime: .from(seconds: 1)), WordToken(text: "world", startTime: .from(seconds: 1), endTime: .from(seconds: 2))]
            let result = try await LLMSegmenter().segment(tokens: words, config: config("hallucinated"))
            print("segment output=" + result.map(\.originalText).joined(separator: "|"))
            print("segment tokens=" + result.flatMap(\.words).map(\.text).joined(separator: "|"))
        } else if mode == "segment-stale" || mode == "align-stale" {
            let app = AppState()
            app.project.subtitles = [cue("Project A", "人工翻译", 0, 2)]
            app.project.llmConfig = config(mode)
            let task = Task {
                if mode == "segment-stale" { await app.runSmartSegmentation() }
                else { await app.matchTimelineToTranslation() }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            app.openVideo(url: URL(fileURLWithPath: "/tmp/review-project-B.mp4"))
            await task.value
            print("video B now contains=" + app.project.subtitles.map(\.originalText).joined(separator: "|"))
            print("translations=" + app.project.subtitles.map(\.translatedText).joined(separator: "|"))
            print("status=" + app.statusMessage)
        } else if mode == "duplicate-timeline" {
            _ = await TimelineAligner().matchTimelineWithLLM(items: [cue("hello", "你好")], config: config(mode), client: OpenAICompatibleClient(baseURL: base + "/" + mode, apiKey: ""))
            print("unexpected no crash")
        }
    }
}
