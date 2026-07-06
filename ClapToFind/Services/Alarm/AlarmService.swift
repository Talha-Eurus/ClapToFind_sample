// ClapToFind — AlarmService.swift
// Synthesises an alarm tone via AVAudioSourceNode pre-attached to AVAudioEngine.
//
// CRITICAL DESIGN: The audio node graph is built ONCE before the engine starts.
// Connecting nodes to a running AVAudioEngine forces an IO context restart
// ("Abandoning I/O cycle because reconfig pending"), which silences the new node
// during the restart window. The fix is to pre-attach everything at startup and
// gate output using AVAudioMixerNode.outputVolume (a parameter change, not a
// graph change — zero reconfig, zero silence).
//
// Topology:
//   AVAudioSourceNode → alarmMixerNode (vol 0/1) → engine.mainMixerNode → output
//
// Tone design:
//   880 Hz (A5) primary + 1320 Hz (E6) harmonic + 4 Hz tremolo
//
// Actor isolation:
//   Phase accumulators are nonisolated(unsafe) because they are mutated
//   exclusively on the AVAudioEngine realtime render thread. With
//   SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor the stored vars would otherwise
//   be @MainActor-isolated, making access from the render thread undefined
//   behaviour under Swift 6 concurrency rules.

import AVFoundation

// MARK: – Protocol

protocol AlarmServicing: AnyObject {
    /// Pre-build the node graph and attach it to the engine.
    /// Must be called BEFORE engine.start() to avoid mid-stream IO reconfig.
    func attachGraph(outputSampleRate: Double)
    /// Gate-open the alarm mixer. No graph changes; zero reconfig overhead.
    func startAlarm() throws
    /// Gate-close the alarm mixer and reset oscillator phases.
    func stopAlarm()
    var isPlaying: Bool { get }
}

// MARK: – Errors

enum AlarmServiceError: Error, LocalizedError {
    case graphNotAttached
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .graphNotAttached: return "attachGraph(outputSampleRate:) must be called before startAlarm()."
        case .invalidFormat:    return "Could not build a valid audio format for alarm synthesis."
        }
    }
}

// MARK: – Concrete implementation

final class AlarmService: AlarmServicing {

    // MARK: – Dependencies

    private let engine: AVAudioEngine

    // MARK: – Graph nodes (created once in attachGraph)

    private var sourceNode: AVAudioSourceNode?
    private var alarmMixer: AVAudioMixerNode?
    private var isGraphAttached = false

    // MARK: – Synthesis constants

    private let primaryFrequency: Float  = 880.0
    private let harmonicFrequency: Float = 1320.0
    private let tremoloFrequency: Float  = 4.0
    private let amplitude: Float         = 0.9

    // MARK: – Phase accumulators
    // nonisolated(unsafe): mutated only on the AVAudioEngine realtime render thread.
    // Must NOT be @MainActor — routing through the actor would deadlock the render thread.
    nonisolated(unsafe) private var isRenderingActive: Bool  = false
    nonisolated(unsafe) private var primaryPhase: Float      = 0
    nonisolated(unsafe) private var harmonicPhase: Float     = 0
    nonisolated(unsafe) private var tremoloPhase: Float      = 0

    // MARK: – State

    private(set) var isPlaying: Bool = false

    // MARK: – Init

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    // MARK: – AlarmServicing

    func attachGraph(outputSampleRate: Double) {
        guard !isGraphAttached else { return }

        let rate = outputSampleRate > 0 ? outputSampleRate : 44100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            return
        }

        let floatRate        = Float(rate)
        let primaryInc       = 2.0 * Float.pi * primaryFrequency  / floatRate
        let harmonicInc      = 2.0 * Float.pi * harmonicFrequency / floatRate
        let tremoloInc       = 2.0 * Float.pi * tremoloFrequency  / floatRate

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }

            let abl    = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            // When inactive write zeros directly — skip sine computation.
            guard self.isRenderingActive else {
                for buf in abl {
                    if let ptr = buf.mData { memset(ptr, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }

            for frame in 0..<frames {
                let tremolo = (sinf(self.tremoloPhase) + 1.0) * 0.5
                let sample  = self.amplitude * tremolo * (
                    0.7 * sinf(self.primaryPhase) +
                    0.3 * sinf(self.harmonicPhase)
                )
                for buf in abl {
                    buf.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
                self.primaryPhase  = fmodf(self.primaryPhase  + primaryInc,  .pi * 2)
                self.harmonicPhase = fmodf(self.harmonicPhase + harmonicInc, .pi * 2)
                self.tremoloPhase  = fmodf(self.tremoloPhase  + tremoloInc,  .pi * 2)
            }
            return noErr
        }

        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        engine.attach(node)

        // Connect alarm sub-graph: source → dedicated mixer → main mixer
        engine.connect(node,  to: mixer,                 format: format)
        engine.connect(mixer, to: engine.mainMixerNode,  format: format)

        // Start silent — volume will be set to 1.0 in startAlarm().
        // Changing outputVolume on a running mixer is a parameter change,
        // NOT a graph change, so it causes zero IO reconfig overhead.
        mixer.outputVolume = 0

        self.sourceNode      = node
        self.alarmMixer      = mixer
        self.isGraphAttached = true
    }

    func startAlarm() throws {
        guard isGraphAttached, let mixer = alarmMixer else {
            throw AlarmServiceError.graphNotAttached
        }
        // Activate the render block first so samples are ready
        // before we open the mixer gate.
        isRenderingActive    = true
        mixer.outputVolume   = 1.0
        isPlaying            = true
    }

    func stopAlarm() {
        alarmMixer?.outputVolume = 0
        isRenderingActive        = false
        isPlaying                = false
        // Reset phases so next alarm starts from a clean zero-crossing (no click).
        primaryPhase  = 0
        harmonicPhase = 0
        tremoloPhase  = 0
    }
}
