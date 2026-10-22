import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore

final class EdgeTTSTests: XCTestCase {

    func testTTSConfigurationEffectiveVoice() {
        var config = TTSConfiguration(engineType: .edgeTTS)

        // 默认中文匹配云希
        XCTAssertEqual(config.effectiveVoice(for: "简体中文 (Simplified Chinese)"), "zh-CN-YunxiNeural")
        XCTAssertEqual(config.effectiveVoice(for: "zh-Hans"), "zh-CN-YunxiNeural")

        // 英文匹配 Ava
        XCTAssertEqual(config.effectiveVoice(for: "English (US)"), "en-US-AvaMultilingualNeural")

        // 日语匹配 Nanami
        XCTAssertEqual(config.effectiveVoice(for: "Japanese"), "ja-JP-NanamiNeural")

        // 用户主动指定音色
        config.selectedVoice = "zh-CN-XiaoxiaoNeural"
        XCTAssertEqual(config.effectiveVoice(for: "Chinese"), "zh-CN-XiaoxiaoNeural")

        // 切换为系统原生引擎时返回基础语言代码
        let sysConfig = TTSConfiguration(engineType: .system)
        XCTAssertEqual(sysConfig.effectiveVoice(for: "Chinese"), "zh-CN")
        XCTAssertEqual(sysConfig.effectiveVoice(for: "English"), "en-US")
    }

    func testVoiceOptionsFiltering() {
        let zhVoices = TTSVoiceOption.voices(for: "中文", engine: .edgeTTS)
        XCTAssertFalse(zhVoices.isEmpty)
        XCTAssertTrue(zhVoices.contains { $0.id == "zh-CN-YunxiNeural" })

        let enVoices = TTSVoiceOption.voices(for: "English", engine: .edgeTTS)
        XCTAssertFalse(enVoices.isEmpty)
        XCTAssertTrue(enVoices.contains { $0.id.hasPrefix("en-") })
    }

    func testEdgeTTSServiceSynthesisAndEdgeTrimming() async throws {
        let service = EdgeTTSService()
        let tempDir = FileManager.default.temporaryDirectory
        let rawWav = tempDir.appendingPathComponent("test_edge_raw_\(UUID().uuidString).wav")
        let trimmedWav = tempDir.appendingPathComponent("test_edge_trimmed_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: rawWav)
            try? FileManager.default.removeItem(at: trimmedWav)
        }

        // 执行 Edge TTS 合成
        let output = try await service.synthesize(
            text: "欢迎使用微软 Edge 拟真语音合成测试。",
            voice: "zh-CN-YunxiNeural",
            outputURL: rawWav
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let fileSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 1000)

        // 验证 NaturalSpeechAudio.trimEdges 可以顺利读取并剪裁
        let duration = try NaturalSpeechAudio.trimEdges(inputURL: rawWav, outputURL: trimmedWav)
        XCTAssertGreaterThan(duration, 0.5)
        XCTAssertLessThan(duration, 10.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trimmedWav.path))
    }

    func testProjectDocumentTTSBackwardCompatibility() throws {
        // 模拟一个旧工程的完整序列化数据，并移除其中的 ttsConfig
        let fullData = try JSONEncoder().encode(ProjectDocument())
        var jsonDict = try JSONSerialization.jsonObject(with: fullData) as! [String: Any]
        jsonDict.removeValue(forKey: "ttsConfig")
        let oldJSON = try JSONSerialization.data(withJSONObject: jsonDict)

        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: oldJSON)
        XCTAssertEqual(decoded.ttsConfig.engineType, .edgeTTS)
        XCTAssertEqual(decoded.ttsConfig.selectedVoice, "zh-CN-YunxiNeural")

        // 重新编码与解码验证持久化一致性
        var state = ProjectState()
        state.ttsConfig.engineType = .edgeTTS
        state.ttsConfig.selectedVoice = "zh-CN-XiaoxiaoNeural"
        let encodedData = try state.encodeDocument()
        let restoredDoc = try ProjectState.decodeDocument(from: encodedData)
        XCTAssertEqual(restoredDoc.ttsConfig.selectedVoice, "zh-CN-XiaoxiaoNeural")
    }
}
