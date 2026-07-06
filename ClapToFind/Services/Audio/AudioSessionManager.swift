// ClapToFind — AudioSessionManager.swift
// Owns the AVAudioSession lifecycle exclusively.
// All session mutations happen on this class; nothing else touches AVAudioSession.

import AVFoundation

// MARK: – Protocol

/// Abstracts AVAudioSession so the engine and tests can inject a mock.
///
/// Interruption and route-change callbacks are declared on the protocol so
/// consumers (MainViewModel) never need to downcast to the concrete type —
/// that downcast would break dependency injection.
protocol AudioSessionManaging: AnyObject {
    /// Configure the session for simultaneous capture + speaker playback.
    /// Using .playAndRecord from the very start ensures the engine's output
    /// node always has a valid resolved format for the alarm synthesiser.
    func configureForListening() throws

    /// Transition the session to default (non-measurement) mode for alarm playback.
    /// The category stays .playAndRecord; only the mode changes.
    func configureForAlarm() throws

    /// Deactivate the session when the app no longer needs audio.
    func deactivate() throws

    /// Called on the main thread when an audio interruption begins or ends.
    var onInterruption: ((AVAudioSession.InterruptionType) -> Void)? { get set }

    /// Called on the main thread when the audio route changes.
    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)? { get set }
}

// MARK: – Concrete implementation

final class AudioSessionManager: AudioSessionManaging {

    private let session = AVAudioSession.sharedInstance()

    // Retained so notifications survive for the lifetime of the manager.
    private var interruptionObserver: Any?
    private var routeChangeObserver: Any?

    var onInterruption: ((AVAudioSession.InterruptionType) -> Void)?
    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?

    init() {
        subscribeToNotifications()
    }

    deinit {
        if let obs = interruptionObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = routeChangeObserver  { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: – AudioSessionManaging

    func configureForListening() throws {
        // .playAndRecord from the very start so the engine's output node always
        // has a valid, resolved format. This prevents the
        // IsFormatSampleRateAndChannelCountValid crash that occurs when the alarm
        // synthesiser connects to an output node that was never configured for playback.
        // .defaultToSpeaker also overrides the silent switch for alarm audio.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: [])
    }

    func configureForAlarm() throws {
        // The session is already .playAndRecord + .defaultToSpeaker from
        // configureForListening(). That configuration:
        //   • Routes output to the loudspeaker (overrides the silent switch)
        //   • Keeps the mic tap alive for continued listening
        //   • Works correctly in .measurement mode for both capture and playback
        //
        // Changing mode from .measurement → .default while the engine is running
        // causes AVAudioEngine to restart its IO context
        // ("Abandoning I/O cycle because reconfig pending"), which destroys the
        // render window during which we're connecting the AVAudioSourceNode —
        // the node connects but never renders, producing silence.
        //
        // Solution: keep exactly the same session configuration.
        // No-op here is intentional and correct.
    }

    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: – Notification subscription

    private func subscribeToNotifications() {
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        onInterruption?(type)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        onRouteChange?(reason)
    }
}
