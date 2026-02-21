import SwiftUI
import AppKit

/// A thread-safe manager for accessing app icons (SF Symbols).
@MainActor
public class IconManager {
    public static let shared = IconManager()
    
    // Pre-loaded icons (SF Symbols)
    public let mic: NSImage
    public let x: NSImage
    public let trash2: NSImage
    public let clipboardCopy: NSImage
    public let cornerDownLeft: NSImage
    public let settings: NSImage
    public let play: NSImage
    public let pause: NSImage
    
    private init() {
        // Force load all icons on the main thread during initialization
        self.mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone") ?? NSImage()
        self.x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage()
        self.trash2 = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete") ?? NSImage()
        self.clipboardCopy = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage()
        self.cornerDownLeft = NSImage(systemSymbolName: "arrow.turn.down.left", accessibilityDescription: "Insert") ?? NSImage()
        self.settings = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings") ?? NSImage()
        self.play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play") ?? NSImage()
        self.pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause") ?? NSImage()
        
        Logger.debug("IconManager initialized - icons warmed up", category: .ui)
    }
    
    /// Call this method early in app launch to ensure icons are loaded
    public func warmup() {
        // Just accessing the singleton triggers init
    }
}
