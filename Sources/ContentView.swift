import SwiftUI

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var urlString = "rtsp://172.20.10.2:554/"

    var body: some View {
        VStack(spacing: 12) {
            Text("Wall-E · Stage 2 — the eye")
                .font(.headline)

            ZStack {
                Color.black
                VLCPlayerView(player: engine.player)
            }
            .frame(height: 220)
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
                    engine.findCamera { ip in urlString = "rtsp://\(ip):554/" }
                } label: {
                    if engine.isScanning {
                        ProgressView()
                    } else {
                        Label("Find camera", systemImage: "wifi")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(engine.isScanning)

                Button {
                    engine.grabBestFrame()
                } label: {
                    Label("Grab frame", systemImage: "camera")
                }
                .buttonStyle(.bordered)
            }

            Text(engine.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let image = engine.capturedImage {
                Text("Captured frame").font(.caption2).foregroundStyle(.tertiary)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
