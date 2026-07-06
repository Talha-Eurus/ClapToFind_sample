// ClapToFind — MainViewModel.swift
// The single ViewModel for the app. Coordinates all services and exposes only
// what the View needs. All published state mutations happen on the MainActor.
//
// Dependency graph:
//   MainViewModel
//     ├── AudioSessionManager   (owns AVAudioSession)
//     ├── AudioEngineService    (owns AVAudioEngine + tap)
//     ├── ClapDetector          (pure DSP, called on audio thread)
//     └── AlarmService          (synthesises alarm tone, shares engine)

import AVFoundation
import Observation

@Observable
@MainActor
final class MainViewModel {

    // MARK: – Exposed state (View reads these)

    /// The current top-level application state.
    private(set) var appState: AppState = .idle

    /// Microphone authorisation as known to the app.
    private(set) var microphonePermission: MicrophonePermission = .undetermined

    /// Human-readable status message for display.
    private(set) var statusMessage: String = "Tap 'Start' to begin listening."

    /// Normalised sensitivity in [0, 1]. 0 = hardest to trigger, 1 = easiest.
    var sensitivity: Double = 0.5 {
        didSet { onSensitivityChanged() }
    }

    /// Whether the alarm is currently sounding.
    /// Stored rather than computed so @Observable correctly tracks changes.
    private(set) var isAlarmActive: Bool = false

    // MARK: – Dependencies

    private let sessionManager: AudioSessionManaging
    private let engineService: AudioEngineServicing
    private let detector: ClapDetecting
    private let alarmService: AlarmServicing

    // MARK: – Init (dependency injection)

    init(
        sessionManager: AudioSessionManaging,
        engineService: AudioEngineServicing,
        detector: ClapDetecting,
        alarmService: AlarmServicing
    ) {
        self.sessionManager = sessionManager
        self.engineService = engineService
        self.detector = detector
        self.alarmService = alarmService
        configureSessionCallbacks()
        refreshPermissionState()
    }

    // MARK: – Public interface

    func startListening() {
        guard microphonePermission == .granted else {
            requestMicrophonePermission()
            return
        }
        guard appState == .idle else { return }

        do {
            try sessionManager.configureForListening()

            // Pre-attach the alarm node graph BEFORE starting the engine.
            //
            // If we attach nodes to a RUNNING engine, AVAudioEngine restarts its
            // IO context ("Abandoning I/O cycle — reconfig pending"). The new node
            // connects during the restart window and produces silence. Pre-attaching
            // here means the graph topology is fully resolved when engine.start()
            // is called, and startAlarm() later only changes a mixer volume
            // parameter — zero reconfig, guaranteed output.
            let outputRate = AVAudioSession.sharedInstance().sampleRate
            alarmService.attachGraph(outputSampleRate: outputRate)

            let capturedDetector = detector  // Capture on MainActor before escaping
            try engineService.start { buffer in
                // Realtime audio thread — access capturedDetector directly,
                // not through MainViewModel's @MainActor isolation.
                let result = capturedDetector.process(buffer: buffer)
                if result.wasDetected {
                    Task { @MainActor [weak self] in
                        self?.handleClapDetected()
                    }
                }
            }
            appState = .listening
            statusMessage = "Listening… Clap your hands!"
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }


    func stopListening() {
        guard appState == .listening || appState == .alarming else { return }
        stopAlarm()
        engineService.stop()
        try? sessionManager.deactivate()
        detector.reset()
        appState = .idle
        statusMessage = "Stopped. Tap 'Start' to listen again."
    }

    func stopAlarm() {
        guard isAlarmActive else { return }
        alarmService.stopAlarm()
        isAlarmActive = false
        if appState == .alarming {
            appState = .listening
            statusMessage = "Alarm stopped. Still listening…"
        }
    }

    func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.microphonePermission = granted ? .granted : .denied
                if granted {
                    self?.statusMessage = "Permission granted. Tap 'Start' to begin."
                } else {
                    self?.statusMessage = "Microphone access denied. Enable in Settings."
                }
            }
        }
    }

#if DEBUG
    /// Directly triggers clap detection without requiring real microphone input.
    /// Available in Debug builds only — used for simulator testing and development.
    /// Compile-time excluded from Release via #if DEBUG.
    func simulateClap() {
        guard appState == .listening else { return }
        handleClapDetected()
    }
#endif

    // MARK: – Private

    private func handleClapDetected() {
        guard appState == .listening else { return }
        appState = .alarming
        statusMessage = "Clap detected! 👏 Tap 'Stop Alarm' to silence."
        triggerAlarm()
    }

    private func triggerAlarm() {
        do {
            try sessionManager.configureForAlarm()
            try alarmService.startAlarm()
            isAlarmActive = true
        } catch {
            statusMessage = "Alarm error: \(error.localizedDescription)"
        }
    }

    private func onSensitivityChanged() {
        let config = DetectionConfiguration.make(sensitivity: sensitivity)
        detector.updateConfiguration(config)
    }

    private func refreshPermissionState() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphonePermission = .granted
        case .denied:
            microphonePermission = .denied
        case .undetermined:
            microphonePermission = .undetermined
        @unknown default:
            microphonePermission = .undetermined
        }
    }

    private func configureSessionCallbacks() {
        // Callbacks are declared on the AudioSessionManaging protocol itself —
        // no downcast to AudioSessionManager required. This preserves full
        // dependency-injection substitutability.
        sessionManager.onInterruption = { [weak self] type in
            Task { @MainActor [weak self] in
                self?.handleInterruption(type)
            }
        }

        sessionManager.onRouteChange = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason)
            }
        }
    }


    private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
        switch type {
        case .began:
            // Phone call started, Siri activated, etc.
            if appState == .listening || appState == .alarming {
                engineService.stop()
                alarmService.stopAlarm()
                isAlarmActive = false
                appState = .idle
                statusMessage = "Interrupted. Tap 'Start' to resume."
            }
        case .ended:
            // Interruption ended — do not auto-resume; let the user decide.
            statusMessage = "Interruption ended. Tap 'Start' to resume."
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones unplugged — audio would have moved to speaker automatically.
            // No action required; AVAudioEngine handles route changes gracefully.
            break
        case .newDeviceAvailable:
            break
        default:
            break
        }
    }
}
