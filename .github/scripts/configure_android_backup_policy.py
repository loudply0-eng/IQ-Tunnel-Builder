#!/usr/bin/env python3
"""Apply a fail-closed Android Auto Backup policy to the generated Flutter app."""
from pathlib import Path
import xml.etree.ElementTree as ET

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID = "{" + ANDROID_NS + "}"
TOOLS_NS = "http://schemas.android.com/tools"
TOOLS = "{" + TOOLS_NS + "}"
REMOVED_PERMISSIONS = (
    # open_filex is used only to hand off IQ Tunnel's own APK from the app-private
    # temporary directory. It does not need access to user photos, videos, audio,
    # or shared external storage for this flow.
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_AUDIO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
)
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
    ET.register_namespace("tools", TOOLS_NS)
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

    # Remove broad media/storage read permissions contributed by open_filex.
    # IQ Tunnel opens only its own downloaded APK from getTemporaryDirectory();
    # package installation uses FileProvider and does not need shared-media access.
    existing_removals = {
        child.get(ANDROID + "name")
        for child in root.findall("uses-permission")
        if child.get(TOOLS + "node") == "remove"
    }
    for permission in REMOVED_PERMISSIONS:
        if permission not in existing_removals:
            ET.SubElement(
                root,
                "uses-permission",
                {
                    ANDROID + "name": permission,
                    TOOLS + "node": "remove",
                },
            )

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
