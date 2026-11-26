#!/usr/bin/env python3
"""Inspect the compiled APK backup policy with Android's AAPT2 binary."""
import argparse
from pathlib import Path
import re
import subprocess

DOMAINS = (
    "root",
    "file",
    "database",
    "sharedpref",
    "external",
    "device_root",
    "device_file",
    "device_database",
    "device_sharedpref",
)


def _values(dump: str, attribute: str) -> list[str]:
    pattern = re.compile(
        rf"\\b{re.escape(attribute)}(?:\\([^)]*\\))?\\s*=\\s*(?:\"([^\"]*)\"|([^\\s]+))"
    )
    return [quoted if quoted is not None else bare for quoted, bare in pattern.findall(dump)]


def _manifest_resource_id(dump: str, attribute: str, resource_name: str, resources: str) -> None:
    lines = [line for line in dump.splitlines() if f"android:{attribute}" in line]
    if len(lines) != 1:
        raise SystemExit(f"APK manifest must contain exactly one android:{attribute} attribute.")
    line = lines[0]
    symbolic = f"@xml/{resource_name}"
    if symbolic in line:
        return
    match = re.search(r"=@(0x[0-9a-fA-F]+)", line)
    if not match:
        raise SystemExit(f"Could not resolve the compiled resource ID for android:{attribute}.")
    resource_id = match.group(1).lower()
    resource_line = next(
        (
            item for item in resources.splitlines()
            if resource_id in item.lower() and f":xml/{resource_name}" in item
        ),
        None,
    )
    if resource_line is None:
        raise SystemExit(
            f"android:{attribute} does not resolve to the packaged xml/{resource_name} resource."
        )


def validate_dumps(manifest: str, legacy: str, extraction: str, resources: str) -> None:
    allow_lines = [line for line in manifest.splitlines() if "android:allowBackup" in line]
    if len(allow_lines) != 1 or not re.search(r"=\\s*(?:\"false\"|false)(?:\\s|$)", allow_lines[0]):
        raise SystemExit("Packaged manifest does not enforce android:allowBackup=false.")

    _manifest_resource_id(manifest, "fullBackupContent", "backup_rules", resources)
    _manifest_resource_id(manifest, "dataExtractionRules", "data_extraction_rules", resources)

    if "E: full-backup-content" not in legacy:
        raise SystemExit("Packaged legacy backup_rules.xml has the wrong root element.")
    legacy_domains = _values(legacy, "domain")
    legacy_paths = _values(legacy, "path")
    if len(legacy_domains) != len(DOMAINS) or set(legacy_domains) != set(DOMAINS):
        raise SystemExit("Packaged legacy backup rules must exclude all nine storage domains exactly once.")
    if legacy_paths.count(".") != len(DOMAINS):
        raise SystemExit("Packaged legacy backup rules must use path='.' for all nine exclusions.")

    for element in ("E: data-extraction-rules", "E: cloud-backup", "E: device-transfer"):
        if element not in extraction:
            raise SystemExit(f"Packaged data extraction rules are missing {element}.")
    extraction_domains = _values(extraction, "domain")
    extraction_paths = _values(extraction, "path")
    if len(extraction_domains) != len(DOMAINS) * 2:
        raise SystemExit("Packaged cloud/D2D rules must contain exactly eighteen domain exclusions.")
    for domain in DOMAINS:
        if extraction_domains.count(domain) != 2:
            raise SystemExit(f"Packaged cloud/D2D rules must exclude {domain} in both sections.")
    if extraction_paths.count(".") != len(DOMAINS) * 2:
        raise SystemExit("Packaged cloud/D2D rules must use path='.' for all exclusions.")


def verify(apk: Path, aapt2: str, evidence_dir: Path) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    files = {
        "manifest": "AndroidManifest.xml",
        "legacy": "res/xml/backup_rules.xml",
        "extraction": "res/xml/data_extraction_rules.xml",
    }
    dumps = {}
    for key, internal_path in files.items():
        result = subprocess.run(
            [aapt2, "dump", "xmltree", str(apk), "--file", internal_path],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        dumps[key] = result.stdout
        (evidence_dir / f"{key}.xmltree.txt").write_text(result.stdout, encoding="utf-8")

    resources_result = subprocess.run(
        [aapt2, "dump", "resources", str(apk)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    (evidence_dir / "resources.txt").write_text(resources_result.stdout, encoding="utf-8")
    validate_dumps(
        dumps["manifest"],
        dumps["legacy"],
        dumps["extraction"],
        resources_result.stdout,
    )
    (evidence_dir / "verification.txt").write_text(
        "PASS: packaged manifest, legacy backup rules, cloud backup, and device transfer "
        "exclude all nine storage domains.\n",
        encoding="utf-8",
    )
    print("AAPT2 verified the packaged Android backup policy.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    args = parser.parse_args()
    if not args.apk.is_file():
        raise SystemExit(f"APK does not exist: {args.apk}")
    verify(args.apk, args.aapt2, args.evidence_dir)


if __name__ == "__main__":
    main()
