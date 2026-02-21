import Foundation
import OSLog

public struct Logger {
    /// The subsystem identifier for the app
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.liuyu.app"
    
    /// Categories for organizing logs
    public enum Category: String {
        case app = "App"
        case audio = "Audio"
        case hotkey = "Hotkey"
        case ui = "UI"
        case stt = "STT"
        case settings = "Settings"
    }
    
    /// Debug mode flag controlled by environment variable "LIUYU_DEBUG"
    /// Also defaults to true if the DEBUG compiler flag is set (Xcode Debug build)
    public static let isDebugEnabled: Bool = {
        #if DEBUG
        return true
        #else
        let env = ProcessInfo.processInfo.environment["LIUYU_DEBUG"]?.lowercased()
        return env == "1" || env == "true" || env == "yes"
        #endif
    }()
    
    // MARK: - Logging Methods
    
    /// Log informational messages (always visible in Console.app)
    public static func info(_ message: String, category: Category = .app) {
        log(message, type: .info, category: category)
    }
    
    /// Log debug messages (only visible if debug mode is enabled or in memory)
    public static func debug(_ message: String, category: Category = .app) {
        // In our custom wrapper, we can filter out debug logs entirely if env var is not set
        // to avoid cluttering the console during standard runs
        if isDebugEnabled {
            log(message, type: .debug, category: category)
        }
    }
    
    /// Log warning messages (for potential issues)
    public static func warning(_ message: String, category: Category = .app) {
        log(message, type: .error, category: category) // OSLog doesn't have .warning, use .error or .default
    }
    
    /// Log error messages (for critical failures)
    public static func error(_ message: String, category: Category = .app) {
        log(message, type: .fault, category: category)
    }
    
    // MARK: - Internal Implementation
    
    private static func log(_ message: String, type: OSLogType, category: Category) {
        let log = OSLog(subsystem: subsystem, category: category.rawValue)
        os_log("%{public}@", log: log, type: type, message)
        
        // Also print to stdout for Xcode console visibility if needed, 
        // though OSLog also shows up there. This format mimics the old print style.
        if isDebugEnabled || type == .fault || type == .error {
            let icon = typeIcon(for: type)
            print("\(icon) [\(category.rawValue)] \(message)")
        }
    }
    
    private static func typeIcon(for type: OSLogType) -> String {
        switch type {
        case .info: return "ℹ️"
        case .debug: return "🐞"
        case .error: return "⚠️"
        case .fault: return "🔥"
        default: return "📝"
        }
    }
}
