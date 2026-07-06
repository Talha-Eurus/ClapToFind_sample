// ClapToFind — DetectionConfiguration.swift
// All tunable DSP thresholds live here. Centralising them makes reasoning about
// the algorithm straightforward and keeps the detector free of magic numbers.

import Foundation

/// Encapsulates every threshold the clap detector uses.
/// Create instances via the static factory so sensitivity mapping is consistent.
struct DetectionConfiguration {

    // MARK: – Energy thresholds

    /// Absolute RMS floor below which detection is always suppressed.
    /// Rationale: prevents false triggers from electronic noise (typically < 0.005 RMS).
    /// 0.01 gives a comfortable margin above the noise floor of most iPhone mics.
    let minimumAbsoluteRMS: Float

    /// The spike ratio multiplier: currentRMS must exceed (adaptiveBaseline × spikeMultiplier)
    /// to be considered a transient.
    /// Rationale: hand claps are typically 10–20 dB above ambient noise.
    ///   10 dB ≈ ×3.16 amplitude, 20 dB ≈ ×10 amplitude.
    ///   We use a range of 4× (low sensitivity) to 12× (high sensitivity) so the
    ///   slider covers the practical detection range without false positives.
    let spikeMultiplier: Float

    // MARK: – Adaptive baseline

    /// Exponential smoothing coefficient for the adaptive noise baseline.
    /// Rationale: at ~10 fps (4096 samples @ 44100 Hz) a value of 0.002 gives
    ///   τ ≈ 500 frames ≈ 50 s, making the baseline very slow to rise.
    ///   This prevents a clap from permanently elevating the baseline.
    let adaptiveAlpha: Float

    // MARK: – Attack / duration gates

    /// Minimum positive delta between consecutive RMS frames for attack confirmation.
    /// Rationale: a clap has a sharp onset. Any frame where energy is falling or flat
    ///   is rejected to avoid triggering on slow noise ramps.
    let minimumAttackDelta: Float

    /// Maximum number of consecutive above-threshold frames before the event is
    /// reclassified as sustained noise (speech, music, HVAC).
    /// Rationale: a hand clap's acoustic energy decays within ~2–3 frames (< 280 ms).
    ///   If energy stays elevated for more frames, it is not a clap.
    let maximumSustainedFrames: Int

    // MARK: – Cooldown

    /// Minimum time between two consecutive clap detections.
    /// Rationale: the fastest deliberate double-clap a human can produce is ~200 ms.
    ///   400 ms suppresses mechanical reverb and flutter echo while still
    ///   allowing intentional successive claps.
    let cooldownDuration: TimeInterval

    // MARK: – Factory

    /// Creates a configuration tuned to the given normalised sensitivity value.
    ///
    /// - Parameter sensitivity: 0.0 = hardest to trigger (least sensitive);
    ///                          1.0 = easiest to trigger (most sensitive).
    static func make(sensitivity: Double) -> DetectionConfiguration {
        let clamped = min(max(sensitivity, 0.0), 1.0)

        // Interpolate spike multiplier: high sensitivity → lower threshold needed.
        // Range: 12.0 (insensitive) → 4.0 (very sensitive)
        let spikeMultiplier = Float(12.0 - clamped * 8.0)

        return DetectionConfiguration(
            minimumAbsoluteRMS: 0.01,
            spikeMultiplier: spikeMultiplier,
            adaptiveAlpha: 0.002,
            minimumAttackDelta: 0.002,
            maximumSustainedFrames: 3,
            cooldownDuration: 0.4
        )
    }

    /// Default mid-range configuration.
    static let `default` = DetectionConfiguration.make(sensitivity: 0.5)
}
