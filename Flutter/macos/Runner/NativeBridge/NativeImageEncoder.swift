import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Flutter bridge needs encoded bytes after the shared image loader has
/// produced a bitmap. Share only in-flight conversions; completed PNGs remain
/// owned by Dart's bounded cache rather than adding another native byte cache.
final class NativeImageEncoder: Sendable {
    struct Codec: Sendable {
        var encode: @Sendable (CGImage) throws -> Data = { try NativeImageEncoder.encodePNG($0) }
    }

    private struct Key: Hashable, Sendable {
        // Keep the bitmap alive for as long as this identity is in the queue or
        // active worker. An ObjectIdentifier alone could be reused after free.
        let image: CGImage
        let kind: ForumImageRequest.Kind
        let owner: Int?
        let revision: Int

        static func == (lhs: Key, rhs: Key) -> Bool {
            ObjectIdentifier(lhs.image) == ObjectIdentifier(rhs.image) &&
            lhs.kind == rhs.kind && lhs.owner == rhs.owner && lhs.revision == rhs.revision
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(image))
            hasher.combine(kind)
            hasher.combine(owner)
            hasher.combine(revision)
        }
    }

    private let codec: Codec
    private let operations = ImageRequestCoordinator<Key, Data>(maximumConcurrent: 2, maximumLargeConcurrent: 1)

    init(codec: Codec = .init()) { self.codec = codec }

    func encode(_ image: CGImage, kind: ForumImageRequest.Kind, owner: Int?, revision: Int) async throws -> Data {
        try Task.checkCancellation()
        let key = Key(image: image, kind: kind, owner: owner, revision: revision)
        let codec = codec
        return try await operations.value(for: key, large: kind == .original) {
            // The coordinator runs this closure on its detached worker. A
            // synchronous ImageIO call retains its slot even after cancellation.
            try Task.checkCancellation()
            let data = try autoreleasepool { try codec.encode(image) }
            try Task.checkCancellation()
            return data
        }
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw URLError(.cannotDecodeContentData)
        }
        CGImageDestinationAddImage(destination, image, nil)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        return output as Data
    }
}
