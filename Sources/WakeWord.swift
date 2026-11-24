import Foundation
import Speech
import AVFoundation

/// Always-listening wake-phrase detector built on Apple's on-device speech
/// recognition. Transcribes continuously and fires `onWake` when it hears a
/// phrase like "Wall-E, solve this".
///
/// Robustness: a health timer re-arms the recognizer within a few seconds of
/// ANY failure (task ending, mic/session error, a stalled restart), so the app
/// can never go permanently deaf while listening is on.
@MainActor
final class WakeWord: ObservableObject {
    @Published var isListening = false
    @Published var status = "Wake word off"
    @Published var lastHeard = ""
    @Published var listeningSince: Date?

    /// Called on the main actor each time the wake phrase is heard.
    var onWake: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var paused = false
    private var healthTimer: Timer?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// A phone call or other audio interruption stops our engine; when it ends,
    /// re-arm listening so it doesn't stay dead.
    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        Task { @MainActor in
            if self.isListening && !self.paused { self.beginSession() }
        }
    }

    // MARK: - Public control

    func start() {
        requestPermissions { [weak self] granted in
            guard let self else { return }
            if granted {
                self.isListening = true
                self.listeningSince = Date()
                self.startHealthTimer()
                self.beginSession()
            } else {
                self.status = "Microphone or speech permission was denied."
            }
        }
    }

    func stop() {
        isListening = false
        paused = false
        listeningSince = nil
        healthTimer?.invalidate(); healthTimer = nil
        teardownSession()
        status = "Wake word off"
    }

    /// Pause while Wall-E is speaking so it doesn't transcribe its own voice.
    func pause() {
        paused = true
        teardownSession()
    }

    /// Resume after the loop finishes. Even if this call fails to start cleanly,
    /// the health timer will re-arm the recognizer within a few seconds.
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

    // MARK: - Self-healing

    /// Every few seconds, if we should be listening but the recognizer isn't
    /// actually running, restart it. This recovers from every failure path.
    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, !self.paused else { return }
                if self.task == nil || !self.audioEngine.isRunning {
                    self.beginSession()
                }
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
            status = "Audio session error — retrying…"
            return   // health timer will retry shortly
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
            status = "Microphone error — retrying…"
            return   // health timer will retry shortly
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.handleTranscript(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    // Drop the finished task so the health timer (or this) re-arms it.
                    self.task = nil
                    if self.isListening && !self.paused { self.beginSession() }
                }
            }
        }

        status = "Listening — say “Wall-E, solve this.”"
    }

    private func handleTranscript(_ text: String) {
        lastHeard = text
        let norm = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let hasWall = norm.contains("wall") || norm.contains("wally") || norm.contains("walle")
        if hasWall && norm.contains("solve this") {
            // Pause so nothing restarts mid-loop, then fire once.
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
