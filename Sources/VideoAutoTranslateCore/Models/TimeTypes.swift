import Foundation
import CoreMedia

public extension CMTime {
    /// 转换为 Double 浮点秒数（仅用于展示或外部接口通信）
    var secondsValue: Double {
        let sec = CMTimeGetSeconds(self)
        return sec.isFinite && !sec.isNaN ? max(0, sec) : 0.0
    }

    /// 从秒数构建精确毫秒级 CMTime (R27: 增加有界性与有限性校验，防溢出崩溃)
    static func from(seconds: Double) -> CMTime {
        guard seconds.isFinite, !seconds.isNaN else { return .zero }
        let clamped = max(0.0, min(seconds, 864_000.0)) // 限制最大 10 天，杜绝 Int64 乘法溢出
        let millis = Int64(round(clamped * 1000.0))
        return CMTime(value: millis, timescale: 1000)
    }

    /// 格式化为标准 SRT 时间戳: HH:mm:ss,SSS (R27 & FU07: 限幅与溢出保护)
    var srtFormat: String {
        guard secondsValue.isFinite, !secondsValue.isNaN, secondsValue >= 0 else { return "00:00:00,000" }
        let clampedSec = min(secondsValue, 359_999.999)
        let totalMilliseconds = Int64(round(clampedSec * 1000.0))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    /// 格式化为 WebVTT 时间戳: HH:mm:ss.SSS (R27 & FU07: 限幅与溢出保护)
    var vttFormat: String {
        guard secondsValue.isFinite, !secondsValue.isNaN, secondsValue >= 0 else { return "00:00:00.000" }
        let clampedSec = min(secondsValue, 359_999.999)
        let totalMilliseconds = Int64(round(clampedSec * 1000.0))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    /// 简短界面展示: mm:ss.SS (R27 & FU07: 限幅与溢出保护)
    var displayFormat: String {
        guard secondsValue.isFinite, !secondsValue.isNaN, secondsValue >= 0 else { return "00:00.00" }
        let clampedSec = min(secondsValue, 359_999.99)
        let totalCentiseconds = Int64(round(clampedSec * 100.0))
        let minutes = totalCentiseconds / 6000
        let seconds = (totalCentiseconds % 6000) / 100
        let centiseconds = totalCentiseconds % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}

/// 支持序列化/反序列化的 CMTime 包装器
public struct CodableCMTime: Codable, Hashable, Equatable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32 = 1000) {
        self.value = max(0, value)
        self.timescale = max(1, timescale)
    }

    public init(cmTime: CMTime) {
        self.value = max(0, cmTime.value)
        self.timescale = max(1, cmTime.timescale)
    }

    public var cmTime: CMTime {
        CMTime(value: value, timescale: max(1, timescale))
    }

    enum CodingKeys: String, CodingKey {
        case value, timescale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVal = try container.decode(Int64.self, forKey: .value)
        let rawScale = try container.decode(Int32.self, forKey: .timescale)

        let validScale = max(1, rawScale)
        // 限制最大 10 天，防止反序列化异常极值引发下游计算溢出 (FU07)
        let maxVal = Int64(min(Double(Int64.max - 1), 864_000.0 * Double(validScale)))
        self.value = max(0, min(rawVal, maxVal))
        self.timescale = validScale
    }
}
