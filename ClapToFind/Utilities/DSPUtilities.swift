// ClapToFind — DSPUtilities.swift
// Pure, stateless DSP helper functions. Being side-effect-free makes them
// trivially unit-testable and safe to call from any thread.

import AVFoundation
import Accelerate

enum DSPUtilities {

    // MARK: – RMS

    /// Computes the root-mean-square amplitude of a mono PCM float buffer.
    ///
    /// RMS = sqrt( (1/N) Σ x²_i )
    ///
    /// Uses Accelerate for SIMD throughput; falls back gracefully to 0 on
    /// empty or non-float buffers.
    ///
    /// - Parameter buffer: The audio buffer to analyse.
    /// - Returns: RMS in the range [0, 1] for normalised float PCM.
    static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else { return 0 }

        let frameCount = Int(buffer.frameLength)
        let samples = channelData[0] // mono; use channel 0

        var sumOfSquares: Float = 0
        vDSP_svesq(samples, 1, &sumOfSquares, vDSP_Length(frameCount))

        return sqrtf(sumOfSquares / Float(frameCount))
    }

    // MARK: – Peak

    /// Returns the absolute peak sample value in the buffer.
    ///
    /// Used for clipping detection and as a secondary energy measure.
    ///
    /// - Parameter buffer: The audio buffer to inspect.
    /// - Returns: Peak amplitude in [0, 1].
    static func peak(buffer: AVAudioPCMBuffer) -> Float {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else { return 0 }

        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        vDSP_maxmgv(channelData[0], 1, &peak, vDSP_Length(frameCount))
        return peak
    }

    // MARK: – Buffer creation helpers (used in tests)

    /// Creates an `AVAudioPCMBuffer` filled with a constant amplitude sine wave.
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz.
    ///   - amplitude: Peak amplitude in [0, 1].
    ///   - sampleRate: Audio sample rate.
    ///   - frameCount: Number of frames in the buffer.
    /// - Returns: A float PCM buffer, or nil if the format is invalid.
    static func makeSineBuffer(
        frequency: Float,
        amplitude: Float,
        sampleRate: Double = 44100,
        frameCount: AVAudioFrameCount = 4096
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        let phaseIncrement = 2.0 * Float.pi * frequency / Float(sampleRate)

        for i in 0..<Int(frameCount) {
            samples[i] = amplitude * sinf(Float(i) * phaseIncrement)
        }
        return buffer
    }

    /// Creates an `AVAudioPCMBuffer` filled with silence (all zeros).
    static func makeSilenceBuffer(
        sampleRate: Double = 44100,
        frameCount: AVAudioFrameCount = 4096
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        // AVAudioPCMBuffer memory is zero-initialised by the framework.
        return buffer
    }

    /// Creates an `AVAudioPCMBuffer` filled with white noise at the given amplitude.
    static func makeNoiseBuffer(
        amplitude: Float,
        sampleRate: Double = 44100,
        frameCount: AVAudioFrameCount = 4096
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            // Float.random in [-1,1] scaled by amplitude
            samples[i] = Float.random(in: -1...1) * amplitude
        }
        return buffer
    }
}
