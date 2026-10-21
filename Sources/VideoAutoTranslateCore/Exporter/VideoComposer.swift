import Foundation
import AVFoundation
import QuartzCore
import AppKit

public enum VideoComposerError: LocalizedError {
    case noVideoTrack
    case exportFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "源视频中未找到有效视频轨道"
        case .exportFailed(let msg):
            return "成片视频合成导出失败: \(msg)"
        case .cancelled:
            return "导出任务已取消"
        }
    }
}

/// 纯原生多媒体合成与 VideoToolbox 硬件硬编导出器
public final class VideoComposer {
    public init() {}

    /// 合成原视频画面轨与音频轨为最终 MP4 视频，并按需内嵌硬字幕
    /// - Parameters:
    ///   - videoURL: 原视频文件路径
    ///   - newAudioURL: 混音好的新音频文件路径（若为 nil，则保留视频原始音轨）
    ///   - outputURL: 最终导出的 MP4 文件路径
    ///   - subtitles: 待内嵌的字幕列表
    ///   - subtitleMode: 内嵌语言模式（双语 / 仅目标语言 / 仅原始语言 / 不内嵌）
    public func compose(
        videoURL: URL,
        newAudioURL: URL? = nil,
        outputURL: URL,
        subtitles: [SubtitleItem] = [],
        subtitleMode: SubtitleExportMode = .bilingual
    ) async throws {
        // 安全检查：严禁输出路径与输入视频或输入音频相同或指向同一文件（防父目录别名与符号链接，R01 / FU02）
        guard !outputURL.pointsToSameFile(as: videoURL) else {
            throw VideoComposerError.exportFailed("输出文件路径不能与源视频路径相同，避免覆盖源素材")
        }
        if let newAudio = newAudioURL {
            guard !outputURL.pointsToSameFile(as: newAudio) else {
                throw VideoComposerError.exportFailed("输出文件路径不能与输入音频路径相同")
            }
        }

        let videoAsset = AVURLAsset(url: videoURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw VideoComposerError.noVideoTrack
        }

        let composition = AVMutableComposition()

        // 1. 插入画面轨
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoComposerError.exportFailed("无法创建视频轨道")
        }

        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )

        // 保持视频原始方向变换
        let transform = try await videoTrack.load(.preferredTransform)
        compVideoTrack.preferredTransform = transform

        // 2. 插入音频轨（新配音或保留原音）
        if let newAudioURL = newAudioURL {
            let audioAsset = AVURLAsset(url: newAudioURL)
            if let newAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
                guard let compAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw VideoComposerError.exportFailed("无法创建音频轨道")
                }

                let audioDuration = try await audioAsset.load(.duration)
                let actualAudioDuration = min(videoDuration, audioDuration)
                try compAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: actualAudioDuration),
                    of: newAudioTrack,
                    at: .zero
                )
            }
        } else if let origAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first {
            if let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                let origAudioDuration = try await videoAsset.load(.duration)
                try compAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: origAudioDuration),
                    of: origAudioTrack,
                    at: .zero
                )
            }
        }

        // 3. 构建硬件硬编导出会话（输出至同目录临时文件，导出成功后再原子替换，R01）
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoComposerError.exportFailed("无法初始化导出引擎")
        }

        let tempDirectory = outputURL.deletingLastPathComponent()
        let tempFilename = ".\(UUID().uuidString)_\(outputURL.lastPathComponent).tmp"
        let tempOutputURL = tempDirectory.appendingPathComponent(tempFilename)
        try? FileManager.default.removeItem(at: tempOutputURL)

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        // 4. 按需构建视频字幕内嵌图层渲染合成器
        if subtitleMode != .none && !subtitles.isEmpty {
            let naturalSize = try await videoTrack.load(.naturalSize)
            let isPortrait = (transform.a == 0 && abs(transform.b) == 1.0)
            let renderSize = isPortrait ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize

            let totalDurationSec = max(0.1, videoDuration.seconds)
            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            let scale = max(0.5, min(renderSize.height / 1080.0, 3.0))

            for item in subtitles {
                let primaryText: String
                let secondaryText: String

                switch subtitleMode {
                case .bilingual:
                    if !item.translatedText.isEmpty {
                        primaryText = item.translatedText
                        secondaryText = item.originalText
                    } else {
                        primaryText = item.originalText
                        secondaryText = ""
                    }
                case .translatedOnly:
                    // R31 & FU08: 仅译文模式下未翻译行以占位符展示，防止静默漏句
                    let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    primaryText = trans.isEmpty ? "[待翻译]" : trans
                    secondaryText = ""
                case .originalOnly:
                    primaryText = item.originalText
                    secondaryText = ""
                case .none:
                    primaryText = ""
                    secondaryText = ""
                }

                guard !primaryText.isEmpty || !secondaryText.isEmpty else { continue }

                let startSec = item.startTime.seconds
                let endSec = item.endTime.seconds
                guard endSec - startSec >= 0.001 else { continue }

                if let cgImage = renderSubtitlePill(
                    primary: primaryText,
                    secondary: secondaryText,
                    renderSize: renderSize,
                    scale: scale
                ) {
                    let pillWidth = CGFloat(cgImage.width)
                    let pillHeight = CGFloat(cgImage.height)

                    let subLayer = CALayer()
                    subLayer.frame = CGRect(
                        x: (renderSize.width - pillWidth) / 2.0,
                        y: renderSize.height * 0.08,
                        width: pillWidth,
                        height: pillHeight
                    )
                    subLayer.contents = cgImage
                    subLayer.contentsGravity = .resizeAspect

                    let delta = 0.001
                    let k0 = max(0.0, (startSec - delta) / totalDurationSec)
                    let k1 = startSec / totalDurationSec
                    let k2 = endSec / totalDurationSec
                    let k3 = min(1.0, (endSec + delta) / totalDurationSec)

                    let anim = CAKeyframeAnimation(keyPath: "opacity")
                    anim.duration = totalDurationSec
                    anim.keyTimes = [
                        0.0,
                        NSNumber(value: k0),
                        NSNumber(value: k1),
                        NSNumber(value: k2),
                        NSNumber(value: k3),
                        1.0
                    ]
                    anim.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
                    anim.beginTime = AVCoreAnimationBeginTimeAtZero
                    anim.isRemovedOnCompletion = false
                    anim.fillMode = .forwards
                    subLayer.add(anim, forKey: "opacity")

                    parentLayer.addSublayer(subLayer)
                }
            }

            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            let nominalFps = (try? await videoTrack.load(.nominalFrameRate)) ?? 30.0
            let fps = nominalFps > 0 ? Int32(round(nominalFps)) : 30
            videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parentLayer
            )

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: videoDuration)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
            layerInstruction.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]

            exportSession.videoComposition = videoComposition
        }

        await exportSession.export()

        if exportSession.status != .completed {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw VideoComposerError.exportFailed(exportSession.error?.localizedDescription ?? "未知导出错误")
        }

        // R01 / FU02: 最终原子替换前再次核验目标文件身份，严禁覆盖源文件
        guard !outputURL.pointsToSameFile(as: videoURL) else {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw VideoComposerError.exportFailed("输出文件路径指向源视频文件，已终止替换")
        }

        // R01: 校验导出结果并原子替换目标文件
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempOutputURL)
            } else {
                try FileManager.default.moveItem(at: tempOutputURL, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw VideoComposerError.exportFailed("替换导出目标文件失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 绘制高保真胶囊字幕图片
    private func renderSubtitlePill(
        primary: String,
        secondary: String,
        renderSize: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let hasSecondary = !secondary.isEmpty

        let primaryFontSize: CGFloat = round(32.0 * scale)
        let secondaryFontSize: CGFloat = round(20.0 * scale)

        let zhStyle = NSMutableParagraphStyle()
        zhStyle.alignment = .center
        zhStyle.lineBreakMode = .byWordWrapping

        let primaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: primaryFontSize),
            .foregroundColor: NSColor.systemYellow,
            .paragraphStyle: zhStyle
        ]

        let enStyle = NSMutableParagraphStyle()
        enStyle.alignment = .center
        enStyle.lineBreakMode = .byWordWrapping

        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: secondaryFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: enStyle
        ]

        let maxPillWidth = min(renderSize.width * 0.88, 1400.0 * scale)
        let horizontalPadding: CGFloat = round(24.0 * scale)
        let verticalPadding: CGFloat = round(12.0 * scale)

        let maxTextWidth = maxPillWidth - horizontalPadding * 2.0

        let primaryBounds = (primary as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: 200.0 * scale),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: primaryAttrs
        )

        let secondaryBounds: CGRect
        if hasSecondary {
            secondaryBounds = (secondary as NSString).boundingRect(
                with: CGSize(width: maxTextWidth, height: 160.0 * scale),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: secondaryAttrs
            )
        } else {
            secondaryBounds = .zero
        }

        let spacing: CGFloat = hasSecondary ? round(6.0 * scale) : 0.0
        let contentHeight = primaryBounds.height + (hasSecondary ? secondaryBounds.height + spacing : 0.0)
        let totalPillHeight = contentHeight + verticalPadding * 2.0
        let totalPillWidth = min(maxPillWidth, max(primaryBounds.width, secondaryBounds.width) + horizontalPadding * 2.0)

        let pillSize = CGSize(width: ceil(totalPillWidth), height: ceil(totalPillHeight))

        let image = NSImage(size: pillSize, flipped: false) { rect in
            let cornerRadius = round(14.0 * scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.withAlphaComponent(0.72).setFill()
            path.fill()

            if hasSecondary {
                // macOS flipped: false 即原点在底部
                // 次级文本（底部）
                let secondaryY = verticalPadding
                let secRect = CGRect(
                    x: horizontalPadding,
                    y: secondaryY,
                    width: rect.width - horizontalPadding * 2.0,
                    height: secondaryBounds.height
                )
                (secondary as NSString).draw(in: secRect, withAttributes: secondaryAttrs)

                // 主级文本（顶部）
                let primaryY = secondaryY + secondaryBounds.height + spacing
                let primRect = CGRect(
                    x: horizontalPadding,
                    y: primaryY,
                    width: rect.width - horizontalPadding * 2.0,
                    height: primaryBounds.height
                )
                (primary as NSString).draw(in: primRect, withAttributes: primaryAttrs)
            } else {
                let primaryY = (rect.height - primaryBounds.height) / 2.0
                let primRect = CGRect(
                    x: horizontalPadding,
                    y: primaryY,
                    width: rect.width - horizontalPadding * 2.0,
                    height: primaryBounds.height
                )
                (primary as NSString).draw(in: primRect, withAttributes: primaryAttrs)
            }
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.cgImage
    }
}
