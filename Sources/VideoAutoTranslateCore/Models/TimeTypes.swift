import Foundation
import CoreMedia

public extension CMTime {
    /// 转换为 Double 浮点秒数（仅用于展示或外部接口通信）
    var secondsValue: Double {
        CMTimeGetSeconds(self)
    }

    /// 从秒数构建精确毫秒级 CMTime
    static func from(seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue(seconds * 1000), timescale: 1000)
    }

    /// 格式化为标准 SRT 时间戳: HH:mm:ss,SSS
    var srtFormat: String {
        let totalSeconds = max(0, secondsValue)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    /// 格式化为 WebVTT 时间戳: HH:mm:ss.SSS
    var vttFormat: String {
        let totalSeconds = max(0, secondsValue)
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    /// 简短界面展示: mm:ss.SS
    var displayFormat: String {
        let totalSeconds = max(0, secondsValue)
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let centiseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}

/// 支持序列化/反序列化的 CMTime 包装器
public struct CodableCMTime: Codable, Hashable, Equatable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32 = 1000) {
        self.value = value
        self.timescale = timescale
    }

    public init(cmTime: CMTime) {
        self.value = cmTime.value
        self.timescale = cmTime.timescale
    }

    public var cmTime: CMTime {
        CMTime(value: value, timescale: timescale)
    }
}
