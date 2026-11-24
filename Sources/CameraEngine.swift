import SwiftUI
import VLCKitSPM

/// Owns the VLC media player, connects to the camera's RTSP stream,
/// and grabs the sharpest of several snapshots as a still image.
@MainActor
final class CameraEngine: ObservableObject {
    let player = VLCMediaPlayer()

    @Published var status = "Idle"
    @Published var isScanning = false
    @Published var capturedImage: UIImage?

    // MARK: - Streaming

    func connect(urlString: String) {
        guard let url = URL(string: urlString), url.host != nil else {
            status = "Invalid RTSP URL"
            return
        }
        let media = VLCMedia(url: url)
        // Low latency + force RTSP over TCP (more reliable than UDP on WiFi).
        media.addOption(":network-caching=300")
        media.addOption(":rtsp-tcp")
        player.media = media
        player.play()
        status = "Connecting to \(url.host ?? "camera")…"
    }

    func stop() {
        player.stop()
        status = "Stopped"
    }

    // MARK: - Discovery

    func findCamera(onFound: @escaping (String) -> Void) {
        isScanning = true
        status = "Scanning the network for a camera…"
        CameraDiscovery.scanForRTSP { [weak self] results in
            Task { @MainActor in
                guard let self else { return }
                self.isScanning = false
                if let ip = results.first {
                    self.status = "Found camera at \(ip)"
                    onFound(ip)
                } else {
                    self.status = "No camera found on this network."
                }
            }
        }
    }

    // MARK: - Frame capture (best of N)

    /// Grabs `count` snapshots a quarter-second apart and keeps the one whose
    /// PNG is largest — blurry frames compress smaller, so this favors the
    /// sharpest frame. Good enough until Stage 3 adds a real sharpness metric.
    func grabBestFrame(count: Int = 5) {
        guard player.isPlaying else {
            status = "Connect to the camera first."
            return
        }
        status = "Grabbing \(count) frames…"
        let dir = FileManager.default.temporaryDirectory
        var paths: [String] = []
        for i in 0..<count {
            let path = dir.appendingPathComponent("walle_shot_\(i).png").path
            paths.append(path)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { [weak self] in
                self?.player.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 0.25 + 0.7) { [weak self] in
            guard let self else { return }
            let best = paths.compactMap { path -> (String, Int)? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int, size > 0 else { return nil }
                return (path, size)
            }.max(by: { $0.1 < $1.1 })

            if let path = best?.0, let image = UIImage(contentsOfFile: path) {
                self.capturedImage = image
                self.status = "Captured sharpest of \(count) frames."
            } else {
                self.status = "No frame captured — is the video actually playing?"
            }
            // tidy up
            for p in paths { try? FileManager.default.removeItem(atPath: p) }
        }
    }
}
