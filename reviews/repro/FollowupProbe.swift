import Foundation
import AVFoundation
import VideoAutoTranslateCore
@main struct FollowupProbe {
 @MainActor static func main() async throws {
  let mode=CommandLine.arguments.dropFirst().first ?? "core"
  func t(_ x:Double)->CMTime { .from(seconds:x) }
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vat-followup-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:dir) }
  if mode == "format-huge" {
   let value=try JSONDecoder().decode(CodableCMTime.self,from:Data("{\"value\":9223372036854775807,\"timescale\":1}".utf8))
   print(value.cmTime.srtFormat)
  } else if mode == "core" {
   let words=[WordToken(text:"Hello",startTime:t(1),endTime:t(2)),WordToken(text:"world",startTime:t(2.2),endTime:t(3))]
   let manager=SubtitleManager()
   for i in [2,6,10] {
    let item=SubtitleItem(startTime:t(1),endTime:t(3),originalText:"Hello world",translatedText:"完整人工译文",words:words)
    if let(a,b)=manager.split(item:item,atCharIndex:i) {
     print("split \(i): left=\(a.originalText), leftWords=\(a.words.map{$0.text}), boundary=\(a.endTime.seconds), right=\(b.originalText), rightWords=\(b.words.map{$0.text}), translations=[\(a.translatedText)|\(b.translatedText)]")
    }
   }
   let tiny=SubtitleItem(startTime:.zero,endTime:t(0.001),originalText:"ab")
   print("tiny split rejected=\(manager.split(item:tiny,atCharIndex:1)==nil)")
   print("milliseconds fixed=\(CMTime(value:1001,timescale:1000).srtFormat)")
   let nested=manager.merge(items:[SubtitleItem(startTime:t(0),endTime:t(10),originalText:"A"),SubtitleItem(startTime:t(1),endTime:t(2),originalText:"B")])!
   print("nested merged end=\(nested.endTime.seconds)")
   var project=ProjectState(videoURL:dir.appendingPathComponent("video.mp4"))
   project.audioURL=dir.appendingPathComponent("background.wav")
   project.llmConfig.onlineAPIKey="sk-review-sentinel-not-real"
   let data=try project.encodeDocument()
   let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
   print("project contains plaintext API key=\((object["llmConfig"] as? [String:Any])?["onlineAPIKey"] as? String == "sk-review-sentinel-not-real")")
   var restored=ProjectState();restored.restore(from:try ProjectState.decodeDocument(from:data))
   print("restored audioURL nil=\(restored.audioURL==nil)")
   let preset=ASRModelPreset(id:"review",displayName:"review",repoOrFileName:"review/model",sizeDescription:"test",approxSizeBytes:1,isRepo:true,note:"")
   let model=dir.appendingPathComponent("models--review--model")
   try FileManager.default.createDirectory(at:model,withIntermediateDirectories:true)
   try Data("{}".utf8).write(to:model.appendingPathComponent("config.json"))
   try Data().write(to:model.appendingPathComponent("model.safetensors"))
   let storage=ModelStorageManager(config:ModelStorageConfig(locationType:.custom,customDirectoryPath:dir.path))
   print("zero-byte weights state=\(storage.detectModel(preset))")
   let missing=SubtitleItem(startTime:t(0),endTime:t(1),originalText:"untranslated")
   let present=SubtitleItem(startTime:t(1),endTime:t(2),originalText:"translated",translatedText:"完成")
   print("translated-only mixed result=\(SRTExporter().exportSRT(items:[missing,present],mode:.translatedOnly).replacingOccurrences(of:"\n",with:"|"))")
   let short=SubtitleItem(startTime:CMTime(value:1,timescale:10000),endTime:CMTime(value:2,timescale:10000),originalText:"sub-ms")
   print("sub-ms exported=\(SRTExporter().exportSRT(items:[short]).replacingOccurrences(of:"\n",with:"|"))")
   print("custom French voice=\(LLMConfiguration(targetLanguage:"French").targetLanguageVoiceCode)")
   let format=AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
   do { _ = try AVAudioFile(forWriting:dir.appendingPathComponent("audio.wav.tmp"),settings:format.settings);print("tmp audio writer opened=true") } catch { print("tmp audio writer error=\(error)") }
   _ = try AVAudioFile(forWriting:dir.appendingPathComponent("audio.wav"),settings:format.settings)
   print("wav audio writer opened=true")
  } else if ["duplicate","missing","stale","clear","cancel"].contains(mode) {
   let item=SubtitleItem(startTime:t(0),endTime:t(2),originalText:"Original",translatedText:"Initial")
   let config=LLMConfiguration(providerType:.onlineCustom,onlineBaseURL:CommandLine.arguments[2]+"/"+mode,onlineModel:"mock")
   let task=Task { try await SubtitleTranslator().translate(items:[item],config:config) }
   if ["stale","clear","cancel"].contains(mode) {
    try await Task.sleep(nanoseconds:150_000_000)
    if mode == "stale" {item.originalText="Edited source";item.translatedText="Manual"}
    if mode == "clear" {item.translatedText=""}
    if mode == "cancel" {task.cancel()}
   }
   do { try await task.value;print("\(mode) returned success, translation=\(item.translatedText)") } catch {print("\(mode) error=\(error.localizedDescription), translation=\(item.translatedText)")}
  } else if mode == "alias-export" {
   let input=URL(fileURLWithPath:CommandLine.arguments[2])
   let before=try Data(contentsOf:input)
   let alias=dir.appendingPathComponent("alias")
   try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:input.deletingLastPathComponent())
   let output=alias.appendingPathComponent(input.lastPathComponent)
   do {try await VideoComposer().compose(videoURL:input,outputURL:output,subtitles:[],subtitleMode:.none);print("parent-alias export accepted=true")} catch {print("parent-alias export error=\(error.localizedDescription)")}
   print("source bytes changed=\((try? Data(contentsOf:input)) != before)")
  }
 }
}
