import XCTest
import AVFoundation
import Network
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class TranscriptionCancellationTests: XCTestCase {
    func testCancelDuringAutomaticSegmentationStopsLaterBatchesAndProgress() async throws {
        let firstBatch = expectation(description: "First automatic segmentation request")
        let finished = expectation(description: "Cancelled transcription returns")
        let ready = expectation(description: "Local fixture listening")
        let fixture = try SegmentationCancellationServer(onReady: { ready.fulfill() }, onFirst: { firstBatch.fulfill() })
        defer { fixture.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let base = "http://127.0.0.1:\(try XCTUnwrap(fixture.port))"
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
            buffer.frameLength = 32000
            memset(buffer.floatChannelData![0], 0, 32000 * MemoryLayout<Float>.size)
            try file.write(from: buffer)
        }
        let app = AppState(probeServices: false)
        app.project.videoURL = audio
        app.project.asrConfig.serviceURL = base + "/v1/audio/transcriptions"
        app.project.llmConfig = LLMConfiguration(providerType: .onlineCustom, onlineBaseURL: base + "/v1", onlineModel: "fixture", onlineAPIKey: "test-token")
        let previous = SubtitleItem(startTime: .zero, endTime: .from(seconds: 1), originalText: "Existing edit")
        app.project.subtitles = [previous]
        let job = Task { await app.runTranscription(); finished.fulfill() }
        await fulfillment(of: [firstBatch], timeout: 5)
        app.cancelAllTasks()
        let progress = app.project.progress
        let step = app.project.currentStepName
        // Releasing the response would allow a second batch if the outer pipeline
        // were still running; a cancelled URLSession request ignores it.
        fixture.releaseFirst()
        await fulfillment(of: [finished], timeout: 5)
        await job.value
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertFalse(app.project.isProcessing)
        XCTAssertEqual(app.statusMessage, "任务已取消")
        XCTAssertEqual(app.project.progress, progress)
        XCTAssertEqual(app.project.currentStepName, step)
        XCTAssertEqual(app.project.subtitles.map(\.id), [previous.id])
        XCTAssertNil(app.errorMessage)
        if let extracted = app.project.audioURL { try? FileManager.default.removeItem(at: extracted) }
    }
}

private final class SegmentationCancellationServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "transcription-cancellation-fixture")
    private let lock = NSLock()
    private var count = 0
    private var first: NWConnection?
    private let onFirst: () -> Void
    var port: UInt16? { listener.port?.rawValue }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(onReady: @escaping () -> Void, onFirst: @escaping () -> Void) throws {
        self.onFirst = onFirst
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { if case .ready = $0 { onReady() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.read(connection, collected: Data())
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var request = collected
            if let data { request.append(data) }
            if let separator = request.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: request[..<separator.lowerBound], encoding: .utf8) {
                let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count - separator.upperBound >= length {
                    let path = header.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    self.handle(path, connection: connection)
                    return
                }
            }
            if ended || error != nil { connection.cancel() }
            else { self.read(connection, collected: request) }
        }
    }

    private func handle(_ path: String, connection: NWConnection) {
        if path == "/v1/chat/completions" {
            lock.lock(); count += 1; let hold = count == 1
            if hold { first = connection }
            lock.unlock()
            if hold { onFirst() } else { finishSegmentation(connection) }
        } else if path == "/v1/audio/transcriptions" {
            let words = (0..<240).map { ["word": "hello", "start": Double($0) * 0.005, "end": Double($0 + 1) * 0.005] as [String: Any] }
            respond(["text": String(repeating: "hello ", count: 240), "words": words], to: connection)
        } else { respond(["status": "ok"], to: connection) }
    }

    func releaseFirst() {
        lock.lock(); let connection = first; first = nil; lock.unlock()
        if let connection { finishSegmentation(connection) }
    }
    private func finishSegmentation(_ connection: NWConnection) {
        let content = String(data: try! JSONSerialization.data(withJSONObject: ["lines": [String(repeating: "hello ", count: 120).trimmingCharacters(in: .whitespaces)]]), encoding: .utf8)!
        respond(["choices": [["message": ["content": content]]]], to: connection)
    }
    private func respond(_ value: [String: Any], to connection: NWConnection) {
        let body = try! JSONSerialization.data(withJSONObject: value)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    func stop() {
        listener.cancel()
        lock.lock(); let connection = first; first = nil; lock.unlock()
        connection?.cancel()
    }
}
