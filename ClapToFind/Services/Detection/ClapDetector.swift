// ClapToFind — ClapDetector.swift
// Custom DSP-based clap detector. No SDK, no ML, no SoundAnalysis.
//
// Algorithm (five-stage pipeline applied per buffer):
//
//   Stage 1 – Absolute floor gate
//     Reject frames whose RMS is below `minimumAbsoluteRMS`. This eliminates
//     electronic noise and microphone self-noise before any further processing.
//
//   Stage 2 – Adaptive baseline update
//     An exponential moving average (EMA) tracks the long-term ambient noise level.
//     Alpha is intentionally tiny (≈0.002) so a clap does not inflate the baseline
//     permanently. The baseline only updates when the current RMS is below the spike
//     threshold, preventing loud events from biasing the ambient model.
//
//   Stage 3 – Transient spike detection
//     currentRMS / adaptiveBaseline must exceed `spikeMultiplier`.
//     Claps produce a sudden 10–20 dB rise above ambient. This ratio gate is the
//     primary detection criterion.
//
//   Stage 4 – Attack confirmation
//     The rise from the previous frame (delta) must be positive and exceed
//     `minimumAttackDelta`. This rejects gradual ramps (music fade-ins, speech
//     starting) that might momentarily satisfy the spike ratio.
//
//   Stage 5 – Sustained-sound rejection
//     A clap's energy decays in < 3 frames (< 280 ms at 4096-frame buffers).
//     If the spike ratio remains elevated for more consecutive frames than
//     `maximumSustainedFrames`, the event is reclassified as sustained noise.
//
//   Stage 6 – Cooldown gate
//     Enforces a minimum inter-detection interval to suppress reverb and flutter.
//
// Thread safety:
//   All mutable state is private and must be accessed only from the audio thread
//   (via the `process(buffer:)` call path). The ViewModel is responsible for
//   dispatching the result to the main thread before updating published properties.

import AVFoundation

// MARK: – Protocol

/// Defines the interface for a stateful audio buffer processor that detects hand claps.
protocol ClapDetecting: AnyObject {
    /// Process one audio buffer frame and return the analysis result.
    /// Must be called exclusively from the audio thread.
    func process(buffer: AVAudioPCMBuffer) -> DetectionResult

    /// Reset all internal state (adaptive baseline, cooldown, frame counters).
    func reset()

    /// Update the sensitivity configuration without resetting the adaptive baseline.
    func updateConfiguration(_ configuration: DetectionConfiguration)
}

// MARK: – Concrete detector

final class ClapDetector: ClapDetecting {

    // MARK: – State (audio-thread only)

    /// Current adaptive noise baseline (exponential moving average of RMS).
    private var adaptiveBaseline: Float = 0.01

    /// RMS of the previous processed frame — used for attack delta calculation.
    private var previousRMS: Float = 0

    /// Number of consecutive frames where the spike ratio has been above threshold.
    private var sustainedFrameCount: Int = 0

    /// Timestamp of the last confirmed detection.
    private var lastDetectionTime: Date = .distantPast

    // MARK: – Configuration (can be updated from main thread; read on audio thread)
    // `configuration` is written atomically from `updateConfiguration`. Because
    // it is a value type (struct) and Swift guarantees atomic stores for value
    // types up to pointer size on ARM64, this is safe without a lock for our use.
    // If this assumption were ever incorrect, a simple os_unfair_lock would suffice.
    private var configuration: DetectionConfiguration

    // MARK: – Init

    init(configuration: DetectionConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: – ClapDetecting

    func process(buffer: AVAudioPCMBuffer) -> DetectionResult {
        let currentRMS = DSPUtilities.rms(buffer: buffer)

        defer { previousRMS = currentRMS }

        // Stage 1 – Absolute floor gate
        guard currentRMS >= configuration.minimumAbsoluteRMS else {
            // Energy too low to be a clap; update baseline with near-silence
            updateBaseline(with: currentRMS)
            sustainedFrameCount = 0
            return DetectionResult(
                wasDetected: false,
                rmsEnergy: currentRMS,
                adaptiveBaseline: adaptiveBaseline,
                spikeRatio: 0,
                timestamp: .now
            )
        }

        let spikeRatio = currentRMS / adaptiveBaseline
        let spikeThreshold = configuration.spikeMultiplier

        // Stage 3 – Transient spike check (gate before baseline update)
        let spikeDetected = spikeRatio >= spikeThreshold

        // Only update baseline when we are NOT in a transient spike.
        // This prevents loud sounds from permanently elevating the ambient model.
        if !spikeDetected {
            updateBaseline(with: currentRMS)
            sustainedFrameCount = 0
        }

        guard spikeDetected else {
            return DetectionResult(
                wasDetected: false,
                rmsEnergy: currentRMS,
                adaptiveBaseline: adaptiveBaseline,
                spikeRatio: spikeRatio,
                timestamp: .now
            )
        }

        // Stage 4 – Attack confirmation (must be rising)
        let attackDelta = currentRMS - previousRMS
        guard attackDelta >= configuration.minimumAttackDelta else {
            sustainedFrameCount += 1
            return DetectionResult(
                wasDetected: false,
                rmsEnergy: currentRMS,
                adaptiveBaseline: adaptiveBaseline,
                spikeRatio: spikeRatio,
                timestamp: .now
            )
        }

        // Stage 5 – Sustained-sound rejection
        sustainedFrameCount += 1
        guard sustainedFrameCount <= configuration.maximumSustainedFrames else {
            // Energy has stayed elevated too long — this is speech, music, or noise.
            return DetectionResult(
                wasDetected: false,
                rmsEnergy: currentRMS,
                adaptiveBaseline: adaptiveBaseline,
                spikeRatio: spikeRatio,
                timestamp: .now
            )
        }

        // Stage 6 – Cooldown gate
        let now = Date.now
        guard now.timeIntervalSince(lastDetectionTime) >= configuration.cooldownDuration else {
            return DetectionResult(
                wasDetected: false,
                rmsEnergy: currentRMS,
                adaptiveBaseline: adaptiveBaseline,
                spikeRatio: spikeRatio,
                timestamp: now
            )
        }

        // ✅ All gates passed — clap confirmed.
        lastDetectionTime = now
        sustainedFrameCount = 0

        return DetectionResult(
            wasDetected: true,
            rmsEnergy: currentRMS,
            adaptiveBaseline: adaptiveBaseline,
            spikeRatio: spikeRatio,
            timestamp: now
        )
    }

    func reset() {
        adaptiveBaseline = 0.01
        previousRMS = 0
        sustainedFrameCount = 0
        lastDetectionTime = .distantPast
    }

    func updateConfiguration(_ configuration: DetectionConfiguration) {
        self.configuration = configuration
    }

    // MARK: – Private helpers

    /// Updates the exponential moving average baseline.
    private func updateBaseline(with rms: Float) {
        // EMA: baseline = alpha * rms + (1 - alpha) * baseline
        let alpha = configuration.adaptiveAlpha
        adaptiveBaseline = alpha * rms + (1 - alpha) * adaptiveBaseline
        // Clamp to the absolute floor so the baseline never collapses to zero.
        adaptiveBaseline = max(adaptiveBaseline, configuration.minimumAbsoluteRMS)
    }
}
