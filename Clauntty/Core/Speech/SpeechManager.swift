import Foundation
import UIKit
import AVFoundation
import Combine
import os.log
import FluidAudio

/// Model download and readiness state
enum SpeechModelState: Equatable {
    case notDownloaded
    case downloading(Float)
    case ready
    case failed(String)

    static func == (lhs: SpeechModelState, rhs: SpeechModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded): return true
        case (.ready, .ready): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// Manages on-device speech-to-text using FluidAudio + Parakeet model.
/// Handles model download, audio capture, and transcription.
@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    // MARK: - Published State

    @Published private(set) var modelState: SpeechModelState = .notDownloaded {
        didSet {
            NotificationCenter.default.post(name: .speechModelStateChanged, object: nil)
        }
    }
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isTranscribing: Bool = false

    // MARK: - Audio Capture

    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let sampleRate: Double = 16000

    // MARK: - FluidAudio

    private var asrModels: AsrModels?
    private var asrManager: AsrManager?

    // MARK: - Callbacks

    /// Called when transcription completes with the recognized text
    var onTranscriptionComplete: ((String) -> Void)?

    // MARK: - Persistence Keys

    private let modelDownloadedKey = "speechModelDownloaded"

    // MARK: - Init

    private init() {
        // Check if model exists - either via UserDefaults flag OR cached files on disk
        // (cache may persist across reinstalls even when UserDefaults is cleared)
        if UserDefaults.standard.bool(forKey: modelDownloadedKey) || modelCacheExists() {
            // Model may be available, try to load it
            Task {
                await loadModelIfAvailable()
            }
        }
    }

    /// Check if model cache files exist on disk (rough check based on directory size)
    private func modelCacheExists() -> Bool {
        guard let cacheDir = getCacheDirectory() else { return false }
        let size = directorySize(at: cacheDir)
        // If cache has substantial data (>100MB), models likely exist
        let exists = size > 100_000_000
        if exists {
            Logger.clauntty.debugOnly("SpeechManager: Found existing cache (\(size / 1_000_000)MB)")
        }
        return exists
    }

    // MARK: - Model Management

    /// Check if the model files exist and load them
    private func loadModelIfAvailable() async {
        do {
            Logger.clauntty.debugOnly("SpeechManager: Loading ASR models...")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            self.asrModels = models

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asrManager = manager

            self.modelState = .ready
            UserDefaults.standard.set(true, forKey: modelDownloadedKey)
            Logger.clauntty.debugOnly("SpeechManager: Models loaded successfully")
        } catch {
            Logger.clauntty.error("SpeechManager: Failed to load models: \(error)")
            self.modelState = .notDownloaded
            UserDefaults.standard.set(false, forKey: modelDownloadedKey)
        }
    }

    // Expected model size in bytes (~800MB for v3)
    private let expectedModelSize: Int64 = 800_000_000

    /// Download the speech model (called after user consent)
    func downloadModel() async {
        guard case .notDownloaded = modelState else { return }

        modelState = .downloading(0)
        Logger.clauntty.debugOnly("SpeechManager: Starting model download...")

        // Start progress monitoring task
        let progressTask = Task { @MainActor in
            await monitorDownloadProgress()
        }

        do {
            // FluidAudio downloads from HuggingFace automatically
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            progressTask.cancel()
            self.asrModels = models

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            self.asrManager = manager

            modelState = .ready
            UserDefaults.standard.set(true, forKey: modelDownloadedKey)
            Logger.clauntty.debugOnly("SpeechManager: Model download complete")
        } catch {
            progressTask.cancel()
            Logger.clauntty.error("SpeechManager: Download failed: \(error)")
            modelState = .failed(error.localizedDescription)
        }
    }

