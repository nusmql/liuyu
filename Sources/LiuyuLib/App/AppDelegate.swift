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

    private var cancellables = Set<AnyCancellable>()
    nonisolated(unsafe) private var previousApp: NSRunningApplication?
    private var recordingStartTime: Date?
    private var currentAudioFileURL: URL?
    private var accessibilityPollTimer: Timer?

    private let providerStore = ProviderConfigStore()
    private let minimumRecordingDuration: TimeInterval = 0.3

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        providerStore.migrateIfNeeded()
        RecordingController.cleanupOrphanedFiles()
        setupStatusItem()
        panelController.setup()
        setupHotkeySubscription()
        setupPanelActions()
        applyHotkeyPreset()
        startHotkeyManager()

        // Centralize activation policy: only go accessory when ALL windows are closed
        let updatePolicy: () -> Void = { [weak self] in
            self?.updateActivationPolicy()
        }
        settingsController.onWindowClose = updatePolicy
        editController.onWindowClose = updatePolicy

        // First launch: open settings if no active model configured
        if providerStore.loadFeatureConfig().sttPrimary == nil {
            settingsController.show()
        }
    }

    private func updateActivationPolicy() {
        if !settingsController.isWindowVisible && !editController.isWindowVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Liuyu")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit...", action: #selector(openEdit), keyEquivalent: "e"))
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

    private func applyHotkeyPreset() {
        let presetRaw = UserDefaults.standard.string(forKey: "hotkeyPreset") ?? HotkeyPreset.rightOption.rawValue
        hotkeyManager.preset = HotkeyPreset.from(rawValue: presetRaw)
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
                switch event {
                case .keyDown:
                    self.handleKeyDown()
                case .keyUp:
                    self.handleKeyUp()
                }
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
        } catch {
            panelController.viewModel.showResult("Error: \(error.localizedDescription)")
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
        let feature = providerStore.loadFeatureConfig()

        guard let sttAssignment = feature.sttPrimary else {
            panelController.viewModel.showResult("No STT model configured. Open Settings.")
            panelController.resize(width: 400, height: 120)
            settingsController.show()
            return
        }

        // Try primary, then fallback
        if let text = await tryTranscribe(assignment: sttAssignment, audioURL: audioURL) {
            panelController.viewModel.showResult(text)
            panelController.resize(width: 400, height: 120)
            return
        }

        if let fallback = feature.sttFallback,
           let text = await tryTranscribe(assignment: fallback, audioURL: audioURL) {
            panelController.viewModel.showResult(text)
            panelController.resize(width: 400, height: 120)
            return
        }

        panelController.viewModel.showResult("Transcription failed. Check Settings.")
        panelController.resize(width: 400, height: 120)
    }

    private func tryTranscribe(assignment: ModelAssignment, audioURL: URL) async -> String? {
        guard let params = providerStore.resolveSTT(assignment) else { return nil }

        let language = UserDefaults.standard.string(forKey: "language") ?? "auto"
        let service = TranscriptionService(
            apiKey: params.apiKey,
            endpoint: params.endpoint,
            model: params.model,
            language: language == "auto" ? nil : language,
            apiFormat: params.apiFormat
        )

        return try? await service.transcribe(audioFileURL: audioURL)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.simulatePaste()
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
