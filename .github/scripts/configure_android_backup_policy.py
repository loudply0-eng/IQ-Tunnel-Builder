#!/usr/bin/env python3
"""Apply a fail-closed Android Auto Backup policy to the generated Flutter app."""
from pathlib import Path
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_NS + "}"
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


def _write_xml(path: Path, root: ET.Element) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def configure(manifest_path: Path, resource_dir: Path) -> None:
    ET.register_namespace("android", ANDROID_NS)
    tree = ET.parse(manifest_path)
    root = tree.getroot()
    application = root.find("application")
    if application is None:
        raise SystemExit("Generated AndroidManifest.xml has no application element.")

    # Keep app data local: Android Keystore keys are hardware/device-bound and
    # cannot be restored with ciphertext copied to another device.
    application.set(ANDROID + "allowBackup", "false")
    application.set(ANDROID + "fullBackupContent", "@xml/backup_rules")
    application.set(ANDROID + "dataExtractionRules", "@xml/data_extraction_rules")

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(manifest_path, encoding="utf-8", xml_declaration=True)

    legacy = ET.Element("full-backup-content")
    for domain in DOMAINS:
        ET.SubElement(legacy, "exclude", {"domain": domain, "path": "."})
    _write_xml(resource_dir / "backup_rules.xml", legacy)

    extraction = ET.Element("data-extraction-rules")
    for section_name in ("cloud-backup", "device-transfer"):
        section = ET.SubElement(extraction, section_name)
        for domain in DOMAINS:
            ET.SubElement(section, "exclude", {"domain": domain, "path": "."})
    _write_xml(resource_dir / "data_extraction_rules.xml", extraction)


def main() -> None:
    configure(
        Path("android/app/src/main/AndroidManifest.xml"),
        Path("android/app/src/main/res/xml"),
    )
    print("Configured Android backup exclusions for all nine storage domains.")


if __name__ == "__main__":
    main()
