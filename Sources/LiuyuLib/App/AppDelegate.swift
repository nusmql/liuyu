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
    private var recordingStartTime: Date?
    private var currentAudioFileURL: URL?
    private var accessibilityPollTimer: Timer?
    private var isRecording = false
    private var recordingFailsafeTimer: Timer?

    private let providerStore = ProviderConfigStore()
    private let minimumRecordingDuration: TimeInterval = 0.3
    /// Silence timeout: auto-stop when no audio activity for this duration (seconds)
    private var silenceTimeout: TimeInterval {
        let saved = UserDefaults.standard.integer(forKey: "silenceTimeout")
        // Default 5 seconds, 0 means disabled
        return saved > 0 ? TimeInterval(saved) : 5.0
    }

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
        hotkeyManager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                Logger.debug("Hotkey event received: \(event), shortcut: \(self.hotkeyManager.shortcut.displayString)", category: .hotkey)
                // ALL shortcuts use hold-to-record behavior
                switch event {
                case .keyDown:
                    self.handleKeyDown()
                case .keyUp:
                    self.handleKeyUp()
                }
            }
            .store(in: &cancellables)
    }

    private func setupHotkeyRefresh() {
        NotificationCenter.default
            .publisher(for: .hotkeyShortcutChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let shortcut = notification.object as? RecordedShortcut {
                    self?.hotkeyManager.shortcut = shortcut
                } else {
                    // nil means disable hotkey (during recording)
                    self?.hotkeyManager.stop()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidBegin)
            .sink { [weak self] _ in
                // For Carbon-based hotkeys, we need to stop during recording to prevent re-triggering
                // For EventTap-based hotkeys (modifier-only or Fn+key), we must keep it running
                // to capture the keyUp event that stops recording
                guard let self else { return }
                if !self.hotkeyManager.isUsingEventTap {
                    self.hotkeyManager.stop()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidEnd)
            .sink { [weak self] _ in
                guard let self else { return }
                // Only restart if we stopped it (Carbon-based shortcuts)
                if !self.hotkeyManager.isUsingEventTap {
                    try? self.hotkeyManager.start()
                }
            }
            .store(in: &cancellables)

        // Detect app deactivation during recording (user clicked elsewhere)
        NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                Logger.info("App lost focus during recording - auto-stopping", category: .app)
                self.handleKeyUp()
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording Flow

    private func handleKeyDown() {
        Logger.debug("handleKeyDown called, isRecording: \(isRecording)", category: .app)
        // Prevent duplicate triggers
        guard !isRecording else {
            Logger.debug("Already recording, ignoring", category: .app)
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication

        panelController.viewModel.showRecording()
        panelController.show()
        Logger.debug("Panel shown for recording", category: .ui)

        do {
            try recordingController.start()
            recordingStartTime = Date()
            isRecording = true
            // Set flag in hotkeyManager for EventTap-based shortcuts
            hotkeyManager.isRecording = true
            // Setup silence detection timer
            let timeout = silenceTimeout
            if timeout > 0 {
                recordingFailsafeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self else {
                            return
                        }
                        guard self.isRecording else {
                            self.recordingFailsafeTimer?.invalidate()
                            self.recordingFailsafeTimer = nil
                            return
                        }
                        // Check if no audio activity for the configured timeout period
                        if !self.recordingController.hasRecentAudioActivity {
                            // Get time since last activity
                            if let lastActivity = self.recordingController.lastAudioActivityTime {
                                let silenceDuration = Date().timeIntervalSince(lastActivity)
                                // print("[AppDelegate] Silence check: \(String(format: "%.1f", silenceDuration))s / \(timeout)s") // Debug logging
                                if silenceDuration >= timeout {
                                    Logger.info("Silence timeout: no audio for \(Int(silenceDuration))s, auto-stopping", category: .audio)
                                    self.handleKeyUp()
                                }
                            }
                        } else {
                            // print("[AppDelegate] Recent audio activity detected, resetting silence timer") // Debug logging
                        }
                    }
                }
            }
        } catch {
            panelController.hide()
            isRecording = false
            hotkeyManager.isRecording = false
            // Restart hotkey on error
            try? hotkeyManager.start()
            return
        }

        recordingController.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.panelController.viewModel.updateAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    private func handleKeyUp() {
        Logger.debug("handleKeyUp called", category: .app)
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())
        Logger.debug("Recording elapsed: \(elapsed)s", category: .audio)

        // Always reset state and invalidate failsafe timer
        recordingFailsafeTimer?.invalidate()
        recordingFailsafeTimer = nil

        if elapsed < minimumRecordingDuration {
            Logger.info("Recording too short, canceling", category: .audio)
            panelController.hide()
            isRecording = false
            hotkeyManager.isRecording = false
            cleanupCurrentAudio()
            // Restart hotkey after short recording
            try? hotkeyManager.start()
            return
        }
        stopRecordingAndTranscribe()
    }

    private func stopRecordingAndTranscribe() {
        Logger.debug("stopRecordingAndTranscribe called, isRecording: \(isRecording)", category: .app)
        guard isRecording else {
            Logger.debug("Not recording, returning", category: .app)
            return
        }
        isRecording = false
        hotkeyManager.isRecording = false

        // Invalidate the failsafe timer
        recordingFailsafeTimer?.invalidate()
        recordingFailsafeTimer = nil

        guard let audioURL = recordingController.stop() else {
            Logger.warning("No audio recorded, hiding panel", category: .audio)
            panelController.hide()
            // Restart hotkey on error
            try? hotkeyManager.start()
            return
        }

        currentAudioFileURL = audioURL
        Logger.info("Stopped recording, showing processing", category: .app)
        panelController.viewModel.showProcessing()

        Task {
            let text = await transcribeForEditWindow(audioURL: audioURL)
            Logger.info("Transcription complete: \(text.prefix(50))...", category: .stt)
            await MainActor.run {
                // Hide panel immediately
                Logger.debug("Hiding panel", category: .ui)
                panelController.hide(immediately: true)
                // Restart hotkey after transcription
                try? self.hotkeyManager.start()

                // Check if Edit window is already open with text - if so, treat as modification instruction
                if self.editController.isWindowVisible && self.editController.hasText {
                    Logger.info("Edit window visible with text, applying instruction", category: .ui)
                    self.editController.applyInstruction(text)
                    self.cleanupCurrentAudio()
                } else {
                    // Open Edit window on next runloop to avoid layout conflicts
                    Logger.debug("Scheduling Edit window open", category: .ui)
                    DispatchQueue.main.async {
                        Logger.info("Opening Edit window", category: .ui)
                        self.editController.showWithText(text) { [weak self] _ in
                            self?.cleanupCurrentAudio()
                        }
                    }
                }
            }
        }
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> (String?, String?) {
        guard let params = providerStore.resolveSTT(assignment) else {
            return (nil, "Could not resolve provider. Check API key.")
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
            let text = try await service.transcribe(audioFileURL: audioURL)
            return (text, nil)
        } catch {
            let detail = "[\(params.model)] \(error.localizedDescription)"
            Logger.error("\(detail) | endpoint=\(params.endpoint)", category: .stt)
            return (nil, detail)
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
        cleanupCurrentAudio()
        isRecording = false
    }

    private func transcribeForEditWindow(audioURL: URL) async -> String {
        let feature = providerStore.loadFeatureConfig()
        guard let sttAssignment = feature.sttPrimary else {
            return "Error: No STT model configured. Open Settings."
        }
        let (primaryText, primaryError) = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL)
        if let primaryText { return primaryText }
        if let fallback = feature.sttFallback {
            let (fallbackText, _) = await tryTranscribe(assignment: fallback, audioURL: audioURL)
            if let fallbackText { return fallbackText }
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
