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
FORBIDDEN_MEDIA_PERMISSIONS = frozenset({
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_AUDIO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
})


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


def _assert_no_forbidden_media_permissions(manifest_root: dict) -> None:
    for element in manifest_root["children"]:
        if element["name"] not in {"uses-permission", "uses-permission-sdk-23"}:
            continue
        permission = _android_attribute(element["attributes"], "name")
        if permission in FORBIDDEN_MEDIA_PERMISSIONS:
            raise SystemExit(
                f"Packaged manifest requests unnecessary media/storage permission: {permission}"
            )


def _manifest_resource_id(dump: str, attribute: str, resource_name: str, resources: str) -> None:
    lines = [
        line for line in dump.splitlines()
        if re.search(rf"(?:android:|http://schemas\.android\.com/apk/res/android:){re.escape(attribute)}\(", line)
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
    resource_lines = resources.splitlines()
    resource_line = next(
        (
            item for item in resource_lines
            if resource_id in item.lower() and f"xml/{resource_name}".lower() in item.lower()
        ),
        None,
    )
    if resource_line is None:
        id_matches = [item.strip() for item in resource_lines if resource_id in item.lower()]
        name_matches = [
            item.strip() for item in resource_lines
            if f"xml/{resource_name}".lower() in item.lower()
        ]
        raise SystemExit(
            f"android:{attribute} resource {resource_id} does not resolve to "
            f"xml/{resource_name}. AAPT2 lines with ID: {id_matches[:5]!r}; "
            f"lines with resource name: {name_matches[:5]!r}"
        )



def _manifest_resource_file(
    manifest_dump: str,
    attribute: str,
    resource_name: str,
    resources_dump: str,
) -> str:
    """Resolve a manifest XML resource to its actual packaged APK path.

    AAPT2/AGP may rename resource file paths while preserving their resource
    IDs and names. Resolve the file path through the compiled resource table
    rather than assuming it remains res/xml/<resource_name>.xml.
    """
    attribute_lines = [
        line for line in manifest_dump.splitlines()
        if re.search(
            rf"(?:android:|http://schemas\.android\.com/apk/res/android:)"
            rf"{re.escape(attribute)}\(",
            line,
        )
    ]
    if len(attribute_lines) != 1:
        raise SystemExit(
            f"APK manifest must contain exactly one android:{attribute} attribute."
        )

    line = attribute_lines[0]
    symbolic = f"@xml/{resource_name}"
    resource_id_match = re.search(r"=@(0x[0-9a-fA-F]+)", line)
    if symbolic not in line and not resource_id_match:
        raise SystemExit(
            f"Could not resolve the compiled resource ID for android:{attribute}."
        )

    lines = resources_dump.splitlines()
    headers = []
    for line_number, item in enumerate(lines):
        match = re.match(
            r"^\s*resource\s+(0x[0-9a-fA-F]+)\s+(.+?)\s*$",
            item,
        )
        if match:
            headers.append(
                (match.group(1).lower(), match.group(2), line_number, item)
            )

    expected_type_name = f"xml/{resource_name}".lower()
    if resource_id_match:
        resource_id = resource_id_match.group(1).lower()
        candidates = [
            entry for entry in headers
            if entry[0] == resource_id and entry[1].lower().endswith(expected_type_name)
        ]
    else:
        candidates = [
            entry for entry in headers
            if entry[1].lower().endswith(expected_type_name)
        ]

    if len(candidates) != 1:
        raise SystemExit(
            f"android:{attribute} does not resolve uniquely to xml/{resource_name}; "
            f"matching resource-table entries: {[entry[3] for entry in candidates[:5]]!r}"
        )

    selected = candidates[0]
    start_line = selected[2]
    later_headers = [entry for entry in headers if entry[2] > start_line]
    end_line = later_headers[0][2] if later_headers else len(lines)
    resource_block = "\n".join(lines[start_line:end_line])
    paths = re.findall(r"\(file\)\s+(res/[^\s]+)", resource_block)

    if len(paths) != 1:
        raise SystemExit(
            f"Expected exactly one packaged XML file for xml/{resource_name}; "
            f"AAPT2 resource-table block was: {resource_block[:1200]!r}"
        )
    return paths[0]



def _aapt2_xmltree(aapt2: str, apk: Path, internal_path: str, label: str) -> str:
    result = subprocess.run(
        [aapt2, "dump", "xmltree", str(apk), "--file", internal_path],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        detail = (result.stdout or "").strip()
        raise SystemExit(
            f"AAPT2 could not inspect packaged {label} at {internal_path!r}. "
            f"Exit code: {result.returncode}. Output: {detail[-1800:]!r}"
        )
    return result.stdout


def validate_dumps(
    manifest: str,
    legacy: str,
    extraction: str,
    resources: str,
    *,
    expect_not_debuggable: bool = False,
) -> None:
    manifest_roots = _parse_xmltree(manifest)
    if len(manifest_roots) != 1 or manifest_roots[0]["name"] != "manifest":
        raise SystemExit("Packaged Android manifest could not be parsed.")
    _assert_no_forbidden_media_permissions(manifest_roots[0])
    application = _direct_child(manifest_roots[0], "application")
    if _android_attribute(application["attributes"], "allowBackup") != "false":
        raise SystemExit("Packaged manifest does not enforce android:allowBackup=false.")
    if expect_not_debuggable and _android_attribute(
        application["attributes"], "debuggable"
    ) == "true":
        raise SystemExit("Release APK is marked android:debuggable=true.")

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


def verify(
    apk: Path,
    aapt2: str,
    evidence_dir: Path,
    *,
    expect_not_debuggable: bool = False,
) -> None:
    evidence_dir.mkdir(parents=True, exist_ok=True)

    resources_result = subprocess.run(
        [aapt2, "dump", "resources", str(apk)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if resources_result.returncode != 0:
        detail = (resources_result.stdout or "").strip()
        raise SystemExit(
            f"AAPT2 could not inspect the APK resource table. "
            f"Exit code: {resources_result.returncode}. Output: {detail[-1800:]!r}"
        )
    resources_dump = resources_result.stdout
    (evidence_dir / "resources.txt").write_text(
        resources_dump, encoding="utf-8"
    )

    manifest_dump = _aapt2_xmltree(
        aapt2, apk, "AndroidManifest.xml", "Android manifest"
    )
    legacy_path = _manifest_resource_file(
        manifest_dump, "fullBackupContent", "backup_rules", resources_dump
    )
    extraction_path = _manifest_resource_file(
        manifest_dump, "dataExtractionRules", "data_extraction_rules",
        resources_dump,
    )

    dumps = {
        "manifest": manifest_dump,
        "legacy": _aapt2_xmltree(
            aapt2, apk, legacy_path, "legacy backup rules"
        ),
        "extraction": _aapt2_xmltree(
            aapt2, apk, extraction_path, "data extraction rules"
        ),
    }
    for key, dump in dumps.items():
        (evidence_dir / f"{key}.xmltree.txt").write_text(
            dump, encoding="utf-8"
        )

    validate_dumps(
        dumps["manifest"],
        dumps["legacy"],
        dumps["extraction"],
        resources_dump,
        expect_not_debuggable=expect_not_debuggable,
    )
    (evidence_dir / "verification.txt").write_text(
        "PASS: packaged manifest excludes all nine storage domains from backup/transfer "
        "and omits unused broad media/storage read permissions.\n",
        encoding="utf-8",
    )
    print(
        "AAPT2 verified the packaged Android backup and media-permission policy "
        f"(legacy={legacy_path}, extraction={extraction_path})."
    )

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument(
        "--expect-not-debuggable",
        action="store_true",
        help="Fail if the compiled application manifest enables android:debuggable.",
    )
    args = parser.parse_args()
    if not args.apk.is_file():
        raise SystemExit(f"APK does not exist: {args.apk}")
    verify(
        args.apk,
        args.aapt2,
        args.evidence_dir,
        expect_not_debuggable=args.expect_not_debuggable,
    )


if __name__ == "__main__":
    main()
