import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"

RELEASE_SECRET_NAMES = {
    "IQT_PROD_ANDROID_KEYSTORE_BASE64",
    "IQT_PROD_ANDROID_KEYSTORE_PASSWORD",
    "IQT_PROD_ANDROID_KEY_ALIAS",
    "IQT_PROD_ANDROID_KEY_PASSWORD",
    "IQT_PROD_ORACLE_SSH_KEY",
    "IQT_PROD_ORACLE_HOST",
    "IQT_PROD_ORACLE_USER",
    "IQT_PROD_ORACLE_DEPLOY_DIR",
    "IQT_PROD_ORACLE_KNOWN_HOSTS",
    "IQT_PROD_UPDATE_PRIVATE_KEY_BASE64",
}
SIGNED_ARTIFACT_SECRET_NAMES = {
    "IQT_PROD_ANDROID_KEYSTORE_BASE64",
    "IQT_PROD_ANDROID_KEYSTORE_PASSWORD",
    "IQT_PROD_ANDROID_KEY_ALIAS",
    "IQT_PROD_ANDROID_KEY_PASSWORD",
}

SECRET_PATTERNS = (
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{30,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
)


class ReleaseWorkflowSecurityTests(unittest.TestCase):
    def read_workflow(self, name):
        return (WORKFLOW_DIR / name).read_text(encoding="utf-8")

    def assert_manual_main_environment(self, workflow, release=False):
        lines = workflow.splitlines()
        trigger_start = lines.index("on:") + 1
        trigger_end = lines.index("permissions:")
        trigger_lines = [line.strip() for line in lines[trigger_start:trigger_end]]
        self.assertIn("workflow_dispatch:", trigger_lines)
        self.assertFalse(any(line.startswith("push:") for line in trigger_lines))
        self.assertFalse(any(line.startswith("pull_request:") for line in trigger_lines))
        self.assertIn("name: iq-tunnel-production", workflow)
        if release:
            expected = "if: " + "$" + "{{ inputs.confirm_release == true && github.ref == 'refs/heads/main' }}"
        else:
            expected = "if: " + "$" + "{{ github.ref == 'refs/heads/main' }}"
        self.assertIn(expected, workflow)

    def assert_read_only_permissions_and_pinned_actions(self, workflow):
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertIn("persist-credentials: false", workflow)
        actions = []
        for line in workflow.splitlines():
            stripped = line.strip()
            if stripped.startswith("uses:") or stripped.startswith("- uses:"):
                action = stripped.split("uses:", 1)[1].split("#", 1)[0].strip()
                actions.append(action)
        self.assertTrue(actions, "Expected third-party actions to be declared.")
        for action in actions:
            self.assertRegex(
                action,
                r"@[0-9a-f]{40}$",
                msg=f"Action is not pinned to an immutable commit SHA: {action}",
            )

    def assert_environment_secrets_only(self, workflow, expected):
        names = set()
        for line in workflow.splitlines():
            if "secrets.IQT_PROD_" in line:
                name = line.split("secrets.", 1)[1].split()[0].rstrip("}")
                names.add(name)
        self.assertEqual(names, expected)
        legacy_names = {
            "ANDROID_KEYSTORE_BASE64",
            "ANDROID_KEYSTORE_PASSWORD",
            "ANDROID_KEY_ALIAS",
            "ANDROID_KEY_PASSWORD",
            "ORACLE_SSH_KEY",
            "ORACLE_HOST",
            "ORACLE_USER",
            "ORACLE_DEPLOY_DIR",
            "ORACLE_KNOWN_HOSTS",
            "UPDATE_PRIVATE_KEY_BASE64",
        }
        for name in legacy_names:
            self.assertNotIn("secrets." + name, workflow)

    def test_production_publish_workflow_is_manual_and_environment_gated(self):
        workflow = self.read_workflow("android-release.yml")
        self.assert_manual_main_environment(workflow, release=True)
        self.assert_read_only_permissions_and_pinned_actions(workflow)
        self.assert_environment_secrets_only(workflow, RELEASE_SECRET_NAMES)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("Remove signing material", workflow)

    def test_signed_artifact_workflow_is_manual_and_environment_gated(self):
        workflow = self.read_workflow("android-signed-artifact.yml")
        self.assert_manual_main_environment(workflow)
        self.assert_read_only_permissions_and_pinned_actions(workflow)
        self.assert_environment_secrets_only(workflow, SIGNED_ARTIFACT_SECRET_NAMES)

    def test_routine_ci_never_receives_production_secrets(self):
        workflow = self.read_workflow("android-ci.yml")
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertNotIn("secrets.", workflow)
        self.assertIn("persist-credentials: false", workflow)

    def test_openwrt_http_requires_one_time_opt_in_and_private_host(self):
        client = (ROOT / "lib" / "openwrt" / "openwrt_client.dart").read_text(
            encoding="utf-8"
        )
        page = (ROOT / "lib" / "openwrt" / "openwrt_page.dart").read_text(
            encoding="utf-8"
        )
        self.assertIn("bool allowInsecureHttp = false", client)
        self.assertIn("if (!_isPrivateOrLocalHost(parsed.host))", client)
        self.assertIn("if (!allowInsecureHttp)", client)
        self.assertIn("allowInsecureHttp = await _confirmInsecureHttp()", page)
        self.assertIn("barrierDismissible: false", page)
        self.assertIn("متابعة لمرة واحدة", page)

    def test_repository_ignores_common_secret_files(self):
        ignored = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for entry in (
            "*.jks",
            "*.keystore",
            "key.properties",
            ".env",
            "*.pem",
            "*.p12",
            "*.pfx",
            "*.key",
        ):
            self.assertIn(entry, ignored)

    def test_tracked_files_contain_no_common_private_key_or_token_markers(self):
        result = subprocess.run(
            ["git", "ls-files", "-z"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
        )
        paths = [
            Path(item.decode("utf-8"))
            for item in result.stdout.split(bytes([0]))
            if item
        ]
        forbidden_extensions = {".jks", ".keystore", ".pem", ".p12", ".pfx"}
        for path in paths:
            self.assertNotIn(
                path.suffix.lower(),
                forbidden_extensions,
                msg=f"Potential signing/secret file must not be tracked: {path}",
            )
            file_path = ROOT / path
            if not file_path.is_file() or file_path.stat().st_size > 2 * 1024 * 1024:
                continue
            try:
                text_content = file_path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for pattern in SECRET_PATTERNS:
                self.assertIsNone(
                    pattern.search(text_content),
                    msg=f"Potential secret marker found in tracked file: {path}",
                )


if __name__ == "__main__":
    unittest.main()
