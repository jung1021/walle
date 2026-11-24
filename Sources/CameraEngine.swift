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
    @Published var connectedSince: Date?
    @Published var captureCount = 0

    private(set) var lastURL: String?

    // MARK: - Streaming

    func connect(urlString: String) {
        guard let url = URL(string: urlString), url.host != nil else {
            status = "Invalid RTSP URL"
            return
        }
        lastURL = urlString
        let media = VLCMedia(url: url)
        // Low latency + force RTSP over TCP (more reliable than UDP on WiFi).
        media.addOption(":network-caching=300")
        media.addOption(":rtsp-tcp")
        media.addOption(":no-audio")   // don't play the camera's mic into our speech recognizer
        player.media = media
        player.play()
        if connectedSince == nil { connectedSince = Date() }
        status = "Connecting to \(url.host ?? "camera")…"
    }

    func stop() {
        player.stop()
        connectedSince = nil
        status = "Stopped"
    }

    /// If the stream stalled (e.g. the app was backgrounded with the screen off),
    /// re-establish it before we try to grab a frame. Waits up to ~3s for video.
    func ensurePlaying() async {
        if player.isPlaying { return }
        guard let url = lastURL else { return }
        connect(urlString: url)
        for _ in 0..<12 {
            if player.isPlaying { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
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

    /// Button entry point — captures and updates `capturedImage`.
    func grabBestFrame(count: Int = 5) {
        Task { _ = await captureBestFrame(count: count) }
    }

    /// One quick, small snapshot — used by the auto-solver's scene-change scan.
    func captureSingleFrame() async -> UIImage? {
        guard player.isPlaying else { return nil }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("walle_scan.png").path
        player.saveVideoSnapshot(at: path, withWidth: 320, andHeight: 0)
        captureCount += 1
        try? await Task.sleep(nanoseconds: 300_000_000)
        let image = UIImage(contentsOfFile: path)
        try? FileManager.default.removeItem(atPath: path)
        return image
    }

    /// Grabs `count` snapshots a quarter-second apart and keeps the one whose
    /// PNG is largest — blurry frames compress smaller, so this favors the
    /// sharpest frame. Returns the chosen image (and sets `capturedImage`).
    @discardableResult
    func captureBestFrame(count: Int = 5) async -> UIImage? {
        guard player.isPlaying else {
            status = "Connect to the camera first."
            return nil
        }
        status = "Grabbing \(count) frames…"
        captureCount += 1
        let dir = FileManager.default.temporaryDirectory
        var paths: [String] = []
        for i in 0..<count {
            let path = dir.appendingPathComponent("walle_shot_\(i).png").path
            paths.append(path)
            player.saveVideoSnapshot(at: path, withWidth: 0, andHeight: 0)
            try? await Task.sleep(nanoseconds: 250_000_000)   // 0.25s
        }
        try? await Task.sleep(nanoseconds: 400_000_000)       // let the last write finish

        let best = paths.compactMap { path -> (String, Int)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size > 0 else { return nil }
            return (path, size)
        }.max(by: { $0.1 < $1.1 })

        var result: UIImage?
        if let path = best?.0, let image = UIImage(contentsOfFile: path) {
            capturedImage = image
            result = image
            status = "Captured sharpest of \(count) frames."
        } else {
            status = "No frame captured — is the video actually playing?"
        }
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        return result
    }
}
