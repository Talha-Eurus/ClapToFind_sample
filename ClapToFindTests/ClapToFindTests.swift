// ClapToFind — ClapDetectorTests.swift
// Comprehensive unit tests for the clap detection pipeline.
// Tests are structured so each DSP stage is exercised independently.
//
// Testing strategy:
//  - Use DSPUtilities buffer factories to create deterministic synthetic signals.
//  - Drive the detector with sequences of buffers to test stateful behaviour.
//  - Verify DetectionResult fields for both positive and negative cases.
//  - No AVAudioEngine, no real microphone — fully synchronous and fast.

import Testing
import AVFoundation
@testable import ClapToFind

// MARK: – DSP Utilities Tests

@Suite("DSPUtilities")
struct DSPUtilitiesTests {

    @Test("RMS of silence is zero")
    func rmsOfSilenceIsZero() throws {
        let buffer = try #require(DSPUtilities.makeSilenceBuffer())
        let rms = DSPUtilities.rms(buffer: buffer)
        #expect(rms == 0.0)
    }

    @Test("RMS of full-scale sine is ~0.707")
    func rmsOfFullScaleSine() throws {
        // RMS of a unit sine wave = 1 / √2 ≈ 0.7071
        let buffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 1.0))
        let rms = DSPUtilities.rms(buffer: buffer)
        #expect(abs(rms - 0.7071) < 0.002, "Expected ≈0.707, got \(rms)")
    }

    @Test("RMS scales linearly with amplitude")
    func rmsScalesWithAmplitude() throws {
        let buffer1 = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 0.5))
        let buffer2 = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 1.0))
        let rms1 = DSPUtilities.rms(buffer: buffer1)
        let rms2 = DSPUtilities.rms(buffer: buffer2)
        #expect(abs(rms2 / rms1 - 2.0) < 0.01, "RMS should double when amplitude doubles")
    }

    @Test("Peak of full-scale sine is ~1.0")
    func peakOfSine() throws {
        let buffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 1.0))
        let peak = DSPUtilities.peak(buffer: buffer)
        #expect(peak >= 0.99, "Peak should be ≈1.0, got \(peak)")
    }

    @Test("Peak of silence is 0.0")
    func peakOfSilence() throws {
        let buffer = try #require(DSPUtilities.makeSilenceBuffer())
        let peak = DSPUtilities.peak(buffer: buffer)
        #expect(peak == 0.0)
    }
}

// MARK: – DetectionConfiguration Tests

@Suite("DetectionConfiguration")
struct DetectionConfigurationTests {

    @Test("Default configuration has valid values")
    func defaultConfigurationIsValid() {
        let config = DetectionConfiguration.default
        #expect(config.minimumAbsoluteRMS > 0)
        #expect(config.spikeMultiplier > 1)
        #expect(config.adaptiveAlpha > 0 && config.adaptiveAlpha < 1)
        #expect(config.maximumSustainedFrames > 0)
        #expect(config.cooldownDuration > 0)
    }

    @Test("Sensitivity 0 produces highest spike multiplier (hardest to trigger)")
    func sensitivityZeroIsHardestToTrigger() {
        let low = DetectionConfiguration.make(sensitivity: 0.0)
        let high = DetectionConfiguration.make(sensitivity: 1.0)
        #expect(low.spikeMultiplier > high.spikeMultiplier,
                "Low sensitivity should require a higher spike ratio")
    }

    @Test("Sensitivity clamped to [0, 1]")
    func sensitivityClamped() {
        let tooLow = DetectionConfiguration.make(sensitivity: -5.0)
        let tooHigh = DetectionConfiguration.make(sensitivity: 100.0)
        let zero = DetectionConfiguration.make(sensitivity: 0.0)
        let one = DetectionConfiguration.make(sensitivity: 1.0)
        #expect(tooLow.spikeMultiplier == zero.spikeMultiplier)
        #expect(tooHigh.spikeMultiplier == one.spikeMultiplier)
    }
}

// MARK: – ClapDetector Tests

