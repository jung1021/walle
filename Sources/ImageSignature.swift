import UIKit

/// Small grayscale fingerprint of a frame, used to tell when what the camera
/// sees has changed. The comparison is LOCAL: it looks for any one region that
/// changed a lot, so new text appearing on an otherwise identical screen counts
/// as a change even though the picture as a whole barely moved.
enum ImageSignature {
    static let width = 160
    static let height = 90
    private static let block = 10          // 16 x 9 regions

    static func make(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        var data = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &data, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// 0…1: in the most-changed region, the share of pixels that changed
    /// strongly. Camera noise and small exposure drift stay near 0; text or
    /// objects appearing, disappearing or moving push it up.
    static func changeScore(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == width * height, b.count == a.count else { return 1.0 }

        // Remove overall brightness drift (auto-exposure) before comparing.
        var sumA = 0, sumB = 0
        for i in 0..<a.count { sumA += Int(a[i]); sumB += Int(b[i]) }
        let offset = (sumB - sumA) / a.count

        let strong = 40                     // grey levels; above sensor noise
        var worst = 0.0
        var by = 0
        while by + block <= height {
            var bx = 0
            while bx + block <= width {
                var changed = 0
                for y in by..<(by + block) {
                    let row = y * width
                    for x in bx..<(bx + block) {
                        let d = abs(Int(b[row + x]) - Int(a[row + x]) - offset)
                        if d > strong { changed += 1 }
                    }
                }
                worst = max(worst, Double(changed) / Double(block * block))
                bx += block
            }
            by += block
        }
        return worst
    }
}
