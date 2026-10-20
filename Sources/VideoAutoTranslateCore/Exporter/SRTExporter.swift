import Foundation

public enum SubtitleExportMode {
    case originalOnly
    case translatedOnly
    case bilingual
}

/// 字幕文件导出器 (.srt / .vtt)
public final class SRTExporter {
    public init() {}

    /// 导出为 SRT 字符串
    public func exportSRT(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> String {
        var output = ""

        for (index, item) in items.enumerated() {
            output += "\(index + 1)\n"
            output += "\(item.startTime.srtFormat) --> \(item.endTime.srtFormat)\n"

            switch mode {
            case .originalOnly:
                output += "\(item.originalText)\n\n"
            case .translatedOnly:
                let text = item.translatedText.isEmpty ? item.originalText : item.translatedText
                output += "\(text)\n\n"
            case .bilingual:
                if !item.translatedText.isEmpty {
                    output += "\(item.translatedText)\n"
                }
                output += "\(item.originalText)\n\n"
            }
        }

        return output
    }

    /// 导出为 WebVTT 字符串
    public func exportVTT(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> String {
        var output = "WEBVTT\n\n"

        for (index, item) in items.enumerated() {
            output += "\(index + 1)\n"
            output += "\(item.startTime.vttFormat) --> \(item.endTime.vttFormat)\n"

            switch mode {
            case .originalOnly:
                output += "\(item.originalText)\n\n"
            case .translatedOnly:
                let text = item.translatedText.isEmpty ? item.originalText : item.translatedText
                output += "\(text)\n\n"
            case .bilingual:
                if !item.translatedText.isEmpty {
                    output += "\(item.translatedText)\n"
                }
                output += "\(item.originalText)\n\n"
            }
        }

        return output
    }

    /// 将字幕保存至本地磁盘
    public func saveToFile(
        items: [SubtitleItem],
        to url: URL,
        mode: SubtitleExportMode = .bilingual
    ) throws {
        let content: String
        if url.pathExtension.lowercased() == "vtt" {
            content = exportVTT(items: items, mode: mode)
        } else {
            content = exportSRT(items: items, mode: mode)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
