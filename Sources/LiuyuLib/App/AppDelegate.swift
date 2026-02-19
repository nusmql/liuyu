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

    private let providerStore = ProviderConfigStore()
    private let minimumRecordingDuration: TimeInterval = 0.3

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
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
        editController.onWindowClose = updatePolicy
        onboardingController.onWindowClose = updatePolicy

        // First launch: show onboarding wizard
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            onboardingController.onComplete = { [weak self] in
                self?.updateActivationPolicy()
            }
            onboardingController.show()
        }
    }

    private func updateActivationPolicy() {
        if !settingsController.isWindowVisible && !editController.isWindowVisible && !onboardingController.isWindowVisible {
            NSApp.setActivationPolicy(.accessory)
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
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Liuyu")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open...", action: #selector(openEdit), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Liuyu", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
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

    private func migrateHotkeySettingsIfNeeded() {
        guard UserDefaults.standard.object(forKey: "hotkeyPreset") != nil,
              UserDefaults.standard.object(forKey: "recordedShortcut") == nil else {
            return
        }

        let presetRaw = UserDefaults.standard.string(forKey: "hotkeyPreset") ?? "Right Option"
        let preset = HotkeyPreset.from(rawValue: presetRaw)

        let shortcut = RecordedShortcut.from(preset: preset)
        shortcut.saveToDefaults()
        UserDefaults.standard.removeObject(forKey: "hotkeyPreset")
        print("[Liuyu] Migrated hotkey preset to new shortcut format")
    }

    private func applyHotkeyShortcut() {
        migrateHotkeySettingsIfNeeded()
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
        hotkeyManager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                if self.hotkeyManager.shortcut.isModifierOnly {
                    // Modifier-only: hold to record, release to stop
                    switch event {
                    case .keyDown:
                        self.handleKeyDown()
                    case .keyUp:
                        self.handleKeyUp()
                    }
                } else {
                    // Key combination: toggle mode
                    switch event {
                    case .keyDown:
                        self.handleToggle()
                    case .keyUp:
                        break // Ignore keyUp for toggle mode
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func setupHotkeyRefresh() {
        NotificationCenter.default
            .publisher(for: .hotkeyShortcutChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let shortcut = notification.object as? RecordedShortcut else { return }
                self?.hotkeyManager.shortcut = shortcut
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidBegin)
            .sink { [weak self] _ in
                self?.hotkeyManager.stop()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .hotkeyRecordingDidEnd)
            .sink { [weak self] _ in
                try? self?.hotkeyManager.start()
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording Flow

    private func handleKeyDown() {
        previousApp = NSWorkspace.shared.frontmostApplication

        panelController.viewModel.showRecording()
        panelController.show()

        do {
            try recordingController.start()
            recordingStartTime = Date()
            isRecording = true
        } catch {
            panelController.viewModel.showResult("Error: \(error.localizedDescription)")
            isRecording = false
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
        let elapsed = Date().timeIntervalSince(recordingStartTime ?? Date())

        if elapsed < minimumRecordingDuration {
            let remaining = minimumRecordingDuration - elapsed
            Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                await MainActor.run {
                    self.stopRecordingAndTranscribe()
                }
            }
        } else {
            stopRecordingAndTranscribe()
        }
    }

    private func handleToggle() {
        if isRecording {
            // Stop recording
            handleKeyUp()
        } else {
            // Start recording
            handleKeyDown()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false

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
        let feature = providerStore.loadFeatureConfig()

        guard let sttAssignment = feature.sttPrimary else {
            panelController.viewModel.showResult("No STT model configured. Open Settings.")
            panelController.resize(width: 400, height: 120)
            settingsController.show()
            return
        }

        // Try primary, then fallback
        let (primaryText, primaryError) = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL)
        if let primaryText {
            panelController.viewModel.showResult(primaryText)
            panelController.resize(width: 400, height: 120)
            return
        }

        if let fallback = feature.sttFallback {
            let (fallbackText, _) = await tryTranscribe(assignment: fallback, audioURL: audioURL)
            if let fallbackText {
                panelController.viewModel.showResult(fallbackText)
                panelController.resize(width: 400, height: 120)
                return
            }
        }

        panelController.viewModel.showResult(primaryError ?? "Transcription failed. Check Settings.")
        panelController.resize(width: 400, height: 120)
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
            print("[Liuyu STT] \(detail) | endpoint=\(params.endpoint)")
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
        switch action {
        case .insert(let text):
            insertText(text)
            cleanupCurrentAudio()
        case .copy:
            break // Already copied in PanelViewModel
        case .clear, .cancel:
            cleanupCurrentAudio()
        }

        panelController.hide()
    }

    private func insertText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        previousApp?.activate()

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            self.simulatePaste()
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
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
