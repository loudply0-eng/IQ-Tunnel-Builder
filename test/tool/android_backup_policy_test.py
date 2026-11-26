import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github" / "scripts"
DOMAINS = (
    "root", "file", "database", "sharedpref", "external",
    "device_root", "device_file", "device_database", "device_sharedpref",
)


def load_script(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def exclusion_dump(domains, indent="    "):
    return "\n".join(
        f'{indent}E: exclude\n{indent}  A: domain(0x01010000)="{domain}"\n'
        f'{indent}  A: path(0x01010000)="."'
        for domain in domains
    )


class AndroidBackupPolicyTests(unittest.TestCase):
    def test_generated_manifest_and_xml_exclude_all_storage_domains(self):
        configure = load_script(
            "configure_android_backup_policy", "configure_android_backup_policy.py"
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "AndroidManifest.xml"
            resources = root / "res" / "xml"
            manifest.write_text(
                '<?xml version="1.0"?><manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                '<application android:label="IQ Tunnel"/></manifest>',
                encoding="utf-8",
            )
            configure.configure(manifest, resources)

            android = "{http://schemas.android.com/apk/res/android}"
            application = ET.parse(manifest).getroot().find("application")
            self.assertEqual(application.get(android + "allowBackup"), "false")
            self.assertEqual(
                application.get(android + "fullBackupContent"), "@xml/backup_rules"
            )
            self.assertEqual(
                application.get(android + "dataExtractionRules"),
                "@xml/data_extraction_rules",
            )

            legacy = ET.parse(resources / "backup_rules.xml").getroot()
            self.assertEqual(legacy.tag, "full-backup-content")
            legacy_excludes = legacy.findall("exclude")
            self.assertEqual({node.get("domain") for node in legacy_excludes}, set(DOMAINS))
            self.assertEqual(len(legacy_excludes), len(DOMAINS))
            self.assertTrue(all(node.get("path") == "." for node in legacy_excludes))

            extraction = ET.parse(resources / "data_extraction_rules.xml").getroot()
            self.assertEqual(extraction.tag, "data-extraction-rules")
            self.assertEqual(
                {section.tag for section in extraction},
                {"cloud-backup", "device-transfer"},
            )
            for section in extraction:
                excludes = section.findall("exclude")
                self.assertEqual({node.get("domain") for node in excludes}, set(DOMAINS))
                self.assertEqual(len(excludes), len(DOMAINS))
                self.assertTrue(all(node.get("path") == "." for node in excludes))

    def test_aapt2_gate_rejects_missing_or_misplaced_packaged_rules(self):
        verifier = load_script(
            "verify_android_backup_policy", "verify_android_backup_policy.py"
        )
        manifest = "\n".join(
            [
                "E: manifest",
                "  E: application",
                "    A: android:allowBackup(0x01010280)=false",
                "    A: android:fullBackupContent(0x0101027c)=@0x7f120000",
                "    A: android:dataExtractionRules(0x010106xx)=@0x7f120001",
            ]
        )
        legacy = "E: full-backup-content\n" + exclusion_dump(DOMAINS, "  ")
        extraction = (
            "E: data-extraction-rules\n"
            "  E: cloud-backup\n"
            + exclusion_dump(DOMAINS, "    ")
            + "\n  E: device-transfer\n"
            + exclusion_dump(DOMAINS, "    ")
        )
        resources = (
            "resource 0x7f120000 com.iqtunnel:xml/backup_rules\n"
            "resource 0x7f120001 com.iqtunnel:xml/data_extraction_rules\n"
        )
        verifier.validate_dumps(manifest, legacy, extraction, resources)
        misplaced = (
            "E: data-extraction-rules\n"
            "  E: cloud-backup\n"
            "  E: device-transfer\n"
            + exclusion_dump(DOMAINS, "    ")
            + exclusion_dump(DOMAINS, "    ")
        )
        with self.assertRaises(SystemExit):
            verifier.validate_dumps(manifest, legacy, misplaced, resources)
        with self.assertRaises(SystemExit):
            verifier.validate_dumps(
                manifest,
                legacy.replace('="sharedpref"', '="file"', 1),
                extraction,
                resources,
            )

    def test_both_workflows_run_configuration_and_packaged_apk_gate(self):
        verifier = (SCRIPTS / "verify_android_backup_policy.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('"dump", "xmltree"', verifier)
        self.assertIn('"dump", "resources"', verifier)
        for workflow_name in ("android-ci.yml", "android-release.yml"):
            workflow = (ROOT / ".github" / "workflows" / workflow_name).read_text(
                encoding="utf-8"
            )
            self.assertIn("configure_android_backup_policy.py", workflow)
            self.assertIn("verify_android_backup_policy.py", workflow)
            self.assertIn("upload-artifact", workflow)


if __name__ == "__main__":
    unittest.main()
