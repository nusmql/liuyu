// Sources/LiuyuLib/App/AppDelegate.swift
import AppKit
import Combine

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    nonisolated(unsafe) private var hotkeyManager = HotkeyManager()
    private let recordingController = RecordingController()
    private let panelController = FloatingPanelController()
    private let settingsController = SettingsWindowController()
    private let editController = EditWindowController()
    private let onboardingController = OnboardingWindowController()

    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var previousApp: NSRunningApplication?
    private var currentAudioFileURL: URL?
    private var accessibilityPollTimer: Timer?

    private let providerStore = ProviderConfigStore()

    // Streaming transcription support
    private var streamingSession: StreamingTranscriptionSession?
    private var streamingTask: Task<Void, Never>?
    private var accumulatedText = ""

    /// Background WebSocket connection for zero-latency recording
    private var backgroundSession: StreamingTranscriptionSession?
    private var backgroundSessionTask: Task<Void, Never>?
    private var lastUsedSession: Date?

    /// Recording state manager
    private let recordingState = RecordingState.shared

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm up icons early to prevent concurrent access crashes
        IconManager.shared.warmup()
        
        AppTheme.applyFromDefaults()
        providerStore.migrateIfNeeded()
        RecordingController.cleanupOrphanedFiles()

        // Pre-warm WebSocket connection if using streaming model
        prewarmWebSocketConnection()

        setupMainMenu()
        setupStatusItem()
        panelController.setup()
        setupHotkeySubscription()
        setupPanelActions()
        applyHotkeyShortcut()
        setupHotkeyRefresh()
        startHotkeyManager()
        setupSettingsChangeListener()

        // Centralize activation policy: only go accessory when ALL windows are closed
        let updatePolicy: () -> Void = { [weak self] in
            self?.updateActivationPolicy()
        }
        settingsController.onWindowClose = updatePolicy
        settingsController.onWindowShow = updatePolicy
        editController.onWindowClose = updatePolicy
        editController.onWindowShow = updatePolicy
        onboardingController.onWindowClose = updatePolicy
        onboardingController.onWindowShow = updatePolicy

        // First launch: show onboarding wizard
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            onboardingController.onComplete = { [weak self] in
                self?.updateActivationPolicy()
                // Show Settings after onboarding so user can verify/tweak
                self?.settingsController.show()
            }
            onboardingController.show()
        }
    }

    private func updateActivationPolicy() {
        // Debounce policy updates to avoid layout conflicts
        DispatchQueue.main.async {
            let isVisible = self.settingsController.isWindowVisible ||
                           self.editController.isWindowVisible ||
                           self.onboardingController.isWindowVisible

            // If any window is visible, we should be in regular mode (dock icon)
            // This ensures the user can find the app/window if they switch away
            let targetPolicy: NSApplication.ActivationPolicy = isVisible ? .regular : .accessory

            if NSApp.activationPolicy() != targetPolicy {
                NSApp.setActivationPolicy(targetPolicy)
                Logger.debug("ActivationPolicy changed to \(targetPolicy == .regular ? ".regular" : ".accessory") (visible: \(isVisible))", category: .ui)
                
                // If switching to regular, bring to front
                if targetPolicy == .regular {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    // MARK: - Main Menu (enables Cmd+C/V/X/A in text fields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Load custom icon from Resources directory
            if let customImage = loadMenuIcon() {
                customImage.isTemplate = true  // Allows macOS to recolor for dark/light mode
                // customImage.isTemplate = false // Render original image colors to check for background
                button.image = customImage
            } else {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Liuyu")
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open...", action: #selector(openEdit), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func loadMenuIcon() -> NSImage? {
        // Try multiple locations for the menu icon
        var possiblePaths: [URL] = [
            // App bundle Resources (production) - @2x first
            Bundle.main.resourceURL?.appendingPathComponent("MenuIcon_18@2x.png"),
            Bundle.main.resourceURL?.appendingPathComponent("MenuIcon_18.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MenuIcon_18@2x.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MenuIcon_18.png"),
        ].compactMap { $0 }

        // Try Bundle.module for SPM resources
        // Note: Bundle.module is auto-generated by SPM when resources are included in Package.swift
        if let modulePath = Bundle.module.url(forResource: "MenuIcon_18@2x", withExtension: "png") {
            possiblePaths.append(modulePath)
        }
        if let modulePath = Bundle.module.url(forResource: "MenuIcon_18", withExtension: "png") {
            possiblePaths.append(modulePath)
        }

        for path in possiblePaths {
            let exists = FileManager.default.fileExists(atPath: path.path)
            Logger.debug("MenuIcon Checking path: \(path.path), exists: \(exists)", category: .ui)
            if exists,
               let image = NSImage(contentsOf: path) {
                // For status bar, we want template mode so it adapts to dark/light
                image.isTemplate = true
                // Set the logical size (18x18), actual pixels depend on @1x or @2x
                image.size = NSSize(width: 18, height: 18)
                Logger.info("MenuIcon Loaded image from: \(path.path), size: \(image.size)", category: .ui)
                return image
            }
        }
        Logger.warning("Failed to load any menu icon, using fallback", category: .ui)
        return nil
    }

    @objc private func openEdit() {
        editController.show()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey

    private func applyHotkeyShortcut() {
        hotkeyManager.shortcut = RecordedShortcut.loadFromDefaults()
    }

    private func startHotkeyManager() {
        guard HotkeyManager.isAccessibilityGranted else {
            // Don't show the system prompt — poll silently instead.
            // The user may have already granted permission for a different binary path.
            HotkeyManager.requestAccessibilityPermission(prompt: false)
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if HotkeyManager.isAccessibilityGranted {
                        self?.accessibilityPollTimer?.invalidate()
                        self?.accessibilityPollTimer = nil
                        try? self?.hotkeyManager.start()
                    }
                }
            }
            return
        }
        try? hotkeyManager.start()
    }

    private func setupHotkeySubscription() {
        Logger.debug("Setting up hotkey subscription", category: .app)

        // Forward hotkey events to RecordingState
        hotkeyManager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                Logger.debug("Hotkey event received: \(event), shortcut: \(self.hotkeyManager.shortcut.displayString)", category: .hotkey)
                switch event {
                case .keyDown:
                    self.recordingState.keyDown()
                case .keyUp:
                    self.recordingState.keyUp()
                }
            }
            .store(in: &cancellables)

        // Subscribe to RecordingState phase changes
        recordingState.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.handleRecordingPhaseChange(phase)
            }
            .store(in: &cancellables)

        // Update hotkeyManager when RecordingState changes
        recordingState.$phase
            .map { $0.isActive }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.hotkeyManager.isRecording = isActive
            }
            .store(in: &cancellables)
    }

    private func handleRecordingPhaseChange(_ phase: RecordingState.RecordingPhase) {
        Logger.debug("Recording phase changed to: \(phase)", category: .app)

        switch phase {
        case .debouncing:
            // Background WebSocket connection is already maintained
            // No need to prepare anything here
            break

        case .recording:
            startRecordingUI()

        case .processing:
            stopRecordingUI()

        case .completed(let text):
            showTranscriptionResult(text)

        case .error(let message):
            showError(message)
            recordingState.cancel()

        case .idle:
            // Cleanup if needed
            break
        }
    }

    private var wasHotkeyActiveBeforeRecording = false

    private func setupHotkeyRefresh() {
        NotificationCenter.default
            .publisher(for: .hotkeyShortcutChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let shortcut = notification.object as? RecordedShortcut {
                    Logger.debug("Shortcut changed to: \(shortcut.displayString)", category: .hotkey)
                    self?.hotkeyManager.shortcut = shortcut
                } else {
                    Logger.debug("Shortcut changed to nil (stopping)", category: .hotkey)
                    self?.hotkeyManager.stop()
                }
            }
            .store(in: &cancellables)

        // Pause hotkey during shortcut recording to avoid conflicts
        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidBegin)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Logger.debug("Pausing hotkey for recording", category: .hotkey)
                // Remember if hotkey was active (has valid shortcut)
                self.wasHotkeyActiveBeforeRecording = self.hotkeyManager.shortcut.isValid
                // Stop the hotkey manager temporarily
                self.hotkeyManager.stop()
            }
            .store(in: &cancellables)

        // Resume hotkey after shortcut recording ends
        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidEnd)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Logger.debug("Resuming hotkey after recording", category: .hotkey)
                // Only restart if hotkey was active before and we have accessibility permission
                if self.wasHotkeyActiveBeforeRecording && HotkeyManager.isAccessibilityGranted {
                    try? self.hotkeyManager.start()
                }
            }
            .store(in: &cancellables)

        // Detect app deactivation during recording (user clicked elsewhere)
        NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.recordingState.phase.isRecording else { return }
                Logger.info("App lost focus during recording - auto-stopping", category: .app)
                self.recordingState.keyUp()
            }
            .store(in: &cancellables)
    }

    /// Listen for settings changes to re-warm WebSocket when model changes
    private func setupSettingsChangeListener() {
        NotificationCenter.default
            .publisher(for: Notification.Name("sttModelChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Logger.info("STT model changed, re-warming WebSocket...", category: .settings)
                Task {
                    // Close existing connection
                    await self?.cleanupStreaming()
                    // Start new pre-warm
                    self?.prewarmWebSocketConnection()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - WebSocket Pre-warming

    /// Pre-warm WebSocket connection for streaming models
    /// Establishes persistent connection at app startup and maintains it
    private func prewarmWebSocketConnection() {
        // Cancel any existing background connection task
        backgroundSessionTask?.cancel()

        backgroundSessionTask = Task { @MainActor in
            // Wait a moment for app to fully initialize
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            guard !Task.isCancelled else { return }

            await establishBackgroundConnection()
        }
    }

    /// Establish and maintain background WebSocket connection
    private func establishBackgroundConnection() async {
        // Get current STT config
        let feature = providerStore.loadFeatureConfig()
        guard let stt = feature.sttPrimary,
              let params = providerStore.resolveSTT(stt),
              params.apiFormat == .alibabaRealtime || params.apiFormat == .tencentRealtime else {
            Logger.debug("No WebSocket STT configured, skipping background connection", category: .stt)
            return
        }

        Logger.info("🌡️ Establishing background WebSocket connection for \(params.model)...", category: .stt)

        // Create new session
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )

        let session = service.createStreamingSession()
        self.backgroundSession = session

        do {
            try await session.connect()
            Logger.info("🌡️ Background WebSocket connected and ready", category: .stt)
            lastUsedSession = Date()

            // Start heartbeat to keep connection alive
            await maintainConnection(session: session)
        } catch {
            Logger.error("🌡️ Background WebSocket connection failed: \(error)", category: .stt)

            // Retry after delay if not cancelled
            if !Task.isCancelled {
                Logger.info("🌡️ Will retry connection in 5 seconds...", category: .stt)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    await establishBackgroundConnection()
                }
            }
        }
    }

    /// Maintain connection with periodic checks and reconnection
    private func maintainConnection(session: StreamingTranscriptionSession) async {
        // Check connection every 10 seconds
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds

            guard !Task.isCancelled else { break }

            // If session hasn't been used for 60 seconds, disconnect to save resources
            // It will be reconnected when needed
            if let lastUsed = lastUsedSession,
               Date().timeIntervalSince(lastUsed) > 60 {
                Logger.info("🌡️ Background connection idle for 60s, disconnecting", category: .stt)
                await session.disconnect()
                backgroundSession = nil
                break
            }
        }
    }

    /// Get background session for recording (if available and fresh)
    /// Returns nil if no valid background session exists
    private func getBackgroundSession() -> StreamingTranscriptionSession? {
        guard let session = backgroundSession else { return nil }

        // Check if session is still fresh (used within last 55 seconds)
        guard let lastUsed = lastUsedSession,
              Date().timeIntervalSince(lastUsed) < 55 else {
            Logger.info("🌡️ Background session too old, will create new connection", category: .stt)
            return nil
        }

        Logger.info("🌡️ Using background WebSocket session (zero latency)", category: .stt)
        return session
    }

    /// Mark background session as used (call when starting recording)
    private func markSessionUsed() {
        lastUsedSession = Date()
    }

    /// Reconnect background session after settings change
    func reconnectBackgroundSession() {
        Logger.info("🌡️ Reconnecting background session due to settings change", category: .stt)

        // Disconnect existing
        Task {
            if let session = backgroundSession {
                await session.disconnect()
                backgroundSession = nil
            }

            // Establish new connection
            await establishBackgroundConnection()
        }
    }

    // MARK: - Recording Flow (using RecordingState)

    /// Called when RecordingState enters .recording phase
    private func startRecordingUI() {
        Logger.info("🎬 [T0] startRecordingUI called", category: .app)
        previousApp = NSWorkspace.shared.frontmostApplication

        panelController.viewModel.showRecording()
        panelController.show()
        Logger.debug("Panel shown for recording", category: .ui)

        // Check if we should use streaming transcription
        let feature = providerStore.loadFeatureConfig()
        if let stt = feature.sttPrimary,
           let params = providerStore.resolveSTT(stt),
           params.apiFormat == .alibabaRealtime || params.apiFormat == .tencentRealtime {
            Logger.info("🎬 Using streaming mode for \(params.model)", category: .app)
            Task {
                await startStreamingRecording(params: params)
            }
            return
        }

        // Use traditional file-based recording
        do {
            Logger.info("🎬 Using file-based recording", category: .app)
            try recordingController.start()

            // Forward audio levels to RecordingState
            recordingController.$audioLevel
                .receive(on: DispatchQueue.main)
                .sink { [weak self] level in
                    self?.recordingState.updateAudioActivity(level: level)
                    self?.panelController.viewModel.updateAudioLevel(level)
                }
                .store(in: &cancellables)
        } catch {
            Logger.error("Failed to start recording: \(error)", category: .audio)
            panelController.hide()
            recordingState.cancel()
        }
    }

    /// Start streaming recording with real-time transcription
    /// Uses pre-connected session if available, otherwise creates new connection
    @MainActor
    private func startStreamingRecording(params: (apiKey: String, endpoint: String, model: String, apiFormat: ApiFormat)) async {
        Logger.info("🎬 [T1] startStreamingRecording called - model: \(params.model)", category: .app)

        do {
            // STEP 1: Start recording IMMEDIATELY to capture all audio
            // Background WebSocket connection is already ready
            Logger.info("🎬 [T2] Starting audio recording...", category: .audio)
            try recordingController.startStreaming()
            Logger.info("🎬 [T3] Audio recording started", category: .audio)

            // Forward audio levels to RecordingState
            recordingController.$audioLevel
                .receive(on: DispatchQueue.main)
                .sink { [weak self] level in
                    self?.recordingState.updateAudioActivity(level: level)
                    self?.panelController.viewModel.updateAudioLevel(level)
                }
                .store(in: &cancellables)

            // STEP 3: Use background session (zero latency) or create new connection
            if let background = getBackgroundSession() {
                Logger.info("🎬 [T4] Using background WebSocket session (zero latency)", category: .stt)
                streamingSession = background
                backgroundSession = nil // Take ownership
                markSessionUsed()

                // Re-establish background connection for next time
                prewarmWebSocketConnection()
            } else {
                Logger.info("🎬 [T4] No background session, creating new WebSocket connection...", category: .stt)
                let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
                let service = TranscriptionService(
                    apiKey: params.apiKey,
                    endpoint: params.endpoint,
                    model: params.model,
                    language: language == "auto" ? nil : language,
                    apiFormat: params.apiFormat
                )
                streamingSession = service.createStreamingSession()
                do {
                    try await streamingSession?.connect()
                    Logger.info("🎬 [T5] WebSocket connected", category: .stt)
                } catch {
                    Logger.error("🎬 [T5] WebSocket connection failed: \(error)", category: .stt)
                }
            }

            // STEP 3: Set up streaming handler (sends buffered audio if any)
            recordingController.setStreamingHandler { [weak self] chunk in
                Task { [weak self] in
                    do {
                        try await self?.streamingSession?.sendAudioChunk(chunk, isFinal: false)
                    } catch {
                        Logger.error("Failed to send audio chunk: \(error)", category: .stt)
                    }
                }
            }
            Logger.info("🎬 [T6] Streaming handler set up", category: .audio)

            // STEP 4: Start listening for transcription results
            startStreamingResultsListener()

            Logger.debug("Recording started (streaming)", category: .app)
        } catch {
            Logger.error("Failed to start streaming recording: \(error)", category: .app)
            panelController.hide()
            recordingState.cancel()
            await cleanupStreaming()
        }
    }

    /// Listen for streaming transcription results
    private func startStreamingResultsListener() {
        if let oldTask = streamingTask {
            Logger.info("🎬 [T7-SETUP] Cancelling previous streaming task", category: .stt)
            oldTask.cancel()
        }
        streamingTask = Task { [weak self] in
            guard let self = self, let session = self.streamingSession else { return }
            Logger.info("🎬 [T7] Started listening for transcription results", category: .stt)

            defer {
                let cancelled = Task.isCancelled
                Logger.info("🎬 [T7-DEFER] Result stream ending (cancelled: \(cancelled))", category: .stt)
                // Ensure cleanup if stream ends unexpectedly
                Task { [weak self] in
                    guard let self else { return }
                    // If still in processing state, something went wrong
                    if case .processing = self.recordingState.phase {
                        Logger.warning("Stream ended without final result, forcing state reset", category: .stt)
                        await MainActor.run {
                            self.recordingState.transition(to: .completed(self.accumulatedText), caller: "defer-block")
                        }
                    }
                    await self.cleanupStreaming()
                }
            }

            for await result in session.receiveResults() {
                guard !Task.isCancelled else { break }

                switch result {
                case .partial(let text):
                    Logger.info("🎬 [T8] Partial result: \"\(text)\"", category: .stt)
                    // Update accumulated text for partial results and show in UI
                    // Note: Stay in .recording state while user is still holding the key
                    // Transition to .processing happens on keyUp or silence timeout
                    await MainActor.run {
                        self.accumulatedText = text
                    }

                case .final(let text):
                    Logger.info("🎬 [T9] Final result received: \"\(text)\" (isEmpty: \(text.isEmpty))", category: .stt)
                    await MainActor.run {
                        self.accumulatedText = text
                        // Transition to completed state (use accumulated text if final is empty)
                        let resultText = text.isEmpty ? self.accumulatedText : text
                        Logger.info("🎬 [T9-COMPLETING] Transitioning to completed with: \"\(resultText)\"", category: .stt)
                        self.recordingState.transition(to: .completed(resultText), caller: "final-result")
                    }
                    await self.cleanupStreaming()
                    return

                case .error(let error):
                    Logger.error("🎬 [T9-ERROR] Streaming error: \(error)", category: .stt)
                    await MainActor.run {
                        self.recordingState.transition(to: .error(error.localizedDescription), caller: "stream-error")
                    }
                    await self.cleanupStreaming()
                    return
                }
            }

            Logger.info("🎬 [T7-END] Result stream ended (cancelled: \(Task.isCancelled))", category: .stt)
        }
    }

    /// Cleanup streaming resources
    private func cleanupStreaming() async {
        streamingTask?.cancel()
        streamingTask = nil
        recordingController.setStreamingHandler(nil)
        await streamingSession?.disconnect()
        streamingSession = nil
    }

    /// Minimum time to show processing UI (in seconds)
    private static let minProcessingDisplayTime: TimeInterval = 1.5

    /// Called when RecordingState enters .processing phase
    private func stopRecordingUI() {
        Logger.info("🎬 [T10] stopRecordingUI called", category: .app)

        // Check if we're in streaming mode
        if streamingSession != nil {
            Task {
                await finishStreamingRecording()
            }
            return
        }

        // File-based recording stop
        guard let audioURL = recordingController.stop() else {
            Logger.warning("No audio recorded", category: .audio)
            panelController.hide()
            recordingState.cancel()
            return
        }

        currentAudioFileURL = audioURL
        Logger.info("Stopped recording, showing processing", category: .app)
        let processingStartTime = Date()
        panelController.viewModel.showProcessing()
        Logger.debug("Processing UI should be visible now", category: .ui)

        Task {
            do {
                // Small delay to ensure processing UI is rendered
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms

                let text = await transcribeForEditWindow(audioURL: audioURL)

                // Ensure minimum display time for processing UI
                let elapsed = Date().timeIntervalSince(processingStartTime)
                let remaining = Self.minProcessingDisplayTime - elapsed
                if remaining > 0 {
                    Logger.debug("Waiting \(String(format: "%.2f", remaining))s for minimum processing display time", category: .ui)
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }

                await MainActor.run {
                    recordingState.transition(to: .completed(text), caller: "transcribe-success")
                }
            } catch {
                Logger.error("Error during transcription: \(error)", category: .app)
                await MainActor.run {
                    recordingState.transition(to: .completed("Transcription failed: \(error.localizedDescription)"), caller: "transcribe-failure")
                }
            }
        }
    }

    /// Finish streaming recording
    @MainActor
    private func finishStreamingRecording() async {
        Logger.info("🎬 [T11] finishStreamingRecording started", category: .app)

        // Stop recording first (sets isRecording = false but keeps accumulated data)
        _ = recordingController.stop()
        Logger.info("🎬 [T12] Audio recording stopped", category: .audio)

        // Flush any remaining accumulated audio data
        // This returns the data instead of calling the handler to ensure proper ordering
        let flushedData = recordingController.flushStreamingData()

        // Now clear streaming state (handler and accumulated data)
        recordingController.clearStreamingState()

        // Send any flushed data BEFORE sending finish-task
        // This ensures proper ordering: audio data first, then finish signal
        do {
            if let data = flushedData, !data.isEmpty {
                Logger.info("🎬 [T13] Sending flushed audio data: \(data.count) bytes...", category: .stt)
                try await streamingSession?.sendAudioChunk(data, isFinal: false)
                Logger.info("🎬 [T13b] Flushed data sent", category: .stt)
            }

            // Now send final chunk to indicate end of stream
            Logger.info("🎬 [T14] Sending final audio chunk (finish-task)...", category: .stt)
            try await streamingSession?.sendAudioChunk(Data(), isFinal: true)
            Logger.info("🎬 [T15] Final chunk sent, waiting for transcription...", category: .stt)
        } catch {
            Logger.error("Failed to send final chunk: \(error)", category: .stt)
            recordingState.transition(to: .error(error.localizedDescription), caller: "finish-streaming-error")
            await cleanupStreaming()
        }

        // Results will be handled by streamingTask listener
    }

    /// Called when RecordingState enters .completed phase
    /// Uses TranscriptionPresenter actor to ensure thread-safe, ordered presentation
    private func showTranscriptionResult(_ text: String) {
        Logger.info("🎬 [RESULT] showTranscriptionResult called with text: '\(text.prefix(50))...' (length: \(text.count))", category: .stt)

        // Hide panel immediately
        panelController.hide(immediately: true)
        Logger.debug("🎬 [RESULT] Panel hidden", category: .ui)

        // Reset state to idle so next shortcut works
        recordingState.transition(to: .idle, caller: "showTranscriptionResult")

        // Use Actor to ensure serial presentation of results
        Logger.debug("🎬 [RESULT] Calling TranscriptionPresenter.present", category: .ui)
        Task {
            await TranscriptionPresenter.shared.present(text) { [weak self] resultText in
                guard let self else {
                    Logger.error("🎬 [RESULT] Self was nil in presenter closure", category: .ui)
                    return
                }
                Logger.info("🎬 [RESULT] Presenting result to UI: '\(resultText.prefix(50))...'", category: .ui)
                await self.presentTranscriptionResult(resultText)
                await MainActor.run {
                    self.cleanupCurrentAudio()
                }
            }
        }
    }

    /// Presents the transcription result to the user.
    /// Must be called from MainActor since it accesses UI.
    @MainActor
    private func presentTranscriptionResult(_ text: String) async {
        Logger.info("🎬 [PRESENT] presentTranscriptionResult called, text length: \(text.count), isWindowVisible: \(editController.isWindowVisible)", category: .ui)
        // Check if Edit window is already open
        if editController.isWindowVisible {
            Logger.info("🎬 [PRESENT] Edit window visible, clearing and showing new result", category: .ui)
            editController.clear()
            editController.showWithText(text) { _ in }
            Logger.info("🎬 [PRESENT] Edit window updated with new text", category: .ui)
        } else {
            Logger.info("🎬 [PRESENT] Opening Edit window", category: .ui)
            editController.showWithText(text) { _ in }
            Logger.info("🎬 [PRESENT] Edit window shown, isWindowVisible now: \(editController.isWindowVisible)", category: .ui)
        }
    }

    /// Called when RecordingState enters .error phase
    private func showError(_ message: String) {
        Logger.error("Recording error: \(message)", category: .app)
        // Ensure panel is hidden immediately
        panelController.hide(immediately: true)
        // Reset state to idle so next shortcut works
        recordingState.transition(to: .idle, caller: "showError")
        // Clean up any remaining audio file
        cleanupCurrentAudio()
        // Could show an alert here
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> (String?, String?) {
        guard let params = providerStore.resolveSTT(assignment) else {
            Logger.error("Could not resolve STT provider for assignment", category: .stt)
            return (nil, "Could not resolve provider. Check API key.")
        }

        // Double-check file exists before transcription
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Logger.error("Audio file missing before transcription: \(audioURL.path)", category: .audio)
            return (nil, "Recording file not found.")
        }

        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )

        do {
            Logger.info("Starting transcription with \(params.model)", category: .stt)
            let text = try await service.transcribe(audioFileURL: audioURL)
            Logger.info("Transcription completed successfully", category: .stt)
            return (text, nil)
        } catch {
            Logger.error("[\(params.model)] \(error.localizedDescription) | endpoint=\(params.endpoint)", category: .stt)
            return (nil, error.localizedDescription)
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
        // Don't clean up audio here - let the normal flow handle it
        // to prevent file deletion during transcription
        recordingState.cancel()
        panelController.hide(immediately: true)
    }

    private func transcribeForEditWindow(audioURL: URL) async -> String {
        // Verify audio file exists before attempting transcription
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            Logger.error("Audio file does not exist at path: \(audioURL.path)", category: .audio)
            return "Error: Recording file not found. Please try again."
        }

        let feature = providerStore.loadFeatureConfig()
        guard let sttAssignment = feature.sttPrimary else {
            return "Error: No STT model configured. Open Settings."
        }

        let (primaryText, primaryError) = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL)
        if let primaryText { return primaryText }

        // Try fallback if primary fails
        if let fallback = feature.sttFallback {
            // Check file still exists before fallback
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                Logger.error("Audio file deleted during transcription", category: .audio)
                return "Error: Recording was cancelled."
            }
            let (fallbackText, fallbackError) = await tryTranscribe(assignment: fallback, audioURL: audioURL)
            if let fallbackText { return fallbackText }
            return fallbackError ?? "Fallback transcription failed."
        }

        return primaryError ?? "Transcription failed. Check Settings."
    }

    private func cleanupCurrentAudio() {
        if let url = currentAudioFileURL {
            RecordingController.deleteRecording(at: url)
            currentAudioFileURL = nil
        }
    }
}
