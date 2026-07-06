// ClapToFind — AudioEngineService.swift
// Wraps AVAudioEngine, installs a buffer tap on the input node, and forwards
// raw PCM buffers to the clap detector via a callback closure.
//
// Design decisions:
//  – The engine is the sole owner of the tap; no other code installs taps.
//  – Buffer callbacks arrive on a realtime audio thread; all heavy lifting
//    is delegated to ClapDetector which is designed to be called from that thread.
//  – No audio is written to disk.
//  – Tap lifecycle is tracked with isTapInstalled because AVAudioEngine throws
//    a fatal exception if installTap is called when a tap is already present.

import AVFoundation

// MARK: – Protocol

protocol AudioEngineServicing: AnyObject {
    /// Start the engine and begin delivering buffers to `onBuffer`.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// Stop the engine and remove the tap.
    func stop()
}

// MARK: – Errors

enum AudioEngineError: Error, LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "Could not construct a valid capture format. Ensure AVAudioSession is active before starting the engine."
    }
}

// MARK: – Concrete implementation

final class AudioEngineService: AudioEngineServicing {

    private let engine: AVAudioEngine

    /// Tracks whether a tap is currently installed on the input node.
    /// AVAudioEngine throws a fatal exception if installTap is called while a tap
    /// is already present — this flag prevents that regardless of engine run state.
    private var isTapInstalled: Bool = false

    /// - Parameter engine: The shared `AVAudioEngine` instance. Pass the same
    ///   engine used by `AlarmService` so mic capture and alarm playback
    ///   coexist on the same audio graph without conflicts.
    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    // MARK: – AudioEngineServicing

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // Defensively remove any stale tap before installing a new one.
        // Double-install crashes with: "required condition is false: nullptr == Tap()"
        removeTapIfInstalled()

        let inputNode = engine.inputNode

        // CRITICAL: The tap format MUST match the hardware INPUT sample rate exactly.
        //
        // AVAudioSession.sampleRate is the OUTPUT device rate — on simulator (and some
        // devices) the input (mic) and output (speaker) operate at different rates.
        // This mismatch caused: "Failed to create tap due to format mismatch,
        //   input hw 88200 Hz vs client format 48000 Hz"
        //
        // The correct source of truth for the input rate is inputNode.outputFormat(forBus:0).
        // This is safe to query AFTER AVAudioSession.setActive(true) has been called,
        // which configureForListening() guarantees before this method is invoked.
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            // Session was not activated before start() was called.
            throw AudioEngineError.invalidFormat
        }

        // Request mono at the hardware's native rate.
        // If the mic is already mono, use its format directly to avoid any conversion.
        // If stereo, build a mono format at the same rate — AVAudioEngine performs
        // the channel-count conversion internally with no quality loss.
        let tapFormat: AVAudioFormat = {
            if hwFormat.channelCount == 1 {
                return hwFormat
            }
            return AVAudioFormat(
                standardFormatWithSampleRate: hwFormat.sampleRate,
                channels: 1
            ) ?? hwFormat
        }()

        // Buffer size in frames. At 88200 Hz (simulator) this is ~46 ms;
        // at 44100 Hz (most devices) this is ~93 ms. Both are well within
        // the <150 ms perceptual threshold for clap detection.
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { buffer, _ in
            // Realtime audio thread — forward immediately, no locking.
            onBuffer(buffer)
        }
        isTapInstalled = true

        engine.prepare()
        try engine.start()
    }


    func stop() {
        // Remove the tap UNCONDITIONALLY — do NOT gate on engine.isRunning.
        //
        // The tap is an independent object from the engine's run state. When the
        // engine stops (e.g., due to a session interruption or category change),
        // the tap is NOT automatically removed. If we skip removal here and the
        // caller later calls start() again, installTap crashes with:
        //   "required condition is false: nullptr == Tap()"
        removeTapIfInstalled()

        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: – Private

    private func removeTapIfInstalled() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }
}
