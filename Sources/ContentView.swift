import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var brain = Brain()
    @StateObject private var speaker = Speaker()
    @StateObject private var wakeWord = WakeWord()
    @StateObject private var autoSolver = AutoSolver()

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("claude_api_key") private var apiKey = ""
    @AppStorage("claude_model") private var model = "claude-sonnet-5-5"
    @AppStorage("auto_scan_interval") private var scanInterval = 15.0

    @State private var urlString = "rtsp://172.20.10.2:554/"
    @State private var showSettings = false
    @State private var now = Date()
    @FocusState private var urlFocused: Bool

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Light tap feedback + dismiss the keyboard, so buttons feel responsive.
    private func tapFeedback() {
        urlFocused = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

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
                Text("Wall-E · auto-solve")
                    .font(.headline)

                if autoSolver.active {
                    Label("Auto-solving", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                    Text(autoSolver.statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ZStack {
                    Color.black
                    VLCPlayerView(player: engine.player)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // The main control: start/stop always-listening.
                Button {
                    tapFeedback()
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
                    Label("\(engine.captureCount)", systemImage: "camera")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Text(wakeWord.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if wakeWord.isListening {
                    // Live proof the mic is hearing something, and which mic it is.
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                        ProgressView(value: wakeWord.micLevel)
                            .frame(width: 110)
                        Text(wakeWord.micName).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
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
                        .focused($urlFocused)
                    Button("Connect") { tapFeedback(); engine.connect(urlString: urlString) }
                        .buttonStyle(.borderedProminent)
                }

                HStack {
                    Button {
                        tapFeedback()
                        engine.findCamera { urlString = "rtsp://\($0):554/" }
                    } label: {
                        if engine.isScanning {
                            HStack(spacing: 6) { ProgressView(); Text("Searching…") }
                        } else {
                            Label("Find", systemImage: "wifi")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isScanning)

                    Button {
                        tapFeedback()
                        engine.grabBestFrame()
                    } label: {
                        if engine.isCapturing { ProgressView() }
                        else { Label("Grab", systemImage: "camera") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.isCapturing)

                    Button {
                        tapFeedback()
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

                DisclosureGroup("Settings", isExpanded: $showSettings) {
                    VStack(spacing: 8) {
                        SecureField("Claude API key (sk-ant-…)", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        TextField("Model", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Stepper("Auto-solve: capture every \(Int(scanInterval))s",
                                value: $scanInterval, in: 2...120, step: 1)
                            .font(.callout)
                        Text("Stored only on this phone. Key is sent only to Anthropic's API.")
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
        .onChange(of: scanInterval) { _ in autoSolver.reloadInterval() }
        .onChange(of: scenePhase) { phase in
            // Returning to the foreground (e.g. after an unlock) — restore the
            // camera stream and listening without the user having to tap anything.
            guard phase == .active else { return }
            Task { @MainActor in
                if engine.connectedSince != nil { await engine.ensurePlaying() }
                if wakeWord.isListening { wakeWord.resume() }
            }
        }
        .onAppear {
            autoSolver.configure(engine: engine, brain: brain, speaker: speaker,
                                 wakeWord: wakeWord, prompt: prompt)
            // "Wall-E, solve this / let's do this" starts auto-solve; "Wall-E, stop" ends it.
            wakeWord.onCommand = { [weak autoSolver] command in
                switch command {
                case .solve: autoSolver?.handleSolve()
                case .stop:  autoSolver?.handleStop()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
