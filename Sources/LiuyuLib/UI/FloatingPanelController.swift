import AppKit
import SwiftUI

@MainActor
public class FloatingPanelController {
    private var panel: NSPanel?
    public let viewModel = PanelViewModel()

    public init() {}

    public func setup() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Support light/dark mode theme changes
        panel.appearance = NSAppearance(named: .aqua)

        // Observe theme changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(themeChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        let hostingView = NSHostingView(rootView: PanelContentView(viewModel: viewModel))
        panel.contentView = hostingView

        self.panel = panel
    }

    @objc private func themeChanged() {
        // Update appearance based on current system theme
        guard let panel = panel else { return }
        let currentName = NSApp.effectiveAppearance.name
        panel.appearance = NSAppearance(named: currentName == .darkAqua ? .darkAqua : .aqua)
    }

    public func show() {
        guard let panel else { return }
        positionAtScreenCenter(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    public func hide(immediately: Bool = false) {
        guard let panel else {
            print("[Panel] Hide called but no panel exists")
            return
        }

        print("[Panel] Hiding panel (immediately: \(immediately), isVisible: \(panel.isVisible))")

        if immediately {
            // Hide immediately without animation
            panel.alphaValue = 0
            panel.orderOut(nil)
            print("[Panel] Panel hidden immediately")
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            DispatchQueue.main.async {
                panel?.orderOut(nil)
            }
        })
    }

    public func resize(width: CGFloat, height: CGFloat) {
        guard let panel else { return }
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func positionAtScreenCenter(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
                ?? NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
