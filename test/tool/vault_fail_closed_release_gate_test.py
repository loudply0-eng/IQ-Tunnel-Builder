import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / ".github" / "scripts" / "verify_vault_fail_closed.py"

VAULT_MARKERS = (
    "Future<SecretKey> _localKey({required bool createIfMissing})",
    "if (!createIfMissing)",
    "refusing to replace the key",
    "secretKey: await _localKey(createIfMissing: true)",
    "secretKey: await _localKey(createIfMissing: false)",
)

VAULT_TEST_MARKERS = (
    "decrypting with a missing local key fails without creating a replacement",
    "malformed local key is rejected and never overwritten",
    "expect(missingKeys.value, isNull)",
)

PROFILE_TEST_MARKERS = (
    "missing vault key preserves encrypted profiles without replacement",
    "expect(await restoredStore.debugStoredValue(), encryptedBefore)",
    "expect(missingKeys.value, isNull)",
)


class VaultFailClosedReleaseGateTests(unittest.TestCase):
    def make_repo(self, root: Path) -> None:
        files = (
            ("lib/security/encrypted_vault.dart", VAULT_MARKERS),
            ("test/security/encrypted_vault_test.dart", VAULT_TEST_MARKERS),
            ("test/security/encrypted_profile_store_test.dart", PROFILE_TEST_MARKERS),
        )
        for relative, markers in files:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(markers), encoding="utf-8")

    def run_gate(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(GATE), "--root", str(root)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_accepts_explicit_fail_closed_vault_and_regression_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root)
            result = self.run_gate(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS:", result.stdout)

    def test_rejects_decrypt_path_that_can_create_a_replacement_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root)
            vault = root / "lib/security/encrypted_vault.dart"
            vault.write_text(
                vault.read_text(encoding="utf-8").replace(
                    "secretKey: await _localKey(createIfMissing: false)",
                    "secretKey: await _localKey()",
                ),
                encoding="utf-8",
            )
            result = self.run_gate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Legacy _localKey()", result.stderr)

    def test_rejects_missing_profile_store_key_loss_regression_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_repo(root)
            profile_test = root / "test/security/encrypted_profile_store_test.dart"
            profile_test.write_text(
                profile_test.read_text(encoding="utf-8").replace(
                    "missing vault key preserves encrypted profiles without replacement",
                    "unrelated profile test",
                ),
                encoding="utf-8",
            )
            result = self.run_gate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing vault key preserves encrypted profiles", result.stderr)

    def test_rejects_missing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_gate(Path(directory))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Required vault gate file is missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
