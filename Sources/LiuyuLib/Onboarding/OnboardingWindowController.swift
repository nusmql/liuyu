// Sources/LiuyuLib/Onboarding/OnboardingWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: WindowController {
    var onComplete: (() -> Void)?

    init() {
        var capturedSelf: OnboardingWindowController?
        super.init(
            title: "Welcome to LiuYu",
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400)
        ) {
            NSHostingView(
                rootView: OnboardingView(onComplete: {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                    capturedSelf?.close()
                    capturedSelf?.onComplete?()
                })
            )
        }
        capturedSelf = self
    }
}
