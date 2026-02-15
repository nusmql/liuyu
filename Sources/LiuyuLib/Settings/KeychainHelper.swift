import Foundation

/// File-based key storage in ~/Library/Application Support/Liuyu/keys/.
/// Avoids macOS Keychain issues with unsigned development builds (password
/// prompts, code-signature mismatches, Data Protection entitlement requirements).
public struct KeychainHelper: Sendable {
    public let service: String

    public init(service: String = "com.liuyu.api") {
        self.service = service
    }

    private var storageDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("Liuyu")
            .appendingPathComponent("keys")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func fileURL(for key: String) -> URL {
        // Sanitize key for filesystem
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return storageDir.appendingPathComponent(safe)
    }

    public func save(key: String, value: String) throws {
        let url = fileURL(for: key)
        try value.write(to: url, atomically: true, encoding: .utf8)
        // Restrict to owner read/write only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func read(key: String) throws -> String? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try String(contentsOf: url, encoding: .utf8)
        return value.isEmpty ? nil : value
    }

    public func delete(key: String) throws {
        let url = fileURL(for: key)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode value"
        case .saveFailed(let s): return "Key storage save failed: \(s)"
        case .readFailed(let s): return "Key storage read failed: \(s)"
        case .deleteFailed(let s): return "Key storage delete failed: \(s)"
        }
    }
}
