import Foundation

public struct VoiceSessionMetrics: Sendable, Equatable {
    public var captureRequestedAtNanos: Int64?
    public var firstFrameCapturedAtNanos: Int64?
    public var providerPrepareStartedAtNanos: Int64?
    public var providerReadyAtNanos: Int64?
    public var firstFrameSentAtNanos: Int64?
    public var logicalStopAtNanos: Int64?
    public var lastFrameAcceptedAtNanos: Int64?
    public var lastFrameSentAtNanos: Int64?
    public var finishSentAtNanos: Int64?
    public var firstPartialReceivedAtNanos: Int64?
    public var finalReceivedAtNanos: Int64?
    public var preRollFrameCount: Int
    public var sentFrameCount: Int
    public var sentByteCount: Int

    public init(
        captureRequestedAtNanos: Int64? = nil,
        firstFrameCapturedAtNanos: Int64? = nil,
        providerPrepareStartedAtNanos: Int64? = nil,
        providerReadyAtNanos: Int64? = nil,
        firstFrameSentAtNanos: Int64? = nil,
        logicalStopAtNanos: Int64? = nil,
        lastFrameAcceptedAtNanos: Int64? = nil,
        lastFrameSentAtNanos: Int64? = nil,
        finishSentAtNanos: Int64? = nil,
        firstPartialReceivedAtNanos: Int64? = nil,
        finalReceivedAtNanos: Int64? = nil,
        preRollFrameCount: Int = 0,
        sentFrameCount: Int = 0,
        sentByteCount: Int = 0
    ) {
        self.captureRequestedAtNanos = captureRequestedAtNanos
        self.firstFrameCapturedAtNanos = firstFrameCapturedAtNanos
        self.providerPrepareStartedAtNanos = providerPrepareStartedAtNanos
        self.providerReadyAtNanos = providerReadyAtNanos
        self.firstFrameSentAtNanos = firstFrameSentAtNanos
        self.logicalStopAtNanos = logicalStopAtNanos
        self.lastFrameAcceptedAtNanos = lastFrameAcceptedAtNanos
        self.lastFrameSentAtNanos = lastFrameSentAtNanos
        self.finishSentAtNanos = finishSentAtNanos
        self.firstPartialReceivedAtNanos = firstPartialReceivedAtNanos
        self.finalReceivedAtNanos = finalReceivedAtNanos
        self.preRollFrameCount = preRollFrameCount
        self.sentFrameCount = sentFrameCount
        self.sentByteCount = sentByteCount
    }
}
