import Foundation
import AVFoundation
import VideoAutoTranslateCore
@main struct AudioProbe {
    static func main() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("vat-audio-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let rate=24000.0
        func writeTone(_ name:String,_ seconds:Double) throws -> URL {
            let url=dir.appendingPathComponent(name+".wav")
            let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
            let frames=AVAudioFrameCount(seconds*rate)
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)!
            buffer.frameLength=frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i]=Float(sin(Double(i)*440*2*Double.pi/rate)*0.2) }
            let file=try AVAudioFile(forWriting:url,settings:format.settings)
            try file.write(from:buffer)
            return url
        }
        let raw=try writeTone("raw",4)
        let stretched=dir.appendingPathComponent("stretched.wav")
        try TimePitchEngine().changeSpeed(inputURL:raw,outputURL:stretched,rate:8)
        let stretchedDuration=try await AVURLAsset(url:stretched).load(.duration)
        print("4s input requested rate8 -> stretched seconds=\(stretchedDuration.seconds)")
        let item=SubtitleItem(startTime:.zero,endTime:.from(seconds:0.5),originalText:"long speech",dubbedAudioURL:stretched)
        let mixed=dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer().mix(backgroundAudioURL:nil,subtitles:[item],to:mixed)
        let mixedDuration=try await AVURLAsset(url:mixed).load(.duration)
        print("0.5s cue with \(stretchedDuration.seconds)s speech -> mixed seconds=\(mixedDuration.seconds)")
        let a=try writeTone("a",2), b=try writeTone("b",2)
        let items=[SubtitleItem(startTime:.zero,endTime:.from(seconds:2),originalText:"A",dubbedAudioURL:a),SubtitleItem(startTime:.from(seconds:1),endTime:.from(seconds:3),originalText:"B",dubbedAudioURL:b)]
        let overlap=dir.appendingPathComponent("overlap.m4a")
        try await AudioMixer().mix(backgroundAudioURL:nil,subtitles:items,to:overlap)
        let overlapDuration=try await AVURLAsset(url:overlap).load(.duration)
        print("two 2s clips at0s and1s -> mixed seconds=\(overlapDuration.seconds), requested timeline ends3s")
    }
}
