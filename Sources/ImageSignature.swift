import UIKit

/// Tiny grayscale fingerprint of a frame, used to tell when the camera view has
/// changed (robot moved to a new problem) and when it has settled (stopped).
enum ImageSignature {
    static func make(_ image: UIImage, size: Int = 24) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        var data = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(data: &data, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size,
                                  space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return data
    }

    /// Mean absolute per-pixel difference, normalized to 0…1 (0 = identical).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }
}
