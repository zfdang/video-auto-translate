import XCTest
import AVFoundation
@testable import VideoAutoTranslateCore
@testable import VideoAutoTranslateApp

@MainActor final class OverlayExportTests: XCTestCase {
    func testOverlayKeepsStereoAndHighFrequenciesFromSourceVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceAudio = folder.appendingPathComponent("source.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let file = try AVAudioFile(forWriting: sourceAudio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for frame in 0..<48000 {
                buffer.floatChannelData![0][frame] = 0.2 * sin(2 * .pi * 10000 * Float(frame) / 48000)
                buffer.floatChannelData![1][frame] = 0.2 * sin(2 * .pi * 400 * Float(frame) / 48000)
            }
            try file.write(from: buffer)
        }
        let silentVideo = folder.appendingPathComponent("picture.mp4")
        let writer = try AVAssetWriter(outputURL: silentVideo, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let video = folder.appendingPathComponent("source.mp4")
        try await VideoComposer().compose(videoURL: silentVideo, newAudioURL: sourceAudio, outputURL: video, subtitleMode: .none)

        let recognition = folder.appendingPathComponent("recognition.wav")
        try await AudioExtractor().extract16kMonoWav(from: video, to: recognition)
        let recognitionFile = try AVAudioFile(forReading: recognition)
        XCTAssertEqual(recognitionFile.processingFormat.sampleRate, 16000)
        XCTAssertEqual(recognitionFile.processingFormat.channelCount, 1)
        let app = AppState(probeServices: false)
        app.project.videoURL = video
        app.project.audioURL = recognition
        let destination = folder.appendingPathComponent("overlay.mp4")
        app.exportJob.start(video: video, rows: [], voice: "zh-CN", audioMode: .overlay, subtitleMode: .none, destination: destination, skipped: 0)
        while app.exportJob.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(app.exportJob.error)
        XCTAssertEqual(app.exportJob.outputURL, destination)

        // Decode the exported track at 48 kHz and measure each channel's tone.
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(block)
            var data = Data(count: count)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
            data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: count, by: 4) { samples.append(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)) }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(samples.count, 48000)
        func tone(_ frequency: Double, channel: Int) -> Double {
            var real = 0.0, imaginary = 0.0
            let frames = samples.count / 2
            for frame in 0..<frames {
                let angle = 2 * Double.pi * frequency * Double(frame) / 48000
                real += Double(samples[frame * 2 + channel]) * cos(angle)
                imaginary += Double(samples[frame * 2 + channel]) * sin(angle)
            }
            return 2 * hypot(real, imaginary) / Double(max(1, frames))
        }
        XCTAssertGreaterThan(tone(10000, channel: 0), 0.08, "ASR downsampling must not remove high-frequency background sound")
        XCTAssertGreaterThan(tone(400, channel: 1), 0.08)
        XCTAssertLessThan(tone(10000, channel: 1), 0.02, "The source stereo channels must remain distinct")
    }
}
