import Foundation
import CoreMedia
import VideoAutoTranslateCore

@main
struct ReviewProbe {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "core"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vat-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SubtitleManager()
        func t(_ n: Double) -> CMTime { .from(seconds: n) }
        if mode == "core" {
            let tokens = [WordToken(text:"Hello",startTime:t(1),endTime:t(2)),WordToken(text:"world",startTime:t(2.2),endTime:t(3))]
            for index in [2,6,10] {
                let item = SubtitleItem(startTime:t(1),endTime:t(3),originalText:"Hello world",translatedText:"人工译文",words:tokens)
                if let (a,b)=manager.split(item:item,atCharIndex:index) {
                    print("split index=\(index): [\(a.originalText)] words=\(a.words.map{$0.text}) \(a.startTime.secondsValue)-\(a.endTime.secondsValue); [\(b.originalText)] words=\(b.words.map{$0.text}); translations=[\(a.translatedText)|\(b.translatedText)]")
                }
            }
            let short = SubtitleItem(startTime:t(0),endTime:CMTime(value:1,timescale:1000),originalText:"ab")
            let (a,b)=manager.split(item:short,atCharIndex:1)!
            print("short split durations(ms)=\(a.duration.secondsValue*1000),\(b.duration.secondsValue*1000)")
            let item=SubtitleItem(startTime:t(1),endTime:t(3),originalText:"Hello world",translatedText:"old",words:tokens,dubbedAudioURL:dir.appendingPathComponent("old.wav"))
            item.originalText="Entirely different text"
            item.translatedText="New text"
            print("edit preserved stale words=\(item.words.map{$0.text}), cached URL=\(item.dubbedAudioURL != nil)")
            let outer=SubtitleItem(startTime:t(0),endTime:t(10),originalText:"outer")
            let inner=SubtitleItem(startTime:t(1),endTime:t(2),originalText:"inner")
            print("merge nested end=\(manager.merge(items:[outer,inner])!.endTime.secondsValue)")
            var examples:[String]=[]
            for ms in 0..<10000 {
                let time=CMTime(value:Int64(ms),timescale:1000)
                let expected=String(format:"00:00:%02d,%03d",ms/1000,ms%1000)
                if time.srtFormat != expected && examples.count<5 { examples.append("\(ms)ms=>\(time.srtFormat)") }
            }
            print("timestamp mismatches=\(examples)")
            let preset=ASRModelPreset(id:"review",displayName:"review",repoOrFileName:"review/model",sizeDescription:"test",approxSizeBytes:1,isRepo:true,note:"")
            try FileManager.default.createDirectory(at:dir.appendingPathComponent("models--review--model"),withIntermediateDirectories:true)
            let storage=ModelStorageManager(config:ModelStorageConfig(locationType:.custom,customDirectoryPath:dir.path))
            print("empty repository state=\(storage.detectModel(preset))")
            let source=dir.appendingPathComponent("source.mp4")
            try Data("disposable source sentinel".utf8).write(to:source)
            do { try await VideoComposer().compose(videoURL:source,outputURL:source,subtitleMode:.none) } catch { print("same-path export error=\(error.localizedDescription)") }
            print("same-path source exists=\(FileManager.default.fileExists(atPath:source.path))")
            let validEnd=SubtitleItem(startTime:t(2),endTime:t(1),originalText:"invalid")
            print("invalid time exported=\(SRTExporter().exportSRT(items:[validEnd]).replacingOccurrences(of:"\n",with:"|"))")
            let noTranslation=SubtitleItem(startTime:t(0),endTime:t(1),originalText:"English only")
            print("translated-only falls back=\(SRTExporter().exportSRT(items:[noTranslation],mode:.translatedOnly).contains("English only"))")
        } else if ["duplicate","missing","stale"].contains(mode) {
            let base=CommandLine.arguments[2]
            let item=SubtitleItem(startTime:t(0),endTime:t(2),originalText:"Original source",translatedText:"Initial translation")
            let config=LLMConfiguration(providerType:.onlineCustom,onlineBaseURL:base+"/"+mode,onlineModel:"review-mock")
            if mode == "stale" {
                let task=Task { try await SubtitleTranslator().translate(items:[item],config:config) }
                try await Task.sleep(nanoseconds:150_000_000)
                item.originalText="User corrected source"
                item.translatedText="User manual translation"
                try await task.value
            } else { try await SubtitleTranslator().translate(items:[item],config:config) }
            print("\(mode) completed without error: source=\(item.originalText), translation=\(item.translatedText)")
        } else if mode == "huge-time" {
            print(CMTime.from(seconds:1e300))
        }
    }
}
