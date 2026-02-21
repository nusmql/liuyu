// Sources/LiuyuLib/App/TranscriptionPresenter.swift
import Foundation

/// Actor responsible for managing transcription result presentation.
/// Ensures thread-safe, ordered presentation of transcription results.
///
/// Note: Actor provides its own isolation, so we don't use @MainActor.
/// UI operations are dispatched to MainActor within the presenter closure.
public actor TranscriptionPresenter {
    public static let shared = TranscriptionPresenter()

    /// Tracks if a presentation is currently in progress
    private var isPresenting = false

    /// Queue of pending results to present
    private var pendingResults: [String] = []

    private init() {}

    /// Presents a transcription result.
    /// This method is serial - if called while another presentation is in progress,
    /// the new result will be queued and presented after the current one completes.
    ///
    /// - Parameters:
    ///   - text: The transcription result to present
    ///   - presenter: An async closure that performs the actual UI presentation.
    ///                This closure will be called on the MainActor.
    public func present(_ text: String, using presenter: @escaping @MainActor (String) async -> Void) async {
        if isPresenting {
            // Queue the result for later presentation
            pendingResults.append(text)
            Logger.debug("Queued transcription result, currently presenting", category: .ui)
            return
        }

        isPresenting = true
        defer {
            isPresenting = false
        }

        // Call presenter on MainActor since it performs UI operations
        await presenter(text)

        // Process any queued results
        while !pendingResults.isEmpty {
            let nextResult = pendingResults.removeFirst()
            Logger.debug("Processing queued transcription result", category: .ui)
            await presenter(nextResult)
        }
    }

    /// Cancels any pending presentations and clears the queue.
    public func cancelPending() {
        pendingResults.removeAll()
        Logger.debug("Cancelled pending transcription presentations", category: .ui)
    }

    /// Resets the presenter state. Useful for recovery from error conditions.
    public func reset() {
        isPresenting = false
        pendingResults.removeAll()
        Logger.debug("Reset transcription presenter", category: .ui)
    }
}