    /// Monitor download progress by checking cache directory size
    private func monitorDownloadProgress() async {
        let cacheDir = getCacheDirectory()
        Logger.clauntty.debugOnly("SpeechManager: Monitoring cache at \(cacheDir?.path ?? "unknown")")

        while !Task.isCancelled {
            if let cacheDir = cacheDir {
                let currentSize = directorySize(at: cacheDir)
                let progress = min(Float(currentSize) / Float(expectedModelSize), 0.95) // Cap at 95% until complete
                modelState = .downloading(progress)
                Logger.clauntty.debugOnly("SpeechManager: Download progress: \(Int(progress * 100))% (\(currentSize / 1_000_000)MB)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5s
        }
    }

    /// Get FluidAudio's cache directory
    private func getCacheDirectory() -> URL? {
        // FluidAudio caches to HuggingFace hub cache location
        // On iOS: ~/Library/Caches/huggingface/hub/
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let hfCache = cacheBase?.appendingPathComponent("huggingface/hub")

        // If HF cache doesn't exist yet, fall back to general caches
        if let hfCache = hfCache, FileManager.default.fileExists(atPath: hfCache.path) {
            return hfCache
        }
        return cacheBase
    }

    /// Calculate total size of directory recursively
    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }

    /// Delete the downloaded model to free up space
    func deleteModel() {
        // Stop any active recording
        if isRecording {
            stopRecordingWithoutTranscription()
        }

        asrManager = nil
        asrModels = nil
        modelState = .notDownloaded
        UserDefaults.standard.set(false, forKey: modelDownloadedKey)

        // TODO: Actually delete cached model files from disk
        // FluidAudio caches to ~/.cache/fluidaudio/ on macOS
        // On iOS it would be in the app's cache directory

        Logger.clauntty.debugOnly("SpeechManager: Model deleted")
    }

    // MARK: - Recording

    /// Request microphone permission
    func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Check if microphone permission is granted
    var hasMicrophonePermission: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// Start recording audio
    func startRecording() {
        guard case .ready = modelState else {
            Logger.clauntty.warning("SpeechManager: Cannot record - model not ready")
            return
        }

        guard !isRecording else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Clear previous buffer
            audioBuffer.removeAll()

            // Install tap to capture audio
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer, inputSampleRate: recordingFormat.sampleRate)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            Logger.clauntty.debugOnly("SpeechManager: Recording started")

            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

        } catch {
            Logger.clauntty.error("SpeechManager: Failed to start recording: \(error)")
        }
    }

    /// Process incoming audio buffer and resample to 16kHz mono
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputSampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Convert to mono by averaging channels
        var monoSamples = [Float](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            monoSamples[frame] = sum / Float(channelCount)
        }

        // Resample to 16kHz if needed
        if inputSampleRate != sampleRate {
            let ratio = sampleRate / inputSampleRate
            let outputLength = Int(Double(frameLength) * ratio)
            var resampled = [Float](repeating: 0, count: outputLength)

            for i in 0..<outputLength {
                let srcIndex = Double(i) / ratio
                let srcIndexInt = Int(srcIndex)
                let fraction = Float(srcIndex - Double(srcIndexInt))

                if srcIndexInt + 1 < frameLength {
                    resampled[i] = monoSamples[srcIndexInt] * (1 - fraction) + monoSamples[srcIndexInt + 1] * fraction
                } else if srcIndexInt < frameLength {
                    resampled[i] = monoSamples[srcIndexInt]
                }
            }
            monoSamples = resampled
        }

        // Append to buffer (thread-safe via MainActor)
        Task { @MainActor in
            self.audioBuffer.append(contentsOf: monoSamples)
        }
    }

    /// Stop recording and transcribe the audio
    func stopRecording() async -> String? {
        guard isRecording else { return nil }

        stopAudioEngine()
        isRecording = false

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        Logger.clauntty.debugOnly("SpeechManager: Recording stopped, captured \(self.audioBuffer.count) samples")

        // Transcribe
        guard !audioBuffer.isEmpty else {
            Logger.clauntty.debugOnly("SpeechManager: No audio captured")
            return nil
        }

        return await transcribe()
    }

    /// Stop recording without transcribing (e.g., cancelled)
    func stopRecordingWithoutTranscription() {
        guard isRecording else { return }

        stopAudioEngine()
        isRecording = false
        audioBuffer.removeAll()

        Logger.clauntty.debugOnly("SpeechManager: Recording cancelled")
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Transcription

    private func transcribe() async -> String? {
        guard let asrManager = asrManager else {
            Logger.clauntty.error("SpeechManager: ASR manager not initialized")
            return nil
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            Logger.clauntty.debugOnly("SpeechManager: Starting transcription...")

            let result = try await asrManager.transcribe(audioBuffer)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            Logger.clauntty.debugOnly("SpeechManager: Transcription result: '\(text)'")

            // Clear buffer after transcription
            audioBuffer.removeAll()

            // Don't return empty results
            guard !text.isEmpty else {
                return nil
            }

            // Notify callback
            onTranscriptionComplete?(text)

            return text
        } catch {
            Logger.clauntty.error("SpeechManager: Transcription failed: \(error)")
            audioBuffer.removeAll()
            return nil
        }
    }
}
