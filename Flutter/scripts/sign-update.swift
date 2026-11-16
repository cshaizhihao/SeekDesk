import CryptoKit
import Foundation

enum SigningError: Error {
    case invalidKey
    case keyMismatch
}

let arguments = CommandLine.arguments
guard arguments.count == 8 else {
    fatalError("Expected key file, public key, archive, version, build, minimum macOS and output.")
}
let keyFile = URL(fileURLWithPath: arguments[1])
let encodedKey = try String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let rawKey = Data(base64Encoded: encodedKey) else { throw SigningError.invalidKey }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[2] else { throw SigningError.keyMismatch }

let archive = URL(fileURLWithPath: arguments[3])
let version = arguments[4], build = arguments[5], minimumOS = arguments[6]
let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
let signature = try key.signature(for: bytes)
guard key.publicKey.isValidSignature(signature, for: bytes) else { throw SigningError.invalidKey }
let link = "https://github.com/cshaizhihao/SeekDesk/releases/download/v\(version)/\(archive.lastPathComponent)"
let feed = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SeekDesk</title>
    <item>
      <title>SeekDesk V\(version)</title>
      <sparkle:version>\(build)</sparkle:version>
      <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>\(minimumOS)</sparkle:minimumSystemVersion>
      <enclosure url="\(link)" length="\(bytes.count)" type="application/octet-stream" sparkle:edSignature="\(signature.base64EncodedString())"/>
    </item>
  </channel>
</rss>
"""
try feed.write(to: URL(fileURLWithPath: arguments[7]), atomically: true, encoding: .utf8)
