# Liuyu MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu-bar voice input utility — hold a hotkey, speak, release, get transcribed text inserted into the active app.

**Architecture:** Menu bar app (LSUIElement) using CGEventTap for global hotkey, AVAudioEngine for recording, OpenAI Whisper API for transcription, and SwiftUI views hosted in an AppKit NSPanel for the floating UI. State flows one direction: hotkey → recording → transcription → clipboard/insert.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, AVFoundation, CoreGraphics, Security framework, SPM, lucide-icons-swift

**Environment:** No full Xcode — uses `swift build` / `swift test` from CLI. A bundling script creates the .app for runtime testing.

**Design doc:** `docs/plans/2026-02-10-mvp-design.md`

---

## Task 1: Project Scaffolding

**Files:**
- Create: `Package.swift`
- Create: `Sources/Liuyu/main.swift`
- Create: `Sources/Liuyu/Resources/Info.plist`
- Create: `Sources/Liuyu/Resources/Liuyu.entitlements`
- Create: `scripts/bundle.sh`

**Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Liuyu",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/JakubMazur/lucide-icons-swift.git", from: "0.563.1")
    ],
    targets: [
        .executableTarget(
            name: "Liuyu",
            dependencies: [
                .product(name: "LucideIcons", package: "lucide-icons-swift")
            ],
            path: "Sources/Liuyu",
            resources: [
                .copy("Resources/Info.plist")
            ]
        ),
        .testTarget(
            name: "LiuyuTests",
            dependencies: ["Liuyu"],
            path: "Tests/LiuyuTests"
        )
    ]
)
```

**Step 2: Create minimal main.swift entry point**

```swift
// Sources/Liuyu/main.swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

Also create a stub `AppDelegate.swift` so it compiles:

```swift
// Sources/Liuyu/App/AppDelegate.swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Liuyu launched")
    }
}
```

**Step 3: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Liuyu</string>
    <key>CFBundleIdentifier</key>
    <string>com.liuyu.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Liuyu</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Liuyu needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
```

**Step 4: Create entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

**Step 5: Create bundle.sh script**

```bash
#!/bin/bash
set -euo pipefail

BINARY_NAME="Liuyu"
APP_NAME="Liuyu.app"
BUILD_DIR=".build/release"
BUNDLE_DIR="build/${APP_NAME}"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "build/${APP_NAME}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${BINARY_NAME}" "${BUNDLE_DIR}/Contents/MacOS/"
cp "Sources/Liuyu/Resources/Info.plist" "${BUNDLE_DIR}/Contents/"

echo "App bundle created at build/${APP_NAME}"
echo "Run with: open build/${APP_NAME}"
```

Make it executable: `chmod +x scripts/bundle.sh`

**Step 6: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED (may take a while first time to fetch lucide-icons-swift)

**Step 7: Commit**

```bash
git add Package.swift Sources/ Tests/ scripts/ docs/plans/2026-02-10-mvp-implementation.md
git commit -m "feat: project scaffolding with SPM, Info.plist, and bundle script"
```

---

## Task 2: KeychainHelper

**Files:**
- Create: `Tests/LiuyuTests/KeychainHelperTests.swift`
- Create: `Sources/Liuyu/Settings/KeychainHelper.swift`

**Step 1: Write the failing tests**

```swift
// Tests/LiuyuTests/KeychainHelperTests.swift
import Testing
@testable import Liuyu

@Suite("KeychainHelper")
struct KeychainHelperTests {

    let testService = "com.liuyu.test.\(UUID().uuidString)"

