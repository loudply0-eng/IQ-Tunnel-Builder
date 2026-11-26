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


def _parse_xmltree(dump: str) -> list[dict]:
    roots = []
    stack = []
    attribute_pattern = re.compile(
        r'([^ (]+)(?:\([^)]*\))?\s*=\s*(?:"([^"]*)"|(\S+))'
    )
    for line in dump.splitlines():
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped.startswith("E: "):
            while stack and stack[-1]["indent"] >= indent:
                stack.pop()
            name = stripped[3:].split(None, 1)[0]
            node = {"name": name, "indent": indent, "attributes": {}, "children": []}
            if stack:
                stack[-1]["children"].append(node)
            else:
                roots.append(node)
            stack.append(node)
        elif stripped.startswith("A: ") and stack:
            match = attribute_pattern.match(stripped[3:])
            if match:
                key = match.group(1)
                value = match.group(2) if match.group(2) is not None else match.group(3)
                stack[-1]["attributes"][key] = value
    return roots


def _android_attribute(attributes: dict, name: str) -> str | None:
    # AAPT2 versions differ: some print android:name, others print the
    # expanded namespace URI followed by :name.
    matches = [
        value for key, value in attributes.items()
        if key == f"android:{name}"
        or key == f"http://schemas.android.com/apk/res/android:{name}"
        or key.endswith(f":{name}")
    ]
    if len(matches) > 1:
        raise SystemExit(f"Packaged manifest contains ambiguous android:{name} attributes.")
    return matches[0] if matches else None


def _direct_child(parent: dict, name: str) -> dict:
    matches = [child for child in parent["children"] if child["name"] == name]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one {name} element under {parent['name']}.")
    return matches[0]


def _assert_exclusions(parent: dict, expected_domains: tuple[str, ...], context: str) -> None:
    excludes = [child for child in parent["children"] if child["name"] == "exclude"]
    if len(excludes) != len(expected_domains):
        raise SystemExit(f"{context} must contain exactly {len(expected_domains)} exclude elements.")
    domains = [node["attributes"].get("domain") for node in excludes]
    paths = [node["attributes"].get("path") for node in excludes]
    if set(domains) != set(expected_domains) or len(set(domains)) != len(expected_domains):
        raise SystemExit(f"{context} must exclude each of the nine storage domains exactly once.")
    if any(path != "." for path in paths):
        raise SystemExit(f"{context} must use path='.' for every exclusion.")


def _manifest_resource_id(dump: str, attribute: str, resource_name: str, resources: str) -> None:
    lines = [
        line for line in dump.splitlines()
        if re.search(rf"(?:android:|http://schemas\\.android\\.com/apk/res/android:){re.escape(attribute)}\\(", line)
    ]
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
    manifest_roots = _parse_xmltree(manifest)
    if len(manifest_roots) != 1 or manifest_roots[0]["name"] != "manifest":
        raise SystemExit("Packaged Android manifest could not be parsed.")
    application = _direct_child(manifest_roots[0], "application")
    if _android_attribute(application["attributes"], "allowBackup") != "false":
        raise SystemExit("Packaged manifest does not enforce android:allowBackup=false.")

    _manifest_resource_id(manifest, "fullBackupContent", "backup_rules", resources)
    _manifest_resource_id(manifest, "dataExtractionRules", "data_extraction_rules", resources)

    legacy_roots = _parse_xmltree(legacy)
    if len(legacy_roots) != 1 or legacy_roots[0]["name"] != "full-backup-content":
        raise SystemExit("Packaged legacy backup_rules.xml has the wrong root element.")
    _assert_exclusions(legacy_roots[0], DOMAINS, "Legacy backup rules")

    extraction_roots = _parse_xmltree(extraction)
    if len(extraction_roots) != 1 or extraction_roots[0]["name"] != "data-extraction-rules":
        raise SystemExit("Packaged data_extraction_rules.xml has the wrong root element.")
    cloud = _direct_child(extraction_roots[0], "cloud-backup")
    device = _direct_child(extraction_roots[0], "device-transfer")
    _assert_exclusions(cloud, DOMAINS, "Cloud backup rules")
    _assert_exclusions(device, DOMAINS, "Device-transfer rules")


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
