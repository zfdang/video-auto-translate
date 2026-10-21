import Foundation
import VideoAutoTranslateCore
@main struct AppProbe {
 @MainActor static func main() async throws {
  let app=AppState()
  let item=SubtitleItem(startTime:.zero,endTime:.from(seconds:2),originalText:"Original",translatedText:"Initial")
  app.project.subtitles=[item]
  app.project.llmConfig=LLMConfiguration(providerType:.onlineCustom,onlineBaseURL:CommandLine.arguments[1]+"/app-cancel",onlineModel:"mock")
  let task=Task {await app.runTranslation()}
  try await Task.sleep(nanoseconds:150_000_000)
  app.cancelAllTasks()
  await task.value
  print("cancelAllTasks returned, eventual translation=\(item.translatedText), status=\(app.statusMessage)")
  app.project.isDirty=false
  item.originalText="Manual source edit"
  print("manual text edit set isDirty=\(app.project.isDirty)")
 }
}