    @Test("saves and reads a value")
    func saveAndRead() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "api-key", value: "sk-test-123")
        let result = try helper.read(key: "api-key")
        #expect(result == "sk-test-123")
        try helper.delete(key: "api-key")
    }

    @Test("returns nil for missing key")
    func readMissing() throws {
        let helper = KeychainHelper(service: testService)
        let result = try helper.read(key: "nonexistent")
        #expect(result == nil)
    }

    @Test("overwrites existing value")
    func overwrite() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "api-key", value: "old-value")
        try helper.save(key: "api-key", value: "new-value")
        let result = try helper.read(key: "api-key")
        #expect(result == "new-value")
        try helper.delete(key: "api-key")
    }

    @Test("delete removes value")
    func deleteKey() throws {
        let helper = KeychainHelper(service: testService)
        try helper.save(key: "api-key", value: "to-delete")
        try helper.delete(key: "api-key")
        let result = try helper.read(key: "api-key")
        #expect(result == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainHelperTests 2>&1`
Expected: FAIL — `KeychainHelper` not found

**Step 3: Implement KeychainHelper**

```swift
// Sources/Liuyu/Settings/KeychainHelper.swift
import Foundation
import Security

struct KeychainHelper {
    let service: String

    init(service: String = "com.liuyu.api") {
        self.service = service
    }

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Try to update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    func read(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.readFailed(status)
        }

        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode value"
        case .saveFailed(let s): return "Keychain save failed: \(s)"
        case .readFailed(let s): return "Keychain read failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter KeychainHelperTests 2>&1`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add Sources/Liuyu/Settings/KeychainHelper.swift Tests/LiuyuTests/KeychainHelperTests.swift
git commit -m "feat: add KeychainHelper with save/read/delete and tests"
```

---

## Task 3: TranscriptionService

**Files:**
- Create: `Tests/LiuyuTests/TranscriptionServiceTests.swift`
- Create: `Sources/Liuyu/Transcription/TranscriptionService.swift`

**Step 1: Write the failing tests**

```swift
// Tests/LiuyuTests/TranscriptionServiceTests.swift
import Testing
import Foundation
@testable import Liuyu

// Mock URLSession using URLProtocol
class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("TranscriptionService")
struct TranscriptionServiceTests {

    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("successful transcription returns text")
    func successfulTranscription() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"text": "Hello world"}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        // Create a tiny temp audio file for the test
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try await service.transcribe(audioFileURL: tempURL)
        #expect(result == "Hello world")
    }

    @Test("401 throws apiKeyInvalid error")
    func invalidApiKey() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"error": {"message": "Invalid API key"}}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-bad",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await #expect(throws: TranscriptionError.self) {
            try await service.transcribe(audioFileURL: tempURL)
        }
    }

    @Test("empty transcription returns noSpeechDetected error")
    func emptyTranscription() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let json = #"{"text": ""}"#
            return (response, json.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-test",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await #expect(throws: TranscriptionError.self) {
            try await service.transcribe(audioFileURL: tempURL)
        }
    }

    @Test("request includes correct multipart form data")
    func requestFormat() async throws {
        var capturedRequest: URLRequest?

        MockURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"text": "test"}"#.data(using: .utf8)!)
        }

        let service = TranscriptionService(
            apiKey: "sk-verify",
            endpoint: "https://api.openai.com/v1/audio/transcriptions",
            language: "en",
            session: makeSession()
        )

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.m4a")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await service.transcribe(audioFileURL: tempURL)

        let request = try #require(capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-verify")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.contains("multipart/form-data"))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter TranscriptionServiceTests 2>&1`
Expected: FAIL — `TranscriptionService` not found

**Step 3: Implement TranscriptionService**

```swift
// Sources/Liuyu/Transcription/TranscriptionService.swift
import Foundation

enum TranscriptionError: Error, LocalizedError {
    case apiKeyInvalid
    case apiKeyMissing
    case rateLimited
    case serverError(Int, String)
    case noSpeechDetected
    case networkError(Error)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .apiKeyInvalid: return "Invalid API key. Check Settings."
        case .apiKeyMissing: return "No API key configured. Open Settings to add one."
        case .rateLimited: return "Rate limited. Try again in a moment."
        case .serverError(let code, let msg): return "API error (\(code)): \(msg)"
        case .noSpeechDetected: return "No speech detected."
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingFailed: return "Failed to decode API response."
        }
    }
}

class TranscriptionService {
    let apiKey: String
    let endpoint: String
    let model: String
    let language: String?
    private let session: URLSession

    init(
        apiKey: String,
        endpoint: String = "https://api.openai.com/v1/audio/transcriptions",
        model: String = "whisper-1",
        language: String? = nil,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.session = session ?? {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
    }

    func transcribe(audioFileURL: URL, retryCount: Int = 0) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(fileURL: audioFileURL, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if retryCount < 1 {
                return try await transcribe(audioFileURL: audioFileURL, retryCount: retryCount + 1)
            }
            throw TranscriptionError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.decodingFailed
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data)
        case 401:
            throw TranscriptionError.apiKeyInvalid
        case 429:
            if retryCount < 1 {
                try await Task.sleep(for: .seconds(2))
                return try await transcribe(audioFileURL: audioFileURL, retryCount: retryCount + 1)
            }
            throw TranscriptionError.rateLimited
        default:
            let message = parseErrorMessage(data) ?? "Unknown error"
            throw TranscriptionError.serverError(httpResponse.statusCode, message)
        }
    }

    private func buildMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        // file field
        body.appendMultipart(boundary: boundary, name: "file", filename: filename,
                             contentType: "audio/m4a", data: fileData)
        // model field
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        // language field (optional)
        if let language {
            body.appendMultipart(boundary: boundary, name: "language", value: language)
        }
        // response_format field
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")
        // closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError.decodingFailed
        }
        if text.isEmpty {
            throw TranscriptionError.noSpeechDetected
        }
        return text
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String,
                                   contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TranscriptionServiceTests 2>&1`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add Sources/Liuyu/Transcription/TranscriptionService.swift Tests/LiuyuTests/TranscriptionServiceTests.swift
