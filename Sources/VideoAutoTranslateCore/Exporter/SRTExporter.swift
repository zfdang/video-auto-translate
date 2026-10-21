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

/// 字幕导出校验报告 (FU08)
public struct ExportValidationReport {
    public let totalCount: Int
    public let validCount: Int
    public let untranslatedCount: Int
    public let invalidDurationCount: Int

    public var hasIssues: Bool {
        untranslatedCount > 0 || invalidDurationCount > 0
    }
}

/// 字幕文件导出器 (.srt / .vtt)
public final class SRTExporter {
    public init() {}

    /// 校验待导出字幕的完整性与时间轴有效性 (FU08)
    public func validate(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> ExportValidationReport {
        var untranslated = 0
        var invalidDuration = 0
        var valid = 0

        for item in items {
            let startStr = item.startTime.srtFormat
            let endStr = item.endTime.srtFormat
            if item.endTime <= item.startTime || startStr == endStr {
                invalidDuration += 1
                continue
            }
            if mode == .translatedOnly && item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                untranslated += 1
            }
            valid += 1
        }

        return ExportValidationReport(
            totalCount: items.count,
            validCount: valid,
            untranslatedCount: untranslated,
            invalidDurationCount: invalidDuration
        )
    }

    /// 导出为 SRT 字符串
    public func exportSRT(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual) -> String {
        if mode == .none { return "" }
        var output = ""
        var cueIndex = 1

        for item in items {
            // R27 & FU07: 过滤时间轴异常及量化后零时长的无效行
            guard item.endTime > item.startTime else { continue }
            let startStr = item.startTime.srtFormat
            let endStr = item.endTime.srtFormat
            guard startStr != endStr else { continue }

            let textContent: String
            switch mode {
            case .originalOnly:
                textContent = item.originalText
            case .translatedOnly:
                // R31 & FU08: 仅译文模式未完成行输出占位符，防止静默漏句造成空洞
                let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                textContent = trans.isEmpty ? "[待翻译]" : trans
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
            output += "\(startStr) --> \(endStr)\n"
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
            // R27 & FU07: 过滤时间轴异常及量化后零时长的无效行
            guard item.endTime > item.startTime else { continue }
            let startStr = item.startTime.vttFormat
            let endStr = item.endTime.vttFormat
            guard startStr != endStr else { continue }

            let textContent: String
            switch mode {
            case .originalOnly:
                textContent = item.originalText
            case .translatedOnly:
                // R31 & FU08: 仅译文模式未完成行输出占位符，防止静默漏句造成空洞
                let trans = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                textContent = trans.isEmpty ? "[待翻译]" : trans
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
            output += "\(startStr) --> \(endStr)\n"
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
