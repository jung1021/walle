import AVFoundation

/// Speaks text aloud, routed to a connected Bluetooth speaker when present,
/// and calls an optional completion when it finishes (used to resume listening).
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion?(); return }
        onFinish = completion
        activateSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .spokenAudio,
                                    options: [.allowBluetoothA2DP, .allowAirPlay, .duckOthers])
            try session.setActive(true)
        } catch {
            // Fall through — the synthesizer will still try the default route.
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let finish = self.onFinish
            self.onFinish = nil
            finish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let finish = self.onFinish
            self.onFinish = nil
            finish?()
        }
    }
}
