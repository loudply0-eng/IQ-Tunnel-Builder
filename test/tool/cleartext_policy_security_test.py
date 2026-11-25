"""Regression gates for the app-wide Android cleartext exception.

Android's manifest flag is app-wide. OpenWrt needs HTTP for arbitrary private
LAN IPs, so a hostname-based Network Security Config cannot safely scope that
exception to every possible router address. Keep app-owned HTTP clients
enumerated and require the updater to remain HTTPS-only.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = (ROOT / "lib", ROOT / "packages")
EXPECTED_HTTP_IMPORTS = {
    "lib/main.dart",  # updater; its transport is HTTPS-only
    "lib/openwrt/openwrt_client.dart",  # explicit private-host + one-shot opt-in
}


class CleartextPolicyTests(unittest.TestCase):
    def test_app_owned_http_transports_are_explicitly_allowlisted(self):
        dart_files = [
            path
            for source_root in SOURCE_ROOTS
            if source_root.exists()
            for path in source_root.rglob("*.dart")
        ]
        imports = set()
        for path in dart_files:
            source = path.read_text(encoding="utf-8")
            if "package:http/http.dart" in source:
                imports.add(path.relative_to(ROOT).as_posix())

            # New direct transports need an explicit security review rather
            # than silently inheriting usesCleartextTraffic=true.
            forbidden_new_transports = (
                r"\bHttpClient\s*\(",
                r"\bDio\s*\(",
                r"\bWebView(?:Widget|Controller)?\s*\(",
                r"\b(?:RawSocket|Socket|WebSocket)\.connect\s*\(",
            )
            for pattern in forbidden_new_transports:
                self.assertIsNone(
                    re.search(pattern, source),
                    msg=f"Unreviewed network transport in {path.relative_to(ROOT)}: {pattern}",
                )

        self.assertEqual(imports, EXPECTED_HTTP_IMPORTS)

    def test_update_client_rejects_http_and_downgrade_redirects(self):
        source = (ROOT / "lib" / "main.dart").read_text(encoding="utf-8")
        self.assertIn("Future<http.StreamedResponse> _sendHttpsGet(", source)
        self.assertRegex(
            source,
            r"if\s*\(uri\.scheme\s*!=\s*'https'",
        )
        self.assertRegex(
            source,
            r"if\s*\(nextUri\.scheme\s*!=\s*'https'",
        )
        self.assertIn("_sendHttpsGet(", source)

    def test_openwrt_is_the_only_http_client_and_requires_local_opt_in(self):
        source = (
            ROOT / "lib" / "openwrt" / "openwrt_client.dart"
        ).read_text(encoding="utf-8")
        self.assertIn("if (!_isPrivateOrLocalHost(parsed.host))", source)
        self.assertIn("if (!allowInsecureHttp)", source)
        self.assertIn("allowInsecureHttp = false", source)

    def test_release_workflow_documents_the_app_wide_cleartext_exception(self):
        workflow = (
            ROOT / ".github" / "workflows" / "android-release.yml"
        ).read_text(encoding="utf-8")
        start = workflow.index(
            "- name: Add APK installer handoff permission"
        )
        end = workflow.index(
            "- name: Configure permanent Android signing", start
        )
        manifest_step = workflow[start:end]
        self.assertIn('android:usesCleartextTraffic="true"', manifest_step)
        self.assertIn("Local OpenWrt LuCI commonly uses HTTP", manifest_step)
        self.assertIn(
            "rejects clear-text URLs outside private/local host ranges",
            manifest_step,
        )


if __name__ == "__main__":
    unittest.main()
