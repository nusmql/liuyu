// Sources/LiuyuLib/App/AppDelegate.swift
import AppKit
import Combine
import LiuyuVoice

enum RecordingPhaseEffect: Equatable {
    case none
    case startRecordingUI
    case stopRecordingUI
    case showTranscriptionResult(String)
    case showError(String)
    case cleanupVoiceSession
}

func recordingPhaseEffect(for phase: RecordingState.RecordingPhase) -> RecordingPhaseEffect {
    switch phase {
    case .debouncing:
        return .none
    case .recording:
        return .startRecordingUI
    case .processing:
        return .stopRecordingUI
    case .completed(let text):
        return .showTranscriptionResult(text)
    case .error(let message):
        return .showError(message)
    case .idle:
        return .cleanupVoiceSession
    }
}

enum EditWindowPreparation: Equatable {
    case none
    case clearEditWindow
}

func editWindowPreparationForNewGlobalRecording(isEditWindowVisible: Bool) -> EditWindowPreparation {
    isEditWindowVisible ? .clearEditWindow : .none
}

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    nonisolated(unsafe) private var hotkeyManager = HotkeyManager()
    private let panelController = FloatingPanelController()
    private let settingsController = SettingsWindowController()
    private let editController = EditWindowController()
    private let onboardingController = OnboardingWindowController()

    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var previousApp: NSRunningApplication?
    private var accessibilityPollTimer: Timer?

    private let providerStore = ProviderConfigStore()

    private var voiceCoordinator: VoiceSessionCoordinator?
    private var voiceEventTask: Task<Void, Never>?
    private var voiceStartTask: Task<Void, Never>?

    /// Recording state manager
    private let recordingState = RecordingState.shared

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Warm up icons early to prevent concurrent access crashes
        IconManager.shared.warmup()
        
        AppTheme.applyFromDefaults()
        providerStore.migrateIfNeeded()
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            providerStore.ensurePreferredDefaultLLMIfNeeded()
        }
        RecordingController.cleanupOrphanedFiles()

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
        hotkeyManager.configure(shortcut: RecordedShortcut.loadFromDefaults())
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

        switch recordingPhaseEffect(for: phase) {
        case .none:
            // Wait for the debounce timer before opening the audio source.
            break

        case .startRecordingUI:
            startRecordingUI()

        case .stopRecordingUI:
            stopRecordingUI()

        case .showTranscriptionResult(let text):
            showTranscriptionResult(text)

        case .showError(let message):
            showError(message)
            recordingState.cancel()

        case .cleanupVoiceSession:
            Task { await cleanupVoiceSession() }
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
                    self?.hotkeyManager.configure(shortcut: shortcut)
                } else {
                    Logger.debug("Shortcut changed to nil (stopping)", category: .hotkey)
                    // configure() owns hotkey lifecycle; an empty shortcut is invalid, so it stops any active monitor.
                    self?.hotkeyManager.configure(shortcut: RecordedShortcut(flags: [], keyCode: nil, includesFnKey: false))
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
                if self.wasHotkeyActiveBeforeRecording {
                    self.hotkeyManager.stop()
                }
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

    /// Listen for settings changes and cancel any active voice session before model replacement.
    private func setupSettingsChangeListener() {
        NotificationCenter.default
            .publisher(for: Notification.Name("sttModelChanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Logger.info("STT model changed, cancelling active voice session if needed", category: .settings)
                Task { await self?.cleanupVoiceSession() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording Flow (using RecordingState)

    /// Called when RecordingState enters .recording phase
    private func startRecordingUI() {
        Logger.info("🎬 [T0] startRecordingUI called", category: .app)
        previousApp = NSWorkspace.shared.frontmostApplication

        switch editWindowPreparationForNewGlobalRecording(isEditWindowVisible: editController.isWindowVisible) {
        case .clearEditWindow:
            Logger.info("[GLOBAL-VOICE] Clearing visible Edit window for new dictation session", category: .ui)
            editController.clear()
            Task {
                await TranscriptionPresenter.shared.cancelPending()
            }
        case .none:
            break
        }

        panelController.viewModel.showRecording()
        panelController.show()
        Logger.debug("Panel shown for recording", category: .ui)

        let feature = providerStore.loadFeatureConfig()
        guard let stt = feature.sttPrimary else {
            recordingState.transition(to: .error("No STT model configured. Open Settings."), caller: "startRecordingUI.noSTT")
            return
        }

        guard let params = providerStore.resolveSTT(stt) else {
            recordingState.transition(to: .error("Could not resolve STT provider. Check Settings."), caller: "startRecordingUI.resolveSTT")
            return
        }

        let language = selectedTranscriptionLanguage()
        let fallbackParams = feature.sttFallback.flatMap { providerStore.resolveSTT($0) }
        let provider = VoiceProviderFactory.makeProvider(
            params: params,
            fallback: fallbackParams,
            language: language
        )
        let source = MacMicrophoneAudioSource()
        let coordinator = VoiceSessionCoordinator(source: source, provider: provider)

        voiceEventTask?.cancel()
        voiceStartTask?.cancel()
        voiceCoordinator = coordinator

        voiceEventTask = Task { [weak self, coordinator] in
            for await event in coordinator.events() {
                await MainActor.run {
                    guard let self, self.isCurrentVoiceCoordinator(coordinator) else { return }
                    self.handleVoiceSessionEvent(event)
                }
            }
        }

        let providerConfig = TranscriptionProviderConfig(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language
        )
        Logger.info("🎬 Starting voice session for \(params.model) (\(provider.mode))", category: .app)

        voiceStartTask = Task { [weak self, coordinator, providerConfig] in
            do {
                try await coordinator.start(config: providerConfig)
                await MainActor.run {
                    guard let self, self.isCurrentVoiceCoordinator(coordinator) else { return }
                    self.voiceStartTask = nil
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self, self.isCurrentVoiceCoordinator(coordinator) else { return }
                    Logger.error("Failed to start voice session: \(error.localizedDescription)", category: .audio)
                    self.handleVoiceStartFailure(error)
                }
            }
        }
    }

    /// Called when RecordingState enters .processing phase
    private func stopRecordingUI() {
        Logger.info("🎬 [T10] stopRecordingUI called", category: .app)

        guard let coordinator = voiceCoordinator else {
            Logger.warning("No active voice coordinator to stop", category: .audio)
            panelController.hide()
            recordingState.cancel()
            return
        }

        panelController.viewModel.showProcessing()
        Logger.debug("Processing UI shown, stopping voice session", category: .ui)

        Task {
            await coordinator.stop(reason: .userReleased)
        }
    }

    private func selectedTranscriptionLanguage() -> String? {
        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        return language == "auto" ? nil : language
    }

    private func handleVoiceSessionEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .started:
            Logger.debug("Voice session started", category: .audio)
            panelController.viewModel.showRecording()

        case .audioLevel(let level, _):
            recordingState.updateAudioActivity(level: level)
            panelController.viewModel.updateAudioLevel(level)

        case .partial(let text, _):
            Logger.debug("Voice partial result: \"\(text)\"", category: .stt)

        case .final(let text, let metrics):
            clearFinishedVoiceSession()
            Logger.info("Voice final result received, bytes=\(metrics.sentByteCount), frames=\(metrics.sentFrameCount)", category: .stt)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                recordingState.transition(to: .error("No speech detected."), caller: "voice-final-empty")
            } else {
                recordingState.transition(to: .completed(text), caller: "voice-final")
            }

        case .failed(let message, let metrics):
            clearFinishedVoiceSession()
            Logger.error("Voice session failed after \(metrics.sentFrameCount) frames: \(message)", category: .stt)
            recordingState.transition(to: .error(message), caller: "voice-failed")

        case .cancelled:
            clearFinishedVoiceSession()
            Logger.debug("Voice session cancelled", category: .audio)
        }
    }

    private func handleVoiceStartFailure(_ error: Error) {
        Task { await cleanupVoiceSession() }
        panelController.hide()
        recordingState.transition(to: .error(error.localizedDescription), caller: "voice-start-failure")
    }

    private func isCurrentVoiceCoordinator(_ coordinator: VoiceSessionCoordinator) -> Bool {
        voiceCoordinator === coordinator
    }

    private func clearFinishedVoiceSession() {
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceEventTask = nil
        voiceCoordinator = nil
    }

    private func cleanupVoiceSession() async {
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceEventTask?.cancel()
        voiceEventTask = nil

        let coordinator = voiceCoordinator
        voiceCoordinator = nil
        await coordinator?.cancel()
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
        Task { await cleanupVoiceSession() }
        // Could show an alert here
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
        Task { await cleanupVoiceSession() }
        recordingState.cancel()
        panelController.hide(immediately: true)
    }
}
