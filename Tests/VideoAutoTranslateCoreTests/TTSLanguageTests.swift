import XCTest
@testable import VideoAutoTranslateCore

final class TTSLanguageTests: XCTestCase {
    func testEveryTargetLanguageUsesMatchingVoiceForBothEngines() {
        for preset in TargetLanguagePreset.defaultPresets {
            let prefix = preset.code == "zh-Hant" ? "zh-TW" : (preset.code == "zh-Hans" ? "zh-CN" : preset.code)
            for engine in [TTSEngineType.edgeTTS, .system] {
                let config = TTSConfiguration(engineType: engine, selectedVoice: "zh-CN-YunxiNeural")
                let voice = config.effectiveVoice(for: preset.name)
                XCTAssertTrue(voice.hasPrefix(prefix), "\(preset.name): \(engine) resolved to \(voice)")
                XCTAssertTrue(TTSVoiceOption.voices(for: preset.name, engine: engine).contains { $0.id == voice })
                XCTAssertEqual(config.effectiveVoice(for: preset.code), voice)
            }
        }
    }
}