git commit -m "feat: add TranscriptionService with Whisper API client, retry logic, and tests"
```

---

## Task 4: HotkeyManager

**Files:**
- Create: `Sources/Liuyu/Hotkey/HotkeyManager.swift`

No unit tests — CGEventTap requires Accessibility permission and is system-level. Tested manually via Task 10.

**Step 1: Implement HotkeyManager**

```swift
// Sources/Liuyu/Hotkey/HotkeyManager.swift
import Foundation
import Combine
import CoreGraphics
import AppKit

enum HotkeyEvent {
    case keyDown
    case keyUp
}

class HotkeyManager {
    let events = PassthroughSubject<HotkeyEvent, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    /// The modifier flag to listen for. Default: right Option key.
    var modifierFlag: CGEventFlags = .maskAlternate

    /// Check if accessibility permission is granted.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user for accessibility permission. Returns true if already granted.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() throws {
        guard Self.isAccessibilityGranted else {
            Self.requestAccessibilityPermission()
            throw HotkeyError.accessibilityNotGranted
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags

        if flags.contains(modifierFlag) && !isKeyDown {
            isKeyDown = true
            events.send(.keyDown)
            return nil // suppress the event
        } else if !flags.contains(modifierFlag) && isKeyDown {
            isKeyDown = false
            events.send(.keyUp)
            return nil // suppress the event
        }

        return Unmanaged.passRetained(event)
    }
}

