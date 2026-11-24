import AVFoundation

/// Speaks text aloud, routed to a connected Bluetooth speaker when present.
@MainActor
final class Speaker: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activateSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Playback category + Bluetooth A2DP so the voice goes to the BT speaker.
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
}
