import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ForumImageAnimation: Sendable {
    let bytes: Data
    let mime: String

    static func format(of source: CGImageSource, maxEdge: Int) -> String? {
        let frameCount = CGImageSourceGetCount(source)
        guard (2...240).contains(frameCount),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...maxEdge).contains(width), (1...maxEdge).contains(height),
              width * height * frameCount <= 50_000_000 else { return nil }
        // Flutter's image decoder animates these formats without rebuilding
        // their frames in ImageIO, preserving timing and disposal behavior.
        switch type {
        case UTType.gif.identifier: return "image/gif"
        case UTType.webP.identifier: return "image/webp"
        default: return nil
        }
    }
}
