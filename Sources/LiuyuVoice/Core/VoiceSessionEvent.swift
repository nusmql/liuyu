import Foundation

public enum VoiceSessionEvent: Sendable, Equatable {
    case started(VoiceSessionMetrics)
    case partial(String, VoiceSessionMetrics)
    case final(String, VoiceSessionMetrics)
    case failed(String, VoiceSessionMetrics)
    case cancelled(VoiceSessionMetrics)
}
