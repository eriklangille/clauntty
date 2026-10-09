import AVFoundation
import os.log

/// Mic in, speaker out for the voice agent.
///
/// Set up the way AIProxySwift's AVAudioEngine path does it for headphones
/// (github.com/lzell/AIProxySwift, MicrophonePCMSampleVendorAE): no voice processing,
/// and the tap asks for 16-bit samples at the hardware rate, which xAI accepts as is.
/// Voice processing on AVAudioEngine is unreliable (the mic stopped after a few
/// seconds on AirPods in the first test), and headphones don't echo anyway.
///
/// On the phone speaker there's no echo cancellation yet, so while the model talks
/// the mic is muted instead (no barge-in there). Proper speaker support would use the
/// voice-processing audio unit directly, like AIProxySwift's AudioToolbox path.
final class VoiceAudio {
    /// Rates xAI's `audio/pcm` accepts
    static let supportedRates: Set<Int> = [8000, 16000, 22050, 24000, 32000, 44100, 48000]
    /// Model audio comes back at xAI's default rate
    static let outputRate: Double = 24000

    /// Mic audio, mono PCM16 little-endian at `inputRate`, about 100ms at a time.
    /// Called on the audio thread.
    var onInput: ((Data) -> Void)?

    /// The mic's rate changed (the route changed mid-session). Main thread.
    var onInputRateChanged: ((Int) -> Void)?

    /// Called on the main thread when everything queued has finished playing
    var onPlaybackDrained: (() -> Void)?

