// ClapToFind — DetectionResult.swift
// Value type representing the output of a single clap detection frame analysis.

import Foundation

/// The result produced by the clap detector after analyzing one audio buffer frame.
struct DetectionResult {
    /// Whether a clap was positively detected in this frame.
    let wasDetected: Bool

    /// The computed RMS energy of the frame (0.0 – 1.0).
    let rmsEnergy: Float

    /// The current adaptive noise floor at the time of analysis.
    let adaptiveBaseline: Float

    /// The spike ratio (rmsEnergy / adaptiveBaseline) that triggered detection, if any.
    let spikeRatio: Float

    /// Wall-clock timestamp of detection.
    let timestamp: Date

    static let empty = DetectionResult(
        wasDetected: false,
        rmsEnergy: 0,
        adaptiveBaseline: 0,
        spikeRatio: 0,
        timestamp: .now
    )
}
