import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ANDROID_PLUGIN = ROOT / "packages" / "iqtunnel_xray" / "android"


class LibXrayJniKeepRulesTests(unittest.TestCase):
    def test_android_plugin_exports_consumer_keep_rules(self):
        gradle = (ANDROID_PLUGIN / "build.gradle.kts").read_text(encoding="utf-8")
        rules_path = ANDROID_PLUGIN / "consumer-rules.pro"
        self.assertRegex(
            gradle,
            r'(?s)defaultConfig\s*\{[^}]*consumerProguardFiles\("consumer-rules\.pro"\)',
        )
        self.assertTrue(rules_path.is_file(), "Android plugin consumer rules are missing")

        rules = rules_path.read_text(encoding="utf-8")
        self.assertRegex(rules, r"(?m)^-keep\s+class\s+go\.\*\*\s+\{\s\*\s*;\s*\}$")
        self.assertRegex(rules, r"(?m)^-keep\s+class\s+libXray\.\*\*\s+\{\s\*\s*;\s*\}$")

    def test_release_dex_verifier_fails_closed_on_missing_seq_helper(self):
        verifier = (ROOT / "tool" / "verify_libxray_jni_dex.py").read_text(encoding="utf-8")
        self.assertIn('type_descriptors[class_index] != "Lgo/Seq;"', verifier)
        self.assertIn('if "getRef" not in methods:', verifier)
        self.assertIn("Java_go_Seq_init", verifier)


if __name__ == "__main__":
    unittest.main()
