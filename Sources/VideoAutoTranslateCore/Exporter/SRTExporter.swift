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
            return "仅目标语"
        case .originalOnly:
            return "仅原始语"
        case .none:
            return "没有字幕"
        }
    }
}

/// 视频成片导出时的音频语言模式
public enum VideoAudioExportMode: String, CaseIterable, Identifiable {
    case translated = "translated" // 自动翻译的语言
    case original = "original"     // 原始语言

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .translated:
            return "自动翻译的语言"
        case .original:
            return "原始语言"
        }
    }
}

/// 字幕导出校验报告 (FU08)
public struct ExportIssue: Identifiable {
    public var id: UUID { itemID }
    public let itemID: UUID
    public let row: Int
    public let reason: String
}

public struct ExportValidationReport {
    public let issues: [ExportIssue]
    public let totalCount: Int
    public let validCount: Int
    public let untranslatedCount: Int
    public let invalidDurationCount: Int

    public var hasIssues: Bool {
        !issues.isEmpty
    }
}

/// 字幕文件导出器 (.srt / .vtt)
public final class SRTExporter {
    public init() {}

    /// 校验待导出字幕的完整性与时间轴有效性 (FU08)
    public func validate(items: [SubtitleItem], mode: SubtitleExportMode = .bilingual, mediaDuration: Double? = nil) -> ExportValidationReport {
        var untranslated = 0
        var invalidDuration = 0
        var valid = 0

        var issues: [ExportIssue] = []
        for (index, item) in items.enumerated() {
            let start = item.startTime.seconds
            let end = item.endTime.seconds
            var reason: String?
            if !start.isFinite || !end.isFinite || start < 0 || end <= start || item.startTime.srtFormat == item.endTime.srtFormat || mediaDuration.map({ end > $0 + 0.001 }) == true {
                invalidDuration += 1
                reason = "时间无效或超出媒体范围"
            } else if index > 0 && item.startTime < items[index-1].endTime {
                invalidDuration += 1
                reason = "与上一句重叠"
            } else if mode != .originalOnly && mode != .none && item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                untranslated += 1
                reason = "译文尚未完成"
            } else if mode != .originalOnly && mode != .none && item.translationNeedsReview {
                reason = "译文待复核"
            } else if mode == .originalOnly && item.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reason = "原文为空"
            }
            if let reason = reason { issues.append(ExportIssue(itemID: item.id, row: index + 1, reason: reason)) }
            else { valid += 1 }
        }

        return ExportValidationReport(
            issues: issues,
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
                guard !trans.isEmpty else { continue }
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
                guard !trans.isEmpty else { continue }
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
        mode: SubtitleExportMode = .bilingual,
        allowSkippingIssues: Bool = false
    ) throws {
        let validation = validate(items: items, mode: mode)
        guard allowSkippingIssues || !validation.hasIssues else {
            throw NSError(domain: "SubtitleExport", code: 1, userInfo: [NSLocalizedDescriptionKey: validation.issues.map { "第\($0.row)句：\($0.reason)" }.joined(separator: "\n")])
        }
        let rejected = Set(validation.issues.map(\.itemID))
        let items = allowSkippingIssues ? items.filter { !rejected.contains($0.id) } : items
        guard !items.isEmpty else { throw NSError(domain: "SubtitleExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有可导出的有效字幕"]) }
        let content: String
        if url.pathExtension.lowercased() == "vtt" {
            content = exportVTT(items: items, mode: mode)
        } else {
            content = exportSRT(items: items, mode: mode)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
