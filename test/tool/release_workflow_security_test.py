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
    "IQT_PROD_ORACLE_KNOWN_HOSTS",
    "IQT_PROD_UPDATE_PRIVATE_KEY_BASE64",
    "IQT_PROD_SOURCE_DEPLOY_KEY",
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

    def assert_manual_main_environment(
        self, workflow, release=False, confirmation_input=None
    ):
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
            confirmation_input = "confirm_release"
        elif confirmation_input:
            expected = "if: " + "$" + "{{ inputs." + confirmation_input + " == true && github.ref == 'refs/heads/main' }}"
        else:
            expected = "if: " + "$" + "{{ github.ref == 'refs/heads/main' }}"
        self.assertIn(expected, workflow)
        if confirmation_input:
            self.assertRegex(
                workflow,
                r"(?s)workflow_dispatch:\s+inputs:\s+"
                + re.escape(confirmation_input)
                + r":\s+description:.*?\s+required: true\s+type: boolean\s+default: false",
            )

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
        self.assertIn("source_ref:", workflow)
        self.assertIn("repository: loudply0-eng/IQ-Tunnel", workflow)
        self.assertIn("path: .iqt-private-source", workflow)
        self.assertIn("rsync -a --delete", workflow)
        self.assertIn("SOURCE_DEPLOY_KEY", workflow)
        self.assertIn("path: .iqt-private-main", workflow)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("merge-base --is-ancestor", workflow)
        self.assertIn("not an ancestor of private main", workflow)
        self.assertIn("Prepare monotonic release version", workflow)
        self.assertIn("max(source_build, current_build + 1)", workflow)
        self.assertIn('--build-number="${{ steps.release_meta.outputs.build_number }}"', workflow)
        self.assertNotIn("إصدار 1.0.11:", workflow)

    def test_signed_artifact_workflow_is_manual_confirmed_and_environment_gated(self):
        workflow = self.read_workflow("android-signed-artifact.yml")
        self.assert_manual_main_environment(
            workflow, confirmation_input="confirm_build"
        )
        self.assert_read_only_permissions_and_pinned_actions(workflow)
        self.assert_environment_secrets_only(workflow, SIGNED_ARTIFACT_SECRET_NAMES)
        self.assertIn("cancel-in-progress: false", workflow)

    def test_routine_ci_never_receives_production_secrets(self):
        workflow = self.read_workflow("android-ci.yml")
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertNotIn("secrets.", workflow)
        self.assertIn("persist-credentials: false", workflow)

    def test_all_public_workflows_pin_actions_and_disable_nested_flutter_cache(self):
        workflow_names = (
            "android-ci.yml",
            "android-release.yml",
            "android-signed-artifact.yml",
        )
        for name in workflow_names:
            workflow = self.read_workflow(name)
            self.assert_read_only_permissions_and_pinned_actions(workflow)
            lines = workflow.splitlines()
            flutter_index = next(
                i for i, line in enumerate(lines)
                if "subosito/flutter-action@" in line
            )
            flutter_block = "\\n".join(lines[flutter_index:flutter_index + 8])
            self.assertIn("cache: false", flutter_block)

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


    def test_sftp_deploy_uses_openssh_atomic_rename_command(self):
        workflow = self.read_workflow("android-release.yml")
        self.assertEqual(workflow.count("          rename /incoming/"), 4)
        self.assertNotIn("posix-rename /incoming/", workflow)


    def test_sftp_deploy_requires_posix_rename_extension_before_upload(self):
        workflow = self.read_workflow("android-release.yml")
        start = workflow.index(
            "      - name: Publish APK and signed manifest to Oracle over restricted SFTP"
        )
        end = workflow.index("      - name: Remove signing material", start)
        deploy_step = workflow[start:end]

        preflight = deploy_step.index("sftp -vv -b -")
        first_upload = deploy_step.index("put build/app/outputs/flutter-apk/app-release.apk")
        self.assertLess(preflight, first_upload)
        self.assertIn(
            'Server supports extension "posix-rename@openssh.com" revision 1',
            deploy_step,
        )
        self.assertIn("refusing to publish", deploy_step)
        self.assertIn("2>/tmp/iqt-sftp-capabilities.log", deploy_step)


    def test_deploy_uses_sftp_only_without_remote_shell_or_scp(self):
        workflow = self.read_workflow("android-release.yml")
        start = workflow.index(
            "      - name: Publish APK and signed manifest to Oracle over restricted SFTP"
        )
        end = workflow.index("      - name: Remove signing material", start)
        deploy_step = workflow[start:end]

        self.assertIn('if user != "iqt-deploy":', deploy_step)
        self.assertIn("sftp -b -", deploy_step)
        self.assertIn("-oStrictHostKeyChecking=yes", deploy_step)
        self.assertNotIn("scp ", deploy_step)
        self.assertNotIn("ssh ", deploy_step)
        self.assertNotIn("ORACLE_DEPLOY_DIR", deploy_step)
        self.assertEqual(deploy_step.count("rename /incoming/"), 4)
        self.assertLess(
            deploy_step.index("rename /incoming/.manifest-"),
            deploy_step.index('PUBLIC_BASE="https://'),
        )


    def test_release_documentation_matches_sftp_deploy_credentials(self):
        security = (ROOT / "SECURITY.md").read_text(encoding="utf-8")
        automatic = (ROOT / "docs" / "AUTOMATIC_RELEASES.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("IQT_PROD_SOURCE_DEPLOY_KEY", security)
        self.assertIn("IQT_PROD_SOURCE_DEPLOY_KEY", automatic)
        active_secret_section = security.split(
            "The legacy repository-level names", 1
        )[0]
        self.assertNotIn("IQT_PROD_SOURCE_READ_TOKEN", active_secret_section)
        self.assertNotIn("IQT_PROD_ORACLE_DEPLOY_DIR", active_secret_section)
        self.assertNotIn("IQT_PROD_SOURCE_READ_TOKEN", automatic)

        self.assertIn("iqt-deploy", security)
        self.assertIn("/incoming", security)
        self.assertIn("iqt-deploy", automatic)
        self.assertIn("/incoming", automatic)


    def test_release_checks_package_identity_and_permanent_android_signer(self):
        workflow = self.read_workflow("android-release.yml")
        package_step = workflow.split(
            "- name: Verify Android package identity", 1
        )[1].split("- name: Verify Android APK signature", 1)[0]
        signer_step = workflow.split(
            "- name: Verify Android APK signature", 1
        )[1].split("- uses: actions/upload-artifact@", 1)[0]

        self.assertIn('"$AAPT" dump badging "$APK"', package_step)
        self.assertIn("package: name='com.iqtunnel.iq_tunnel'", package_step)
        self.assertIn("apksigner", signer_step)
        self.assertIn("verify --verbose --print-certs", signer_step)
        self.assertIn(
            "cc96499ac23bf3a9101b2a7cc7d19feef852e61a5902860abe15218a8968b017",
            signer_step,
        )
        self.assertIn("test \"$SIGNER_SHA256\" = \"$EXPECTED_SIGNER_SHA256\"", signer_step)

    def test_release_verifies_published_apk_http_size_hash_and_manifest(self):
        workflow = self.read_workflow("android-release.yml")
        publish_step = workflow.split(
            "- name: Publish APK and signed manifest to Oracle over restricted SFTP",
            1,
        )[1].split("- name: Remove signing material", 1)[0]

        self.assertIn("curl --fail --silent --show-error --location", publish_step)
        self.assertIn("HTTP/\\S+ 200", publish_step)
        self.assertIn("Content-Length", publish_step)
        self.assertIn("len(lengths) != 1", publish_step)
        self.assertIn("int(lengths[0]) != actual_size", publish_step)
        self.assertIn("ACTUAL_APK_SHA256", publish_step)
        self.assertIn("EXPECTED_APK_SHA256", publish_step)
        self.assertIn("cmp --silent /tmp/iq-update-manifest.json /tmp/iq-update-manifest-published.json", publish_step)


if __name__ == "__main__":
    unittest.main()
