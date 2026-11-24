import SwiftUI
import VLCKitSPM

/// A SwiftUI wrapper around a plain UIView that VLC renders video into.
struct VLCPlayerView: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // VLC keeps rendering into the same drawable; nothing to update here.
    }
}
