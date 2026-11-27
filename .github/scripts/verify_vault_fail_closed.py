#!/usr/bin/env python3
"""Fail-closed release gate for the encrypted local vault.

The production release workflow copies source files from the private repository
before building. This gate must run after that copy so an older private/main
revision cannot silently reintroduce replacement-key creation during decrypt.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys


REQUIRED_SOURCE_MARKERS = (
    "Future<SecretKey> _localKey({required bool createIfMissing})",
    "if (!createIfMissing)",
    "refusing to replace the key",
    "secretKey: await _localKey(createIfMissing: true)",
    "secretKey: await _localKey(createIfMissing: false)",
)

REQUIRED_VAULT_TEST_MARKERS = (
    "decrypting with a missing local key fails without creating a replacement",
    "malformed local key is rejected and never overwritten",
    "expect(missingKeys.value, isNull)",
)

REQUIRED_PROFILE_STORE_TEST_MARKERS = (
    "missing vault key preserves encrypted profiles without replacement",
    "expect(await restoredStore.debugStoredValue(), encryptedBefore)",
    "expect(missingKeys.value, isNull)",
)


def verify_repository(root: Path) -> list[str]:
    errors: list[str] = []
    files = {
        "vault": root / "lib/security/encrypted_vault.dart",
        "vault_test": root / "test/security/encrypted_vault_test.dart",
        "profile_test": root / "test/security/encrypted_profile_store_test.dart",
    }
    contents: dict[str, str] = {}
    for name, path in files.items():
        if not path.is_file():
            errors.append(f"Required vault gate file is missing: {path.relative_to(root)}")
            continue
        contents[name] = path.read_text(encoding="utf-8")

    for name, markers in (
        ("vault", REQUIRED_SOURCE_MARKERS),
        ("vault_test", REQUIRED_VAULT_TEST_MARKERS),
        ("profile_test", REQUIRED_PROFILE_STORE_TEST_MARKERS),
    ):
        source = contents.get(name)
        if source is None:
            continue
        for marker in markers:
            if marker not in source:
                errors.append(f"{name} is missing required fail-closed marker: {marker}")

    # Reject legacy calls with implicit create-on-missing behavior. The
    # implementation must explicitly state true for encryption and false
    # for decryption, so a future refactor cannot make intent ambiguous.
    vault_source = contents.get("vault", "")
    if "await _localKey()" in vault_source:
        errors.append("Legacy _localKey() call without createIfMissing policy is forbidden.")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    errors = verify_repository(root)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: fail-closed local vault implementation and regression tests are present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
