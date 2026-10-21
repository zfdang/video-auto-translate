import Foundation
import CoreMedia

public enum SubtitleTiming {
    public static func validate(start: Double, end: Double, mediaDuration: Double, previousEnd: Double?, nextStart: Double?) throws {
        guard start.isFinite, end.isFinite, mediaDuration.isFinite, start >= 0, end <= mediaDuration, end - start >= 0.0999 else {
            throw NSError(domain: "SubtitleTiming", code: 1, userInfo: [NSLocalizedDescriptionKey: "时间需在媒体范围内，且每句至少持续 100ms。"])
        }
        guard previousEnd.map({ start >= $0 - 0.0001 }) ?? true,
              nextStart.map({ end <= $0 + 0.0001 }) ?? true else {
            throw NSError(domain: "SubtitleTiming", code: 2, userInfo: [NSLocalizedDescriptionKey: "此范围与相邻字幕重叠，请调整边界。"])
        }
    }
}
