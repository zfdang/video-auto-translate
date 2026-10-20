import Foundation
import CoreMedia

/// 单个词/汉字的精确起止时间戳
public struct WordToken: Identifiable, Codable, Hashable, Equatable {
    public var id: UUID
    public var text: String
    public var startTime: CodableCMTime
    public var endTime: CodableCMTime

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: CMTime,
        endTime: CMTime
    ) {
        self.id = id
        self.text = text
        self.startTime = CodableCMTime(cmTime: startTime)
        self.endTime = CodableCMTime(cmTime: endTime)
    }

    public var startCMTime: CMTime {
        startTime.cmTime
    }

    public var endCMTime: CMTime {
        endTime.cmTime
    }

    public var durationCMTime: CMTime {
        CMTimeSubtract(endCMTime, startCMTime)
    }
}