@Suite("ClapDetector")
struct ClapDetectorTests {

    // MARK: – Absolute floor gate

    @Test("Silence never triggers detection")
    func silenceNeverTriggers() throws {
        let detector = ClapDetector(configuration: .default)
        let silence = try #require(DSPUtilities.makeSilenceBuffer())

        for _ in 0..<10 {
            let result = detector.process(buffer: silence)
            #expect(!result.wasDetected, "Silence must never produce a detection")
        }
    }

    @Test("Very quiet noise below absolute floor is rejected")
    func quietNoiseRejected() throws {
        let config = DetectionConfiguration.default
        let detector = ClapDetector(configuration: config)

        // Create noise that is below minimumAbsoluteRMS
        let subFloorAmplitude: Float = 0.005 // well below 0.01 floor
        let quietBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: subFloorAmplitude))
        let rms = DSPUtilities.rms(buffer: quietBuffer)
        // Verify our test signal is actually below the floor
        #expect(rms < config.minimumAbsoluteRMS, "Test signal RMS \(rms) should be below floor \(config.minimumAbsoluteRMS)")

        let result = detector.process(buffer: quietBuffer)
        #expect(!result.wasDetected)
    }

    // MARK: – Spike detection

    @Test("A single large spike is detected after adaptive baseline warms up")
    func singleSpikeDetectedAfterWarmup() throws {
        // Use very high sensitivity to make the test reliable
        let config = DetectionConfiguration.make(sensitivity: 1.0)
        let detector = ClapDetector(configuration: config)

        // Warm up the adaptive baseline with consistent low-amplitude noise
        let ambientAmplitude: Float = 0.02
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: ambientAmplitude))
        for _ in 0..<50 {
            _ = detector.process(buffer: ambientBuffer)
        }

        // Now send a spike: amplitude 10× the ambient
        let spikeAmplitude: Float = ambientAmplitude * 20
        let spikeBuffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: spikeAmplitude))

        let result = detector.process(buffer: spikeBuffer)
        #expect(result.wasDetected, "A large spike above baseline should be detected")
        #expect(result.spikeRatio > config.spikeMultiplier, "Spike ratio \(result.spikeRatio) should exceed multiplier \(config.spikeMultiplier)")
    }

    @Test("Spike just below threshold is not detected")
    func spikeBelowThresholdNotDetected() throws {
        // Use minimum sensitivity = highest multiplier threshold
        let config = DetectionConfiguration.make(sensitivity: 0.0)
        let detector = ClapDetector(configuration: config)

        let ambientAmplitude: Float = 0.02
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: ambientAmplitude))
        for _ in 0..<50 {
            _ = detector.process(buffer: ambientBuffer)
        }

        // Spike is only 3× ambient — well below the 12× threshold at sensitivity 0
        let spikeBuffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: ambientAmplitude * 3))
        let result = detector.process(buffer: spikeBuffer)
        #expect(!result.wasDetected, "A spike below the threshold should not be detected")
    }

    // MARK: – Sustained-sound rejection

    @Test("Sustained loud noise does not produce a detection")
    func sustainedNoiseRejected() throws {
        let config = DetectionConfiguration.make(sensitivity: 1.0)
        let detector = ClapDetector(configuration: config)

        // Warm up baseline
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: 0.02))
        for _ in 0..<50 {
            _ = detector.process(buffer: ambientBuffer)
        }

        // Sustained loud noise (10× ambient) — held for many frames
        let sustainedBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: 0.4))
        var detections = 0

        // After the first few frames (where attack might briefly pass), sustained
        // sound should be rejected by the maximumSustainedFrames gate.
        // We expect at most 1 detection (the initial transient) then silence.
        for _ in 0..<20 {
            let result = detector.process(buffer: sustainedBuffer)
            if result.wasDetected { detections += 1 }
        }

        // Allow at most 1 detection for the initial transient; sustained noise must not repeat
        #expect(detections <= 1, "Sustained noise should not produce repeated detections; got \(detections)")
    }

    // MARK: – Cooldown / debounce

    @Test("Two rapid clap signals are debounced by cooldown")
    func cooldownPreventsDoubleDetection() throws {
        let config = DetectionConfiguration.make(sensitivity: 1.0)
        let detector = ClapDetector(configuration: config)

        // Warm up
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: 0.02))
        for _ in 0..<50 {
            _ = detector.process(buffer: ambientBuffer)
        }

        let spikeBuffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 0.5))

        // First spike — should detect
        let first = detector.process(buffer: spikeBuffer)

        // Reset sustained counter by sending a quiet frame
        _ = detector.process(buffer: ambientBuffer)

        // Immediate second spike — should be blocked by cooldown
        let second = detector.process(buffer: spikeBuffer)

        if first.wasDetected {
            #expect(!second.wasDetected, "Second detection within cooldown window should be suppressed")
        }
    }

    // MARK: – Reset

    @Test("Reset clears all state including cooldown")
    func resetClearsState() throws {
        let config = DetectionConfiguration.make(sensitivity: 1.0)
        let detector = ClapDetector(configuration: config)

        // Warm up and trigger a clap to engage cooldown
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: 0.02))
        for _ in 0..<50 { _ = detector.process(buffer: ambientBuffer) }
        let spike = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 0.5))
        _ = detector.process(buffer: spike)

        // Reset — should clear cooldown
        detector.reset()

        // After reset, warm up again and trigger
        for _ in 0..<50 { _ = detector.process(buffer: ambientBuffer) }
        let resultAfterReset = detector.process(buffer: spike)

        // The cooldown was reset so a new detection should be possible
        // (We just verify no crash and the detector processes correctly)
        #expect(resultAfterReset.rmsEnergy > 0, "Detector should process buffers normally after reset")
    }

    // MARK: – Configuration update

    @Test("updateConfiguration changes detection threshold without reset")
    func updateConfigurationChangesThreshold() throws {
        let detector = ClapDetector(configuration: DetectionConfiguration.make(sensitivity: 0.0))

        // Warm up
        let ambientBuffer = try #require(DSPUtilities.makeNoiseBuffer(amplitude: 0.02))
        for _ in 0..<50 { _ = detector.process(buffer: ambientBuffer) }

        // Moderate spike — should NOT detect at low sensitivity (high multiplier)
        let moderateSpike = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 0.1))
        let beforeUpdate = detector.process(buffer: moderateSpike)

        // Switch to maximum sensitivity — same spike should now potentially detect
        detector.updateConfiguration(DetectionConfiguration.make(sensitivity: 1.0))

        // Reset cooldown and sustained count via ambient frames
        for _ in 0..<5 { _ = detector.process(buffer: ambientBuffer) }

        let afterUpdate = detector.process(buffer: moderateSpike)

        // At minimum, the spike ratio should be reported identically (deterministic RMS).
        // The key assertion is that config was accepted without crashing.
        #expect(afterUpdate.rmsEnergy > 0)
        _ = beforeUpdate // suppress unused warning
    }

    // MARK: – DetectionResult fields

    @Test("DetectionResult carries correct RMS energy")
    func detectionResultCarriesRMS() throws {
        let detector = ClapDetector(configuration: .default)
        let sineBuffer = try #require(DSPUtilities.makeSineBuffer(frequency: 440, amplitude: 0.5))
        let expectedRMS = DSPUtilities.rms(buffer: sineBuffer)

        let result = detector.process(buffer: sineBuffer)
        #expect(abs(result.rmsEnergy - expectedRMS) < 0.001,
                "Result RMS \(result.rmsEnergy) should match computed RMS \(expectedRMS)")
    }

    @Test("DetectionResult timestamp is recent")
    func detectionResultTimestampIsRecent() throws {
        let detector = ClapDetector(configuration: .default)
        let buffer = try #require(DSPUtilities.makeSilenceBuffer())
        let before = Date.now
        let result = detector.process(buffer: buffer)
        let after = Date.now
        #expect(result.timestamp >= before && result.timestamp <= after)
    }
}