    /// The mic's sample rate, which is what xAI is told the input is
    private(set) var inputRate = 24000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceAudio.outputRate, channels: 1, interleaved: false)!

    /// Mic samples waiting to make up a full chunk. Audio thread.
    private var pending = Data()

    /// Buffers scheduled and not yet played. Main thread.
    private var pendingBuffers = 0 {
        didSet { modelSpeaking = pendingBuffers > 0 }
    }
    /// Read on the audio thread to mute the mic on the speaker while the model talks
    private var modelSpeaking = false
    /// Bumped on flush, so completions of flushed buffers are ignored
    private var generation = 0

    private var observers: [NSObjectProtocol] = []

    /// When the mic last delivered audio. Written on the audio thread, read on main.
    private let lastInputLock = NSLock()
    private var lastInputAt = Date()
    private var watchdog: Timer?

    var isPlaying: Bool { pendingBuffers > 0 }

    /// Headphones or a Bluetooth headset, so the model can't hear itself
    private(set) var onHeadphones = false

    /// Set up the audio session and find the mic's rate, before connecting to xAI
    func prepare() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        try readInputRate()
    }

    func start() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        // The route can change between prepare() and now (AirPods moving over)
        let preparedRate = inputRate
        try readInputRate()
        if inputRate != preparedRate {
            onInputRateChanged?(inputRate)
        }
        installTap()

        engine.prepare()
        try engine.start()
        player.play()

        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            voiceTrace("audio route changed (reason \(reason)): \(Self.describeRoute())")
            self?.updateHeadphones()
        })
        voiceTrace("audio started (mic \(inputRate)Hz, headphones \(onHeadphones), \(describeOutput())): \(Self.describeRoute())")

        // A route change can leave the tap silent: when AirPods move over from another
        // device mid-start, the restart can read the old rate and the mic never delivers
        // again. If it goes quiet, set it up again for whatever the route is now.
        markInput()
        let watchdog = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastInput) > 2 else { return }
            voiceTrace("audio mic delivered nothing for 2s; setting it up again")
            self.markInput()
            self.restartAfterConfigurationChange()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    private var lastInput: Date {
        lastInputLock.lock()
        defer { lastInputLock.unlock() }
        return lastInputAt
    }

    private func markInput() {
        lastInputLock.lock()
        lastInputAt = Date()
        lastInputLock.unlock()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        pendingBuffers = 0
        generation += 1
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        voiceTrace("audio stopped")
    }

    // MARK: - Input

    /// Read the rate from the hardware side of the input node: installTap aborts the app
    /// (an Objective-C exception) unless the tap's rate matches it, and while the route
    /// is changing the node's output side can still report the old rate
    private func readInputRate() throws {
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        let rate = Int(hardware.sampleRate)
        guard hardware.channelCount > 0 else {
            throw VoiceAudioError.noMicrophone
        }
        guard Self.supportedRates.contains(rate) else {
            throw VoiceAudioError.unsupportedRate(rate)
        }
        inputRate = rate
        updateHeadphones()
    }

    private func installTap() {
        let rate = Double(inputRate)
        // The tap converts to 16-bit for us; only the rate has to match the hardware
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false) else { return }
        pending = Data()
        var buffers = 0
        // ~50ms buffers, sent in ~100ms chunks
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(rate / 20), format: format) { [weak self] buffer, _ in
            buffers += 1
            if buffers == 1 {
                voiceTrace("audio first mic buffer: \(buffer.frameLength) frames")
            }
            self?.handleInput(buffer)
        }
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.int16ChannelData, buffer.frameLength > 0 else { return }
        markInput()
        // On the speaker, don't let the model hear (and interrupt) itself
        if modelSpeaking && !onHeadphones {
            pending.removeAll(keepingCapacity: true)
            return
        }
        pending.append(Data(bytes: samples[0], count: Int(buffer.frameLength) * 2))
        if pending.count >= inputRate / 10 * 2 {
            onInput?(pending)
            pending = Data()
        }
    }

    /// The engine stops itself when the hardware changes (e.g. AirPods switching
    /// profiles); start it again, at the new rate if it changed. If the mic isn't
    /// ready yet, this leaves it off and the watchdog tries again.
    private func restartAfterConfigurationChange() {
        let oldRate = inputRate
        engine.inputNode.removeTap(onBus: 0)
        // Start over from a stopped engine, dropping whatever was queued to play
        engine.stop()
        player.stop()
        generation += 1
        pendingBuffers = 0
        do {
            try readInputRate()
            // Checked again right before installing: a mismatch here crashes
            guard Int(engine.inputNode.inputFormat(forBus: 0).sampleRate) == inputRate else {
                voiceTrace("audio mic rate changed while restarting; will retry")
                return
            }
            // The output changed too (AirPods' call profile is mono and slower than
            // music playback): connect again so playback follows the new hardware
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            installTap()
            engine.prepare()
            try engine.start()
            player.play()
            voiceTrace("audio restarted after configuration change (mic \(inputRate)Hz, \(describeOutput())): \(Self.describeRoute())")
            if inputRate != oldRate {
                onInputRateChanged?(inputRate)
            }
        } catch {
            voiceTrace("audio restart failed: \(error.localizedDescription)")
        }
    }

    private func updateHeadphones() {
        let headsetPorts: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        onHeadphones = AVAudioSession.sharedInstance().currentRoute.outputs.contains { headsetPorts.contains($0.portType) }
    }

    /// "out 24000Hz x1 (mixer 24000Hz x1)": the hardware output and what the mixer sends it
    private func describeOutput() -> String {
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        return "out \(Int(hardware.sampleRate))Hz x\(hardware.channelCount) (mixer \(Int(mixer.sampleRate))Hz x\(mixer.channelCount))"
    }

    private static func describeRoute() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return "in \(route.inputs.map(\.portName)), out \(route.outputs.map(\.portName))"
    }

    // MARK: - Output

    /// Queue model audio (24kHz mono PCM16 little-endian). Main thread.
    func play(_ pcm16: Data) {
        let frames = pcm16.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768
            }
        }

        pendingBuffers += 1
        let scheduledGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == scheduledGeneration else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers == 0 {
                    self.onPlaybackDrained?()
                }
            }
        }
        if !player.isPlaying {
            player.play()
        }
    }

    /// Drop everything queued (the user started talking over the model). Main thread.
    func flush() {
        generation += 1
        pendingBuffers = 0
        player.stop()
        player.play()
    }
}

enum VoiceAudioError: LocalizedError {
    case unsupportedRate(Int)
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .unsupportedRate(let rate): return "The microphone runs at \(rate)Hz, which xAI doesn't accept"
        case .noMicrophone: return "No microphone is available"
        }
    }
}
