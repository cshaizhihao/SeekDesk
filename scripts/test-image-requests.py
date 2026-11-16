#!/usr/bin/env python3
"""Exercise the production image pipeline with a delayed local-file transport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/SeekDesk/ForumImageView.swift").read_text()
request = "enum ForumImageRequest {" + source.split("enum ForumImageRequest {", 1)[1]
needle = "static func decode(_ file: URL, kind: Kind = .post) throws -> Decoded {"
assert request.count(needle) == 1
request = request.replace(needle, needle + " ImageRequestProbe.shared.decoding()")
decode = "private static func decodeBitmap(_ temporary: TemporaryImageFile, kind: Kind, svgAvatar: Bool) async throws -> Bitmap {"
assert request.count(decode) == 1
request = request.replace(decode, decode + " DecodeRequestProbe.shared.begin(temporary.url); defer { DecodeRequestProbe.shared.finish() }")
with tempfile.TemporaryDirectory(prefix="seekdesk-image-requests-") as directory:
    directory = Path(directory)
    extracted = directory / "ProductionImageRequest.swift"
    extracted.write_text("import AppKit\nimport ImageIO\n" + request)
    executable = directory / "ImageRequestChecks"
    cache = root / ".build/module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    coordinator = root / "Sources/SeekDesk/ImageRequestCoordinator.swift"
    # Check the independent scheduler under Swift 6's strict sendability rules too.
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(cache),
                    "-emit-module", str(coordinator), "-o", str(directory / "Scheduler.swiftmodule")], check=True)
    subprocess.run(["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(cache),
                    str(coordinator), str(extracted), str(root / "Sources/SeekDesk/ForumImageAnimation.swift"),
                    str(root / "Tests/ImageRequests/TransportFixture.swift"),
                    str(root / "Tests/ImageRequests/RequestChecks.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
