import Foundation
import Speech
import AVFoundation

/// Always-listening wake-phrase detector built on Apple's on-device speech
/// recognition. Transcribes continuously and fires `onCommand` when it hears a
/// phrase like "Wall-E, solve this".
///
/// Robustness: every recognition session has a generation number, so callbacks
/// from an old session can never disturb the current one, and a health timer
/// re-arms the recognizer within a few seconds of any failure — including the
/// microphone going silent.
@MainActor
final class WakeWord: ObservableObject {
    @Published var isListening = false
    @Published var status = "Wake word off"
    @Published var lastHeard = ""
    @Published var listeningSince: Date?
    /// Which microphone iOS is actually recording from (shown for diagnosis).
    @Published var micName = "—"
    /// Live input level 0…1, so you can see whether the mic is hearing anything.
    @Published var micLevel: Double = 0

    enum Command { case solve, stop }

    /// Called on the main actor when a command phrase is heard.
    var onCommand: ((Command) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var paused = false
    private var healthTimer: Timer?

    private var generation = 0
    private var sessionStartedAt = Date.distantPast
    private var lastAudioAt = Date.distantPast

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange),
                       name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Only a device physically appearing/disappearing (e.g. the Bluetooth
    /// speaker) should re-arm the session. Our own category changes also post
    /// route-change notifications, and reacting to those caused a restart loop.
    @objc nonisolated private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        Task { @MainActor in
            guard self.isListening, !self.paused else { return }
            if Date().timeIntervalSince(self.sessionStartedAt) > 1.5 { self.beginSession() }
        }
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
        micLevel = 0
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
    /// running — or the mic has delivered no audio for a while — restart it.
    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, !self.paused else { return }
                let engineDead = self.task == nil || !(self.audioEngine?.isRunning ?? false)
                let sessionAge = Date().timeIntervalSince(self.sessionStartedAt)
                let micSilent = sessionAge > 5 && Date().timeIntervalSince(self.lastAudioAt) > 5
                if engineDead || micSilent { self.beginSession() }
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
        generation += 1
        let gen = generation
        sessionStartedAt = Date()

        let session = AVAudioSession.sharedInstance()
        do {
            // Record-only, and no Bluetooth option: an A2DP speaker has no mic,
            // so letting Bluetooth near the input route breaks recording. Force
            // the phone's own microphone.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(mic)
            }
        } catch {
            status = "Audio session error — retrying…"
            return   // health timer will retry shortly
        }
        micName = session.currentRoute.inputs.first?.portName ?? "no input"

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        // A fresh engine every session: a reused engine keeps the input format
        // from the previous audio route, which goes stale when Bluetooth
        // connects or the category changes, and then delivers no audio.
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "Microphone not ready — retrying…"
            return   // health timer will retry shortly
        }

        var bufferCount = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            bufferCount += 1
            guard bufferCount % 8 == 0 else { return }
            // Peak level of this buffer, for the on-screen mic meter.
            var peak: Float = 0
            if let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var i = 0
                while i < n { peak = max(peak, abs(data[i])); i += 16 }
            }
            let level = Double(min(1, peak * 4))
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.micLevel = level
                self.lastAudioAt = Date()
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Microphone error — retrying…"
            return   // health timer will retry shortly
        }
        lastAudioAt = Date()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                // Ignore callbacks from a session that has since been replaced
                // (cancelling an old task fires its handler with an error).
                guard let self, self.generation == gen else { return }
                if let text { self.handleTranscript(text) }
                if ended {
                    self.task = nil
                    if self.isListening && !self.paused { self.beginSession() }
                }
            }
        }

        status = "Listening — say “Wall-E, let’s do this.”"
    }

    /// Trigger requires the name ("Wall-E", however Apple mishears it) AND any
    /// one of these action phrases — in any order within the same transcript.
    private static let actionPhrases = [
        "solve this", "solve it", "solve the problem",
        "lets do this", "do this", "lets do it",
        "figure this out", "figure it out", "work this out",
        "whats the answer", "answer this", "help me with this", "help with this"
    ]

    private func handleTranscript(_ text: String) {
        lastHeard = text
        let norm = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "'", with: "")   // let's -> lets, what's -> whats
            .replacingOccurrences(of: "’", with: "")
        let hasName = norm.contains("wall")             // wall-e, wally, wallie, wall e …
        guard hasName else { return }

        // "Wall-E, stop" takes priority over a solve phrase.
        if norm.contains("stop") {
            paused = true
            teardownSession()
            onCommand?(.stop)
            return
        }
        let hasAction = WakeWord.actionPhrases.contains { norm.contains($0) }
        if hasAction {
            // Pause so nothing restarts mid-loop, then fire once.
            paused = true
            teardownSession()
            onCommand?(.solve)
        }
    }

    private func teardownSession() {
        generation += 1            // invalidate callbacks from the old session
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
    }
}