enum HotkeyError: Error, LocalizedError {
    case accessibilityNotGranted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
        case .tapCreationFailed:
            return "Failed to create event tap. Restart the app and try again."
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Liuyu/Hotkey/HotkeyManager.swift
git commit -m "feat: add HotkeyManager with CGEventTap for global modifier key detection"
```

---

## Task 5: RecordingController

**Files:**
- Create: `Sources/Liuyu/Audio/RecordingController.swift`

No unit tests — AVAudioEngine requires a real audio device. Tested manually via Task 10.

**Step 1: Implement RecordingController**

```swift
// Sources/Liuyu/Audio/RecordingController.swift
import Foundation
import AVFoundation
import Combine

class RecordingController: ObservableObject {
    @Published var audioLevel: Float = 0.0

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    enum RecordingError: Error, LocalizedError {
        case microphonePermissionDenied
        case engineStartFailed(Error)
        case fileCreationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access denied. Grant access in System Settings > Privacy & Security > Microphone."
            case .engineStartFailed(let e):
                return "Failed to start audio engine: \(e.localizedDescription)"
            case .fileCreationFailed(let e):
                return "Failed to create audio file: \(e.localizedDescription)"
            }
        }
    }

    /// Request microphone permission. Returns true if granted.
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start recording. Returns immediately. Call stop() to get the file URL.
    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create temp file with settings for the Whisper API
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuyu_\(UUID().uuidString).m4a")

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let outputFormat = AVAudioFormat(settings: outputSettings)!

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)
        } catch {
            throw RecordingError.fileCreationFailed(error)
        }

        // Install tap for audio data and metering
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, audioFile: audioFile)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw RecordingError.engineStartFailed(error)
        }

        self.engine = engine
        self.audioFile = audioFile
        self.tempFileURL = tempURL
    }

    /// Stop recording and return the temp file URL.
    func stop() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
        audioLevel = 0.0
        return tempFileURL
    }

    /// Clean up orphaned temp files from previous sessions.
    static func cleanupOrphanedFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.lastPathComponent.hasPrefix("liuyu_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Delete a specific recording file.
    static func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer,
                                converter: AVAudioConverter?,
                                audioFile: AVAudioFile) {
        // Calculate RMS audio level
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        var rms: Float = 0
        for i in 0..<frameCount {
            rms += channelData[i] * channelData[i]
        }
        rms = sqrt(rms / Float(max(frameCount, 1)))

        // Normalize to 0...1 (typical speech RMS is -40dB to -10dB)
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 50) / 50))

        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = normalized
        }

        // Write converted audio to file
        if let converter {
            let outputFrameCapacity = AVAudioFrameCount(
                ceil(Double(buffer.frameLength) * (16000.0 / buffer.format.sampleRate))
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            var error: NSError?
            var hasData = false
            converter.convert(to: convertedBuffer, error: &error) { _, status in
                if hasData {
                    status.pointee = .noDataNow
                    return nil
                }
                hasData = true
                status.pointee = .haveData
                return buffer
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                try? audioFile.write(from: convertedBuffer)
            }
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Liuyu/Audio/RecordingController.swift
git commit -m "feat: add RecordingController with AVAudioEngine capture and real-time metering"
```

---

## Task 6: FloatingPanelController & PanelViewModel

**Files:**
- Create: `Sources/Liuyu/UI/PanelViewModel.swift`
- Create: `Sources/Liuyu/UI/FloatingPanelController.swift`

**Step 1: Implement PanelViewModel**

```swift
// Sources/Liuyu/UI/PanelViewModel.swift
import Foundation
import AppKit
import Combine

enum PanelState {
    case hidden
    case recording(audioLevel: Float)
    case processing
    case result(text: String)
}

enum PanelAction {
    case insert(String)
    case copy(String)
    case clear
    case cancel
}

class PanelViewModel: ObservableObject {
    @Published var state: PanelState = .hidden
    let actions = PassthroughSubject<PanelAction, Never>()

    private var autoDismissTimer: Timer?
    private let autoDismissInterval: TimeInterval = 10.0

    func showRecording() {
        cancelAutoDismiss()
        state = .recording(audioLevel: 0)
    }

    func updateAudioLevel(_ level: Float) {
        state = .recording(audioLevel: level)
    }

    func showProcessing() {
        cancelAutoDismiss()
        state = .processing
    }

    func showResult(_ text: String) {
        state = .result(text: text)
        startAutoDismiss()
    }

    func hide() {
        cancelAutoDismiss()
        state = .hidden
    }

    // MARK: - User Actions

    func insertText() {
        guard case .result(let text) = state else { return }
        actions.send(.insert(text))
        hide()
    }

    func copyText() {
        guard case .result(let text) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        actions.send(.copy(text))
    }

    func clearResult() {
        actions.send(.clear)
        hide()
    }

    func cancel() {
        actions.send(.cancel)
        hide()
    }

    // MARK: - Auto-dismiss

    private func startAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissInterval, repeats: false) { [weak self] _ in
            self?.cancel()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }
}
```

**Step 2: Implement FloatingPanelController**

```swift
// Sources/Liuyu/UI/FloatingPanelController.swift
import AppKit
import SwiftUI

class FloatingPanelController {
    private var panel: NSPanel?
    let viewModel = PanelViewModel()

    func setup() {
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

        let hostingView = NSHostingView(rootView: PanelContentView(viewModel: viewModel))
        panel.contentView = hostingView

        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        positionAtScreenCenter(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    func resize(width: CGFloat, height: CGFloat) {
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
```

**Step 3: Create a placeholder PanelContentView (will be filled in Task 7)**

```swift
// Sources/Liuyu/UI/PanelContentView.swift
import SwiftUI

struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        switch viewModel.state {
        case .hidden:
            EmptyView()
        case .recording(let audioLevel):
            RecordingView(audioLevel: audioLevel, onClose: viewModel.cancel)
        case .processing:
            ProcessingView()
        case .result(let text):
            ResultView(
                text: text,
                onInsert: viewModel.insertText,
                onCopy: viewModel.copyText,
                onClear: viewModel.clearResult
            )
        }
    }
}
```

Also create stubs for the three views so it compiles:

```swift
// Sources/Liuyu/UI/RecordingView.swift
import SwiftUI

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    var body: some View {
        Text("Recording... \(audioLevel)")
    }
}
```

```swift
// Sources/Liuyu/UI/ProcessingView.swift
import SwiftUI

struct ProcessingView: View {
    var body: some View {
        Text("Processing...")
    }
}
```

```swift
// Sources/Liuyu/UI/ResultView.swift
import SwiftUI

struct ResultView: View {
    let text: String
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        Text(text)
    }
}
```

**Step 4: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/Liuyu/UI/
git commit -m "feat: add FloatingPanelController, PanelViewModel, and stub views"
```

---

## Task 7: SwiftUI Views

**Files:**
- Modify: `Sources/Liuyu/UI/RecordingView.swift`
- Modify: `Sources/Liuyu/UI/ProcessingView.swift`
- Modify: `Sources/Liuyu/UI/ResultView.swift`

**Step 1: Implement RecordingView with waveform bars**

```swift
// Sources/Liuyu/UI/RecordingView.swift
import SwiftUI
import LucideIcons

struct RecordingView: View {
    let audioLevel: Float
    let onClose: () -> Void

    // Rolling buffer of recent audio levels for waveform bars
    @State private var levels: [Float] = Array(repeating: 0, count: 7)

    var body: some View {
        HStack(spacing: 12) {
            // Mic icon
            Image(nsImage: Lucide.mic)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)

            // Waveform bars
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 4, height: CGFloat(8 + levels[index] * 32))
                        .animation(.easeInOut(duration: 0.08), value: levels[index])
                }
            }

            Spacer()

            // Close button
            Button(action: onClose) {
                Image(nsImage: Lucide.x)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: audioLevel) { _, newValue in
            levels.removeFirst()
            levels.append(newValue)
        }
    }
}
```

**Step 2: Implement ProcessingView**

```swift
// Sources/Liuyu/UI/ProcessingView.swift
import SwiftUI
import LucideIcons

struct ProcessingView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: Lucide.mic)
                .resizable()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)

            ProgressView()
                .scaleEffect(0.8)

            Text("Transcribing...")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 280, height: 80)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
```

**Step 3: Implement ResultView with action buttons and keyboard handling**

```swift
// Sources/Liuyu/UI/ResultView.swift
import SwiftUI
import LucideIcons

struct ResultView: View {
    let text: String
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Transcribed text
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: Lucide.mic)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Action buttons
            HStack(spacing: 8) {
                Spacer()

                Button(action: onClear) {
                    Label {
                        Text("Clear")
                    } icon: {
                        Image(nsImage: Lucide.trash2)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onCopy) {
                    Label {
                        Text("Copy")
                    } icon: {
                        Image(nsImage: Lucide.clipboardCopy)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onInsert) {
                    Label {
                        Text("Insert")
                    } icon: {
                        Image(nsImage: Lucide.cornerDownLeft)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 400, height: 120)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onKeyPress(.return) {
            onInsert()
            return .handled
        }
        .onKeyPress(.escape) {
            onClear()
            return .handled
        }
    }
}
```

**Note:** The Lucide icon property names (`Lucide.mic`, `Lucide.trash2`, etc.) may differ from the exact API. The implementing agent should verify icon names by checking the package's source or auto-complete, and adjust accordingly. Likely candidates: `Lucide.mic`, `Lucide.x`, `Lucide.trash2`, `Lucide.clipboardCopy`, `Lucide.cornerDownLeft`.

**Step 4: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED (adjust Lucide icon names if compiler errors on unknown properties)

**Step 5: Commit**

```bash
git add Sources/Liuyu/UI/RecordingView.swift Sources/Liuyu/UI/ProcessingView.swift Sources/Liuyu/UI/ResultView.swift
git commit -m "feat: implement RecordingView with waveform, ProcessingView, and ResultView with actions"
```

---

## Task 8: Settings Window

**Files:**
- Modify: `Sources/Liuyu/Settings/SettingsView.swift` (create)
- Create: `Sources/Liuyu/Settings/SettingsWindowController.swift`

**Step 1: Implement SettingsView**

```swift
// Sources/Liuyu/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @AppStorage("endpoint") private var endpoint = "https://api.openai.com/v1/audio/transcriptions"
    @AppStorage("language") private var language = "auto"
    @State private var saveMessage: String?

    private let keychain = KeychainHelper()

    var body: some View {
        Form {
            Section("API Configuration") {
                SecureField("API Key", text: $apiKey, prompt: Text(hasExistingKey ? "••••••••••••(saved)" : "sk-..."))

                TextField("Endpoint URL", text: $endpoint)

                Picker("Language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Chinese (Simplified)").tag("zh")
                }
            }

            Section("Hotkey") {
                LabeledContent("Activation Key", value: "Right Option (⌥)")
                Text("Custom hotkeys coming in a future version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Button("Save") {
                    saveApiKey()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 320)
        .onAppear {
            loadApiKey()
        }
    }

    private func loadApiKey() {
        if let key = try? keychain.read(key: "openai-api-key"), !key.isEmpty {
            hasExistingKey = true
        }
    }

    private func saveApiKey() {
        if !apiKey.isEmpty {
            try? keychain.save(key: "openai-api-key", value: apiKey)
            hasExistingKey = true
            apiKey = ""
        }
        saveMessage = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveMessage = nil
        }
    }
}
```

**Step 2: Implement SettingsWindowController**

```swift
// Sources/Liuyu/Settings/SettingsWindowController.swift
import AppKit
import SwiftUI

class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Liuyu Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
```

**Step 3: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/Liuyu/Settings/SettingsView.swift Sources/Liuyu/Settings/SettingsWindowController.swift
git commit -m "feat: add SettingsView with API key form and SettingsWindowController"
```

---

## Task 9: AppDelegate — Wire Everything Together

**Files:**
- Modify: `Sources/Liuyu/App/AppDelegate.swift`

This is the orchestration layer. It wires HotkeyManager → RecordingController → TranscriptionService → FloatingPanelController.

**Step 1: Implement the full AppDelegate**

```swift
// Sources/Liuyu/App/AppDelegate.swift
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let recordingController = RecordingController()
    private let panelController = FloatingPanelController()
    private let settingsController = SettingsWindowController()

    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?
    private var recordingStartTime: Date?
    private var currentAudioFileURL: URL?

    private let keychain = KeychainHelper()
    private let minimumRecordingDuration: TimeInterval = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        RecordingController.cleanupOrphanedFiles()
        setupStatusItem()
        panelController.setup()
        setupHotkeySubscription()
        setupPanelActions()
        startHotkeyManager()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Liuyu")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey

    private func startHotkeyManager() {
        guard HotkeyManager.isAccessibilityGranted else {
            HotkeyManager.requestAccessibilityPermission()
            // Poll for permission
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if HotkeyManager.isAccessibilityGranted {
                    timer.invalidate()
                    try? self?.hotkeyManager.start()
                }
            }
            return
        }
        try? hotkeyManager.start()
    }

    private func setupHotkeySubscription() {
        hotkeyManager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                switch event {
                case .keyDown:
                    self?.handleKeyDown()
                case .keyUp:
                    self?.handleKeyUp()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording Flow

    private func handleKeyDown() {
        // Save the currently focused app before showing our panel
        previousApp = NSWorkspace.shared.frontmostApplication

        panelController.viewModel.showRecording()
        panelController.show()

        do {
            try recordingController.start()
            recordingStartTime = Date()
        } catch {
            panelController.viewModel.showResult("Error: \(error.localizedDescription)")
            return
        }

        // Bind audio level to view model
        recordingController.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.panelController.viewModel.updateAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    private func handleKeyUp() {
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            // Wait for minimum duration
            let remaining = minimumRecordingDuration - elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.stopRecordingAndTranscribe()
            }
        } else {
            stopRecordingAndTranscribe()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let audioURL = recordingController.stop() else {
            panelController.viewModel.showResult("Error: No audio recorded.")
            return
        }

        currentAudioFileURL = audioURL
        panelController.viewModel.showProcessing()
        panelController.resize(width: 280, height: 80)

        Task {
            await transcribe(audioURL: audioURL)
        }
    }

    private func transcribe(audioURL: URL) async {
        guard let apiKey = try? keychain.read(key: "openai-api-key"), !apiKey.isEmpty else {
            await MainActor.run {
                panelController.viewModel.showResult("No API key configured. Open Settings to add one.")
                panelController.resize(width: 400, height: 120)
                settingsController.show()
            }
            return
        }

        let endpoint = UserDefaults.standard.string(forKey: "endpoint")
            ?? "https://api.openai.com/v1/audio/transcriptions"
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"

        let service = TranscriptionService(
            apiKey: apiKey,
            endpoint: endpoint,
            language: language == "auto" ? nil : language
        )

        do {
            let text = try await service.transcribe(audioFileURL: audioURL)
            await MainActor.run {
                panelController.viewModel.showResult(text)
                panelController.resize(width: 400, height: 120)
            }
        } catch {
            await MainActor.run {
                panelController.viewModel.showResult("Error: \(error.localizedDescription)")
                panelController.resize(width: 400, height: 120)
            }
        }
    }

    // MARK: - Panel Actions

    private func setupPanelActions() {
        panelController.viewModel.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.handlePanelAction(action)
            }
            .store(in: &cancellables)
    }

    private func handlePanelAction(_ action: PanelAction) {
        switch action {
        case .insert(let text):
            insertText(text)
            cleanupCurrentAudio()
        case .copy:
            // Already copied in PanelViewModel
            break
        case .clear, .cancel:
            cleanupCurrentAudio()
        }

        panelController.hide()
    }

    private func insertText(_ text: String) {
        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Re-activate the previous app
        previousApp?.activate()

        // Small delay to let the app activate, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V key
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func cleanupCurrentAudio() {
        if let url = currentAudioFileURL {
            RecordingController.deleteRecording(at: url)
            currentAudioFileURL = nil
        }
    }
}
```

**Step 2: Verify it compiles**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Liuyu/App/AppDelegate.swift
git commit -m "feat: wire AppDelegate with hotkey, recording, transcription, and panel orchestration"
```

---

## Task 10: Integration Test & First-Launch Flow

**Files:**
- Modify: `Sources/Liuyu/App/AppDelegate.swift` (add first-launch check)

**Step 1: Add first-launch API key check**

In `AppDelegate.applicationDidFinishLaunching`, after `startHotkeyManager()`, add:

```swift
// Check for first launch (no API key)
if (try? keychain.read(key: "openai-api-key")) == nil {
    settingsController.show()
}
```

**Step 2: Build the app bundle**

Run: `bash scripts/bundle.sh 2>&1`
Expected: "App bundle created at build/Liuyu.app"

**Step 3: Manual integration test**

Run: `open build/Liuyu.app`

Test checklist:
1. App appears in menu bar with mic icon (no Dock icon)
2. Clicking menu bar icon shows Settings... and Quit options
3. If no API key: settings window opens automatically
4. Enter API key, save, close settings
5. Grant Accessibility permission when prompted
6. Hold right Option key: recording panel appears with waveform
7. Release: processing spinner, then transcription result
8. Press Enter: text pastes into previously focused app
9. Press Escape: result dismissed
10. Cmd+C in result: text copied to clipboard

**Step 4: Fix any issues found during manual testing**

Iterate on any bugs. Common issues:
- Lucide icon names may not match — check auto-complete for correct property names
- `onKeyPress` requires macOS 14+; if targeting macOS 13, use `NSEvent.addLocalMonitorForEvents` in the panel instead
- Audio format conversion issues — verify temp file is valid audio

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: add first-launch flow and integration polish"
```

---

## Summary

| Task | What | Tests |
|------|------|-------|
| 1 | Project scaffolding (SPM, Info.plist, bundle script) | Compiles |
| 2 | KeychainHelper | 4 unit tests |
| 3 | TranscriptionService | 4 unit tests |
| 4 | HotkeyManager (CGEventTap) | Manual |
| 5 | RecordingController (AVAudioEngine) | Manual |
| 6 | FloatingPanelController + PanelViewModel | Compiles |
| 7 | SwiftUI Views (Recording, Processing, Result) | Visual |
| 8 | Settings Window | Visual |
| 9 | AppDelegate wiring | Integration |
| 10 | First-launch flow + manual integration test | Manual E2E |
