import Foundation

public enum SubtitleExportMode: String, CaseIterable, Identifiable {
    case bilingual
    case translatedOnly
    case originalOnly
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bilingual:
            return "双语对照"
        case .translatedOnly:
            return "仅目标语言 (译文)"
        case .originalOnly:
            return "仅原始语言 (原文)"
        case .none:
            return "不内嵌字幕"
        }
    }
}

/// 字幕文件导出器 (.srt / .vtt)
public final class SRTExporter {
    public init() {}

    /// 导出为 SRT 字符串
    public func exportSRT(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> String {
        if mode == .none { return "" }
        var output = ""
        var cueIndex = 1

        for item in items {
            // R27: 过滤时间轴异常的无效行（如 end <= start）
            guard item.endTime > item.startTime else { continue }

            let textContent: String
            switch mode {
            case .originalOnly:
                textContent = item.originalText
            case .translatedOnly:
                // R31: 仅译文模式不静默回退填入原文
                let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                textContent = trans
            case .bilingual:
                if !item.translatedText.isEmpty {
                    textContent = "\(item.translatedText)\n\(item.originalText)"
                } else {
                    textContent = item.originalText
                }
            case .none:
                continue
            }

            guard !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            output += "\(cueIndex)\n"
            output += "\(item.startTime.srtFormat) --> \(item.endTime.srtFormat)\n"
            output += "\(textContent)\n\n"
            cueIndex += 1
        }

        return output
    }

    /// 导出为 WebVTT 字符串
    public func exportVTT(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> String {
        if mode == .none { return "WEBVTT\n\n" }
        var output = "WEBVTT\n\n"
        var cueIndex = 1

        for item in items {
            // R27: 过滤时间轴异常的无效行
            guard item.endTime > item.startTime else { continue }

            let textContent: String
            switch mode {
            case .originalOnly:
                textContent = item.originalText
            case .translatedOnly:
                // R31: 仅译文模式不静默回退填入原文
                let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                textContent = trans
            case .bilingual:
                if !item.translatedText.isEmpty {
                    textContent = "\(item.translatedText)\n\(item.originalText)"
                } else {
                    textContent = item.originalText
                }
            case .none:
                continue
            }

            guard !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            output += "\(cueIndex)\n"
            output += "\(item.startTime.vttFormat) --> \(item.endTime.vttFormat)\n"
            output += "\(textContent)\n\n"
            cueIndex += 1
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
