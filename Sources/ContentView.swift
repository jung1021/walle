import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var brain = Brain()
    @StateObject private var speaker = Speaker()
    @StateObject private var wakeWord = WakeWord()

    @AppStorage("claude_api_key") private var apiKey = ""
    @AppStorage("claude_model") private var model = "claude-sonnet-5-5"

    @State private var urlString = "rtsp://172.20.10.2:554/"
    @State private var showSettings = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func elapsed(since start: Date?) -> String {
        guard let start else { return "—" }
        let t = max(0, Int(now.timeIntervalSince(start)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    private let prompt = """
    You are Wall-E, a small robot assistant. The image is exactly what your \
    camera sees right now. If it contains a problem to solve — a math problem, \
    puzzle, question, or similar — solve it and state the answer clearly and \
    briefly, suitable to be read aloud. If there is no problem to solve in the \
    image, reply with exactly: "There is no problem to solve." Keep it short.
    """

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Wall-E · Stage 5 — hands-free")
                    .font(.headline)

                ZStack {
                    Color.black
                    VLCPlayerView(player: engine.player)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // The main control: start/stop always-listening.
                Button {
                    if wakeWord.isListening { wakeWord.stop() }
                    else { wakeWord.start() }
                } label: {
                    Label(wakeWord.isListening ? "Stop listening" : "Start listening",
                          systemImage: wakeWord.isListening ? "ear.trianglebadge.exclamationmark" : "ear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(wakeWord.isListening ? .red : .accentColor)

                HStack(spacing: 16) {
                    Label(elapsed(since: wakeWord.listeningSince), systemImage: "ear")
                    Label(elapsed(since: engine.connectedSince), systemImage: "video")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text(wakeWord.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !wakeWord.lastHeard.isEmpty {
                    Text("heard: \(wakeWord.lastHeard)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Divider()

                HStack {
                    TextField("rtsp://…", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    Button("Connect") { engine.connect(urlString: urlString) }
                        .buttonStyle(.borderedProminent)
                }

                HStack {
                    Button {
                        engine.findCamera { urlString = "rtsp://\($0):554/" }
                    } label: {
                        if engine.isScanning { ProgressView() }
                        else { Label("Find", systemImage: "wifi") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isScanning)

                    Button { engine.grabBestFrame() } label: {
                        Label("Grab", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            if let image = engine.capturedImage {
                                await brain.solve(image: image, apiKey: apiKey, model: model, prompt: prompt)
                                let say = brain.answer.isEmpty ? (brain.error ?? "") : brain.answer
                                speaker.speak(say)
                            }
                        }
                    } label: {
                        if brain.isThinking { ProgressView() }
                        else { Label("Ask", systemImage: "brain") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.capturedImage == nil || brain.isThinking || apiKey.isEmpty)
                }

                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !brain.answer.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wall-E says").font(.caption2).foregroundStyle(.tertiary)
                        Text(brain.answer).font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let err = brain.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                DisclosureGroup("Settings — Claude API key", isExpanded: $showSettings) {
                    VStack(spacing: 8) {
                        SecureField("Claude API key (sk-ant-…)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        TextField("Model", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Text("Stored only on this phone. Sent only to Anthropic's API.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline)

                Spacer(minLength: 20)
            }
            .padding()
        }
        .onReceive(ticker) { now = $0 }
        .onAppear {
            // The hands-free loop: wake → grab → ask Claude → speak → listen again.
            wakeWord.onWake = { [weak wakeWord, weak engine, weak brain, weak speaker] in
                Task { @MainActor in
                    guard let wakeWord, let engine, let brain, let speaker else { return }
                    // Whatever happens below — capture failure, API error, stuck
                    // speech — listening ALWAYS comes back.
                    defer { wakeWord.resume() }

                    // If the stream stalled (e.g. screen was off), re-establish it.
                    await engine.ensurePlaying()
                    guard let image = await engine.captureBestFrame() else {
                        await speaker.speakAndWait("I can't see the camera right now.")
                        return
                    }
                    let key = UserDefaults.standard.string(forKey: "claude_api_key") ?? ""
                    let mdl = UserDefaults.standard.string(forKey: "claude_model") ?? "claude-sonnet-5-5"
                    await brain.solve(image: image, apiKey: key, model: mdl, prompt: prompt)

                    // Speak the answer, or a SHORT spoken error (full detail stays
                    // on screen in brain.error). Never read the raw API response aloud.
                    let say = brain.answer.isEmpty
                        ? "Sorry, I couldn't get an answer that time. Try again."
                        : brain.answer
                    await speaker.speakAndWait(say)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
