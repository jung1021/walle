import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var brain = Brain()

    // Stored on this phone only (UserDefaults). Not in the repo.
    @AppStorage("claude_api_key") private var apiKey = ""
    @AppStorage("claude_model") private var model = "claude-sonnet-5-5"

    @State private var urlString = "rtsp://172.20.10.2:554/"
    @State private var showSettings = false

    private let prompt = """
    You are Wall-E, a small robot. This image is what your camera sees. \
    If it shows a question, puzzle, or problem, solve it and give the answer \
    clearly and briefly. Otherwise, briefly say what you see. Keep it short \
    enough to read aloud.
    """

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Wall-E · Stage 3 — the brain")
                    .font(.headline)

                ZStack {
                    Color.black
                    VLCPlayerView(player: engine.player)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))

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

                    Button {
                        engine.grabBestFrame()
                    } label: {
                        Label("Grab", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let image = engine.capturedImage {
                            Task { await brain.solve(image: image, apiKey: apiKey, model: model, prompt: prompt) }
                        }
                    } label: {
                        if brain.isThinking { ProgressView() }
                        else { Label("Ask Claude", systemImage: "brain") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.capturedImage == nil || brain.isThinking || apiKey.isEmpty)
                }

                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let image = engine.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

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
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
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
    }
}

#Preview {
    ContentView()
}
