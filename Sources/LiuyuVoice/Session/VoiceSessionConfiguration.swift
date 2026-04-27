import Foundation

public enum VoiceSessionStopReason: Sendable, Equatable {
    case userReleased
    case silenceTimeout
    case cancelled
}

public struct VoiceSessionConfiguration: Sendable, Equatable {
    public let preRollFrameLimit: Int
    public let tailFrameLimit: Int

    public init(preRollFrameLimit: Int = 36, tailFrameLimit: Int = 12) {
        self.preRollFrameLimit = preRollFrameLimit
        self.tailFrameLimit = tailFrameLimit
    }
}
