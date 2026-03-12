import Foundation
import AVFoundation
import WhisperKit

/// Detects a wake word ("波波") using a lightweight WhisperKit tiny model.
/// Runs its own AVAudioEngine for background listening and pauses when
/// ChatManager is actively recording or playing TTS.
@MainActor
class WakeWordDetector {
    // MARK: - Configuration
    private let energyThreshold: Float = 0.006
    private let silenceDuration: TimeInterval = 0.5
    private let maxListenDuration: TimeInterval = 2.0
    
    // Default wake words
    static let defaultWakeWords = ["小虾", "小蝦", "小瞎", "小下", "小香", "小夏", "小霞", "小侠", "小俠", "虾", "蝦"]
    
    // User-configurable wake words (stored in UserDefaults)
    var wakeWords: [String] {
        get {
            if let saved = UserDefaults.standard.array(forKey: "wakeWords") as? [String], !saved.isEmpty {
                return saved
            }
            return Self.defaultWakeWords
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "wakeWords")
        }
    }

    // MARK: - State
    private var whisperKit: WhisperKit?
    private var whisperReady = false
    private var audioEngine = AVAudioEngine()
    private var isDetecting = false
    var isPaused = false

    // VAD state
    private var isCapturing = false
    private var capturedSamples: [Float] = []
    private var captureStartTime: Date?
    private var lastVoiceTime: Date?
    private var inputSampleRate: Double = 48000.0
    
    // Pre-buffer: keep last ~0.5s of audio so we don't cut off word onsets
    private var preBuffer: [Float] = []
    private let preBufferDuration: Double = 0.5  // seconds

    /// Called on the main thread when the wake word is detected.
    var onWakeWordDetected: (() -> Void)?
    var onModelLoaded: (() -> Void)?

    // MARK: - Init

    func setup() async {
        await loadTinyModel()
    }

    var modelBasePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml").path
    
    private func loadTinyModel() async {
        let localModelsBase = URL(fileURLWithPath: modelBasePath)

        let modelsToTry = ["small", "base", "tiny"]
        for modelName in modelsToTry {
            let modelFolder = localModelsBase.appendingPathComponent("openai_whisper-\(modelName)")
            let useLocal = FileManager.default.fileExists(atPath: modelFolder.path)

            do {
                debugLog("[WakeWord] Trying model: \(modelName) (local=\(useLocal))...")
                let config: WhisperKitConfig
                if useLocal {
                    config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, logLevel: .error)
                } else {
                    config = WhisperKitConfig(model: modelName, verbose: false, logLevel: .error)
                }
                whisperKit = try await WhisperKit(config)
                whisperReady = true
                debugLog("[WakeWord] ✅ Tiny model '\(modelName)' loaded")
                onModelLoaded?()
                return
            } catch {
                debugLog("[WakeWord] ❌ Model '\(modelName)' failed: \(error.localizedDescription)")
            }
        }
        debugLog("[WakeWord] All wake-word models failed to load")
    }

    // MARK: - Start / Stop
    
    /// Request microphone permission explicitly before starting
    func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func startDetecting() {
        guard whisperReady, !isDetecting else { return }
        guard !isPaused else { return }

        isDetecting = true
        isCapturing = false
        capturedSamples.removeAll()
        captureStartTime = nil
        lastVoiceTime = nil

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputSampleRate = recordingFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                self?.processAudioBuffer(buffer)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            debugLog("[WakeWord] Audio engine started, listening for wake word...")
        } catch {
            debugLog("[WakeWord] Audio engine failed: \(error)")
            isDetecting = false
        }
    }

    func stopDetecting() {
        guard isDetecting else { return }
        isDetecting = false
        isCapturing = false
        capturedSamples.removeAll()

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        debugLog("[WakeWord] Stopped detecting")
    }

    /// Pause detection (e.g. when ChatManager is recording or speaking).
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        stopDetecting()
        debugLog("[WakeWord] Paused")
    }

    /// Resume detection after ChatManager returns to idle.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        debugLog("[WakeWord] Resumed")
        startDetecting()
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isDetecting else { return }
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        // Calculate RMS energy
        var rms: Float = 0
        for s in samples { rms += s * s }
        rms = sqrtf(rms / Float(frameLength))

        let now = Date()
        
        // Maintain pre-buffer (rolling window of last ~0.5s)
        let maxPreBufferSamples = Int(inputSampleRate * preBufferDuration)

        if rms > energyThreshold {
            // Voice detected
            if !isCapturing {
                // Start capturing — prepend pre-buffer to catch word onset
                isCapturing = true
                capturedSamples = preBuffer  // include audio before voice detection
                preBuffer.removeAll()
                captureStartTime = now
                debugLog("[WakeWord] 👂 检测中... (rms=\(String(format: "%.4f", rms)))")
            }
            lastVoiceTime = now
            capturedSamples.append(contentsOf: samples)
        } else if isCapturing {
            // Silence while capturing
            capturedSamples.append(contentsOf: samples)

            let silenceElapsed = now.timeIntervalSince(lastVoiceTime ?? now)
            let totalElapsed = now.timeIntervalSince(captureStartTime ?? now)

            if silenceElapsed >= silenceDuration || totalElapsed >= maxListenDuration {
                // End of utterance — check average energy before transcribing
                let samplesToTranscribe = capturedSamples
                isCapturing = false
                capturedSamples.removeAll()
                captureStartTime = nil
                lastVoiceTime = nil
                
                // Calculate average RMS of captured audio
                var avgEnergy: Float = 0
                for s in samplesToTranscribe { avgEnergy += s * s }
                avgEnergy = sqrtf(avgEnergy / Float(max(samplesToTranscribe.count, 1)))
                
                // Skip if average energy too low (background noise, not speech)
                guard avgEnergy > 0.003 else {
                    debugLog("[WakeWord] ⏭️ 跳过转写 — avgEnergy \(String(format: "%.4f", avgEnergy)) 太低")
                    return
                }

                Task { @MainActor in
                    await transcribeAndCheck(samplesToTranscribe)
                }
            }
        } else {
            // Not capturing — fill pre-buffer (rolling window)
            preBuffer.append(contentsOf: samples)
            if preBuffer.count > maxPreBufferSamples {
                preBuffer.removeFirst(preBuffer.count - maxPreBufferSamples)
            }
        }
    }

    // MARK: - Transcription & Matching

    private func transcribeAndCheck(_ samples: [Float]) async {
        guard whisperReady, let whisper = whisperKit else { return }

        // Resample to 16kHz
        let targetSampleRate: Double = 16000.0
        let resampled: [Float]
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
            let ratio = targetSampleRate / inputSampleRate
            let outputLength = Int(Double(samples.count) * ratio)
            var buf = [Float](repeating: 0, count: outputLength)
            for i in 0..<outputLength {
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx + 1 < samples.count {
                    buf[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
                } else if idx < samples.count {
                    buf[i] = samples[idx]
                }
            }
            resampled = buf
        } else {
            resampled = samples
        }

        let durationSec = Double(resampled.count) / targetSampleRate
        debugLog("[WakeWord] Transcribing \(String(format: "%.1f", durationSec))s...")

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "zh",
                temperature: 0.0,
                sampleLength: 224
            )
            let results = try await whisper.transcribe(audioArray: resampled, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            // Filter out Whisper hallucinations
            guard !isHallucination(text) else {
                return
            }

            debugLog("[WakeWord] 👂 唤醒词检测: '\(text)' (不会发送)")

            if matchesWakeWord(text) {
                debugLog("[WakeWord] 🎯 Wake word detected!")
                // Temporarily stop detecting — ChatManager will pause/resume
                stopDetecting()
                onWakeWordDetected?()
            }
        } catch {
            debugLog("[WakeWord] Transcription error: \(error)")
        }
    }

    private func matchesWakeWord(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "！", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        for word in wakeWords {
            if normalized.contains(word.lowercased()) {
                return true
            }
        }
        return false
    }
    
    /// Detect common Whisper hallucination patterns (generated from silence/noise)
    private func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty
        if t.isEmpty { return true }
        
        // Common hallucination patterns
        let patterns = [
            "字幕", "订阅", "点赞", "转发", "打赏", "感谢", "谢谢观看",
            "明镜", "栏目", "支持", "频道",
            "(笑)", "(拍)", "(music)", "♪",
            "字幕:j", "chong", "字幕by",
            "please subscribe", "thank you", "like and subscribe"
        ]
        let lower = t.lowercased()
        for pattern in patterns {
            if lower.contains(pattern.lowercased()) {
                return true
            }
        }
        
        // Mostly punctuation or brackets
        let stripped = t.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= 1 { return true }
        
        return false
    }
}
