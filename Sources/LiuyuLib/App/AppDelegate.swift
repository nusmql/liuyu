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

    /// Recording state manager
    private let recordingState = RecordingState.shared

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm up icons early to prevent concurrent access crashes
        IconManager.shared.warmup()
        
        AppTheme.applyFromDefaults()
        providerStore.migrateIfNeeded()
        RecordingController.cleanupOrphanedFiles()
        setupMainMenu()
        setupStatusItem()
        panelController.setup()
        setupHotkeySubscription()
        setupPanelActions()
        applyHotkeyShortcut()
        setupHotkeyRefresh()
        startHotkeyManager()

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
            // Just waiting, no UI yet
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

    // MARK: - Recording Flow (using RecordingState)

    /// Called when RecordingState enters .recording phase
    private func startRecordingUI() {
        Logger.debug("Starting recording UI", category: .app)
        previousApp = NSWorkspace.shared.frontmostApplication

        panelController.viewModel.showRecording()
        panelController.show()
        Logger.debug("Panel shown for recording", category: .ui)

        do {
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

    /// Minimum time to show processing UI (in seconds)
    private static let minProcessingDisplayTime: TimeInterval = 1.5

    /// Called when RecordingState enters .processing phase
    private func stopRecordingUI() {
        Logger.debug("Stopping recording UI", category: .app)

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
                    recordingState.transition(to: .completed(text))
                }
            } catch {
                Logger.error("Error during transcription: \(error)", category: .app)
                await MainActor.run {
                    recordingState.transition(to: .completed("Transcription failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Called when RecordingState enters .completed phase
    /// Uses TranscriptionPresenter actor to ensure thread-safe, ordered presentation
    private func showTranscriptionResult(_ text: String) {
        Logger.info("Showing transcription result", category: .stt)

        // Hide panel immediately
        panelController.hide(immediately: true)

        // Reset state to idle so next shortcut works
        recordingState.transition(to: .idle)

        // Use Actor to ensure serial presentation of results
        Task {
            await TranscriptionPresenter.shared.present(text) { [weak self] resultText in
                guard let self else { return }
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
        // Check if Edit window is already open
        if editController.isWindowVisible {
            Logger.info("Edit window visible, clearing and showing new result", category: .ui)
            editController.clear()
            editController.showWithText(text) { _ in }
        } else {
            Logger.info("Opening Edit window", category: .ui)
            editController.showWithText(text) { _ in }
        }
    }

    /// Called when RecordingState enters .error phase
    private func showError(_ message: String) {
        Logger.error("Recording error: \(message)", category: .app)
        // Ensure panel is hidden immediately
        panelController.hide(immediately: true)
        // Reset state to idle so next shortcut works
        recordingState.transition(to: .idle)
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
