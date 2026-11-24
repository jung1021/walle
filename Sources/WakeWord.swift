import Foundation
import Speech
import AVFoundation

/// Always-listening wake-phrase detector built on Apple's on-device speech
/// recognition. Transcribes continuously and fires `onWake` when it hears a
/// phrase like "Wall-E, solve this". On-device sessions time out after ~1 min,
/// so it restarts itself on a timer and whenever a task ends.
@MainActor
final class WakeWord: ObservableObject {
    @Published var isListening = false
    @Published var status = "Wake word off"
    @Published var lastHeard = ""

    /// Called on the main actor each time the wake phrase is heard.
    var onWake: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var paused = false
    private var restartTimer: Timer?

    // MARK: - Public control

    func start() {
        requestPermissions { [weak self] granted in
            guard let self else { return }
            if granted {
                self.isListening = true
                self.beginSession()
            } else {
                self.status = "Microphone or speech permission was denied."
            }
        }
    }

    func stop() {
        isListening = false
        paused = false
        restartTimer?.invalidate(); restartTimer = nil
        teardownSession()
        status = "Wake word off"
    }

    /// Pause while Wall-E is speaking so it doesn't transcribe its own voice.
    func pause() {
        paused = true
        teardownSession()
    }

    func resume() {
        guard isListening else { return }
        paused = false
        beginSession()
    }

    // MARK: - Permissions

    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                DispatchQueue.main.async { completion(auth == .authorized && micOK) }
            }
        }
    }

    // MARK: - Recognition session

    private func beginSession() {
        guard isListening, !paused else { return }
        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognizer is unavailable."
            return
        }
        teardownSession()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            status = "Audio session error: \(error.localizedDescription)"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            status = "Microphone error: \(error.localizedDescription)"
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.handleTranscript(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    if self.isListening && !self.paused { self.beginSession() }
                }
            }
        }

        status = "Listening — say “Wall-E, solve this.”"

        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, !self.paused else { return }
                self.beginSession()
            }
        }
    }

    private func handleTranscript(_ text: String) {
        lastHeard = text
        let norm = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let hasWall = norm.contains("wall") || norm.contains("wally") || norm.contains("walle")
        if hasWall && norm.contains("solve this") {
            // Pause so the timer/task-end doesn't restart mid-loop, then fire once.
            paused = true
            teardownSession()
            onWake?()
        }
    }

    private func teardownSession() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
    }
}
