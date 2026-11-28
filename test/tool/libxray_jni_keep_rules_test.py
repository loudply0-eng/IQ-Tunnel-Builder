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
        self.assertRegex(rules, r"(?m)^-keep\s+class\s+go\.\*\*\s+\{\s*\*\s*;\s*\}$")
        self.assertRegex(rules, r"(?m)^-keep\s+class\s+libXray\.\*\*\s+\{\s*\*\s*;\s*\}$")

    def test_jni_helper_names_are_explicitly_covered(self):
        rules = (ANDROID_PLUGIN / "consumer-rules.pro").read_text(encoding="utf-8")
        for helper in ("Seq.getRef", "Seq.incRef", "Seq.incRefnum", "Seq.decRef", "Seq.throwException"):
            self.assertIn(helper, rules)


if __name__ == "__main__":
    unittest.main()
