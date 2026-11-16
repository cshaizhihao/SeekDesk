#!/usr/bin/env python3
"""Verify a build, resealing only the proven local ad-hoc incremental case.

Flutter embeds and signs App.framework after a Dart-only rebuild, but Xcode can
skip the enclosing app's CodeSign task. Never repair nested code or a certificate
signature: this helper only refreshes that stale outer resource seal.
"""

import pathlib
import plistlib
import hashlib
import os
import subprocess
import sys


class SignatureError(RuntimeError):
    pass


def command(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


def checked(arguments):
    result = command(arguments)
    if result.returncode:
        raise SignatureError(result.stderr.strip() or result.stdout.strip())
    return result


def nested_code(app):
    contents = app / "Contents"
    with (contents / "_CodeSignature/CodeResources").open("rb") as stream:
        seal = plistlib.load(stream)
    paths = {
        contents / name
        for name, entry in seal.get("files2", {}).items()
        if isinstance(entry, dict) and ("cdhash" in entry or "requirement" in entry)
    }
    # Include newly embedded code as well as all previously sealed nested code.
    for folder in ("Frameworks", "Helpers", "PlugIns", "XPCServices",
                   "Library/LoginItems", "Library/LaunchServices"):
        directory = contents / folder
        if directory.exists():
            paths.update(directory.iterdir())
    if contents / "Frameworks/App.framework" not in paths:
        raise SignatureError("Expected embedded App.framework is missing.")
    for path in paths:
        if not path.exists() or not path.resolve().is_relative_to(contents.resolve()):
            raise SignatureError(f"Missing or external nested code: {path}")
    return sorted(paths), seal


def verify_resources(app, seal, nested, executable):
    """Check every sealed ordinary file/link, not just codesign's first error."""
    contents = app / "Contents"
    sealed = set()
    for section in ("files", "files2"):
        for name, entry in seal.get(section, {}).items():
            relative = pathlib.PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise SignatureError(f"Unsafe resource seal path: {name}")
            path = contents / name
            sealed.add(path)
            entry = {"hash": entry} if isinstance(entry, bytes) else entry
            if not isinstance(entry, dict):
                raise SignatureError(f"Unknown resource seal: {name}")
            if "cdhash" in entry or "requirement" in entry:
                continue
            if "symlink" in entry:
                if not path.is_symlink() or os.readlink(path) != entry["symlink"]:
                    raise SignatureError(f"Changed resource link: {name}")
                continue
            if not path.is_file() or path.is_symlink():
                raise SignatureError(f"Missing or replaced resource: {name}")
            data = path.read_bytes()
            for key, algorithm in (("hash", hashlib.sha1), ("hash2", hashlib.sha256)):
                if key in entry and algorithm(data).digest() != entry[key]:
                    raise SignatureError(f"Changed sealed resource: {name}")
            if "hash" not in entry and "hash2" not in entry:
                raise SignatureError(f"Unsupported resource seal: {name}")

    # Be stricter than optional/omission rules during repair: unexpected extras
    # must go back through a normal Xcode build, rather than be newly sealed.
    special = {contents / "Info.plist", contents / "PkgInfo", contents / "MacOS" / executable}
    nested_set = set(nested)
    for directory, subdirectories, files in os.walk(contents, followlinks=False):
        current = pathlib.Path(directory)
        for name in list(subdirectories):
            path = current / name
            if path in nested_set or path == contents / "_CodeSignature":
                subdirectories.remove(name)
            elif path.is_symlink():
                subdirectories.remove(name)
                files.append(name)
        for name in files:
            path = current / name
            if path not in sealed and path not in special and path not in nested_set:
                raise SignatureError(f"Unexpected unsealed file: {path.relative_to(contents)}")


def verify(app, expected_identifier):
    app = pathlib.Path(app).absolute()
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise SignatureError("Expected a regular local application bundle.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != expected_identifier:
        raise SignatureError("The built application does not match the requested bundle identity.")

    verification = command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)])
    if verification.returncode == 0:
        return "Bundle signature verified."

    # Refuse every other failure instead of hiding a damaged resource or code
    # signature behind a broad force/deep signing operation.
    modified = f"file modified: {app}/Contents/Frameworks/App.framework"
    expected_error = f"{app}: nested code is modified or invalid"
    # codesign sends detailed modified-file paths to stdout, diagnostics to stderr.
    lines = (verification.stdout + verification.stderr).splitlines()
    if modified not in lines or expected_error not in lines or any(
        line and line not in (modified, expected_error)
        and not line.startswith(("--prepared:", "--validated:"))
        for line in lines
    ):
        raise SignatureError(verification.stderr.strip())

    metadata = checked(["/usr/bin/codesign", "-d", "--verbose=4", str(app)]).stderr.splitlines()
    if "Signature=adhoc" not in metadata or any(line.startswith("Authority=") for line in metadata):
        raise SignatureError("Refusing to replace a non-ad-hoc application signature.")
    if f"Identifier={expected_identifier}" not in metadata:
        raise SignatureError("The existing signing identifier does not match the requested build.")

    # Validate the existing executable before ignoring its stale resource seal.
    checked(["/usr/bin/codesign", "--verify", "--ignore-resources", "--strict", str(app)])
    nested, seal = nested_code(app)
    verify_resources(app, seal, nested, info["CFBundleExecutable"])
    for path in nested:
        checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])
        if path != app / "Contents/Frameworks/App.framework":
            entry = seal.get("files2", {}).get(str(path.relative_to(app / "Contents")), {})
            cdhash = entry.get("cdhash")
            detail = checked(["/usr/bin/codesign", "-d", "--verbose=4", str(path)]).stderr.splitlines()
            if not isinstance(cdhash, bytes) or f"CDHash={cdhash.hex()}" not in detail:
                raise SignatureError(f"Unexpected changed nested signature: {path}")

    checked([
        "/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
        "--preserve-metadata=identifier,entitlements,requirements,flags,runtime",
        "--generate-entitlement-der", str(app),
    ])
    checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    return "Refreshed the local ad-hoc app seal and verified the complete bundle."


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: verify-local-signature.py APPLICATION EXPECTED_BUNDLE_IDENTIFIER")
    try:
        print(verify(sys.argv[1], sys.argv[2]))
    except (SignatureError, OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit(f"Signature verification failed: {error}")
