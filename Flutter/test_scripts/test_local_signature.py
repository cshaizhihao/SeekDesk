import hashlib
import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


source = pathlib.Path(__file__).resolve().parents[1] / "scripts/verify-local-signature.py"
spec = importlib.util.spec_from_file_location("local_signature", source)
signatures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signatures)


class LocalSignatureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / "Fixture.app"
        self.contents = self.app / "Contents"
        for folder in ("Resources", "MacOS", "_CodeSignature", "Frameworks/App.framework", "Frameworks/Sparkle.framework"):
            (self.contents / folder).mkdir(parents=True, exist_ok=True)
        self.identifier = "com.seekdesk.flutter-benchmark"
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": self.identifier, "CFBundleExecutable": "Fixture"}))
        (self.contents / "MacOS/Fixture").write_bytes(b"fixture executable")
        (self.contents / "Resources/note.txt").write_bytes(b"original resource")
        (self.contents / "Resources/link").symlink_to("note.txt")
        self.seal = {
            "files": {"Resources/note.txt": hashlib.sha1(b"original resource").digest()},
            "files2": {
                "Resources/note.txt": {"hash2": hashlib.sha256(b"original resource").digest()},
                "Resources/link": {"symlink": "note.txt"},
                "Frameworks/App.framework": {"cdhash": b"old app hash", "requirement": "fixture"},
                "Frameworks/Sparkle.framework": {"cdhash": b"unchanged sparkle hash", "requirement": "fixture"},
            },
        }
        (self.contents / "_CodeSignature/CodeResources").write_bytes(plistlib.dumps(self.seal))
        self.calls = []
        self.already_valid = False
        self.signed = False
        self.certified = False
        self.invalid_nested = False
        self.changed_sparkle = False
        self.invalid_executable = False

    def command(self, args):
        self.calls.append(args)
        result = subprocess.CompletedProcess(args, 0, "", "")
        if "--force" in args:
            self.signed = True
        elif "-d" in args:
            if args[-1] == str(self.app):
                result.stderr = f"Identifier={self.identifier}\n" + ("Signature size=1234\nAuthority=Developer ID\n" if self.certified else "Signature=adhoc\n")
            else:
                cdhash = b"changed" if self.changed_sparkle else b"unchanged sparkle hash"
                result.stderr = f"CDHash={cdhash.hex()}\n"
        elif "--ignore-resources" in args:
            if self.invalid_executable:
                result.returncode = 1
                result.stderr = "invalid executable signature"
        elif args[-1] == str(self.app):
            if not self.already_valid and not self.signed:
                result.returncode = 1
                result.stdout = f"file modified: {self.contents}/Frameworks/App.framework\n"
                result.stderr = f"{self.app}: nested code is modified or invalid\n"
        elif self.invalid_nested:
            result.returncode = 1
            result.stderr = "nested code is invalid"
        return result

    def verify(self):
        with mock.patch.object(signatures, "command", self.command):
            return signatures.verify(self.app, self.identifier)

    def assert_refused(self):
        with self.assertRaises(signatures.SignatureError):
            self.verify()
        self.assertFalse(self.signed)

    def test_valid_signature_is_left_untouched(self):
        self.already_valid = True
        self.verify()
        self.assertFalse(self.signed)

    def test_only_the_outer_adhoc_bundle_is_signed_with_existing_metadata(self):
        self.verify()
        signing = [args for args in self.calls if "--force" in args]
        self.assertEqual(len(signing), 1)
        self.assertEqual(signing[0][-1], str(self.app))
        self.assertNotIn("--deep", signing[0])
        self.assertIn("--preserve-metadata=identifier,entitlements,requirements,flags,runtime", signing[0])
        self.assertEqual(self.calls[-1], ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)])

    def test_certificate_signature_is_never_replaced(self):
        self.certified = True
        self.assert_refused()

    def test_changed_ordinary_resource_cannot_hide_behind_first_nested_error(self):
        (self.contents / "Resources/note.txt").write_bytes(b"changed resource")
        self.assert_refused()

    def test_changed_symlink_is_rejected(self):
        (self.contents / "Resources/link").unlink()
        (self.contents / "Resources/link").symlink_to("other.txt")
        self.assert_refused()

    def test_unsealed_extra_file_is_rejected(self):
        (self.contents / "Resources/extra.txt").write_text("unexpected")
        self.assert_refused()

    def test_invalid_nested_signature_is_rejected(self):
        self.invalid_nested = True
        self.assert_refused()

    def test_even_a_valid_changed_third_party_signature_is_rejected(self):
        self.changed_sparkle = True
        self.assert_refused()

    def test_invalid_outer_executable_is_rejected(self):
        self.invalid_executable = True
        self.assert_refused()

    def test_wrong_bundle_identity_is_rejected_before_codesign(self):
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "other", "CFBundleExecutable": "Fixture"}))
        self.assert_refused()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
