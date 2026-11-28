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
    "IQT_PROD_SOURCE_DEPLOY_KEY",
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
        self.assertIn("source_ref:", workflow)
        self.assertIn("repository: loudply0-eng/IQ-Tunnel", workflow)
        self.assertIn("path: .iqt-private-source", workflow)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("merge-base --is-ancestor", workflow)
        self.assertIn("rsync -a --delete", workflow)
        self.assertIn("IQT_PROD_SOURCE_DEPLOY_KEY", workflow)

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


    def test_sftp_deploy_uses_the_supported_openssh_rename_batch_command(self):
        workflow = self.read_workflow("android-release.yml")
        self.assertEqual(workflow.count("          rename $PUBLISH_DIR/"), 4)
        self.assertNotIn("          posix-rename ", workflow)
        self.assertNotIn("rename /incoming/", workflow)
        self.assertNotIn("rename /.", workflow)
        self.assertIn('PUBLISH_DIR="."', workflow)
        self.assertIn("Remote working directory: /incoming", workflow)
        self.assertIn("rename $PROBE_SOURCE $PROBE_TARGET", workflow)
        self.assertIn("Sending SSH2_FXP_EXTENDED(posix-rename@openssh.com)", workflow)


    def test_sftp_preflight_executes_a_real_posix_replace_before_upload(self):
        workflow = self.read_workflow("android-release.yml")
        start = workflow.index(
            "      - name: Publish APK and signed manifest to Oracle over restricted SFTP"
        )
        end = workflow.index("      - name: Remove signing material", start)
        deploy_step = workflow[start:end]

        preflight = deploy_step.index("sftp -vv -b -")
        probe_rename = deploy_step.index("rename $PROBE_SOURCE $PROBE_TARGET")
        first_release_upload = deploy_step.index(
            "put build/app/outputs/flutter-apk/app-release.apk"
        )
        self.assertLess(preflight, probe_rename)
        self.assertLess(probe_rename, first_release_upload)
        self.assertIn('PUBLISH_DIR="."', deploy_step)
        self.assertIn("ls -l /", deploy_step)
        self.assertIn("cd $PUBLISH_DIR", deploy_step)
        self.assertIn("sftp> cd .", deploy_step)
        self.assertIn("Remote working directory: /incoming", deploy_step)
        self.assertIn("put /tmp/iqt-sftp-rename-probe-source $PROBE_SOURCE", deploy_step)
        self.assertIn("put /tmp/iqt-sftp-rename-probe-target $PROBE_TARGET", deploy_step)
        self.assertIn("Sending SSH2_FXP_EXTENDED(posix-rename@openssh.com)", deploy_step)
        self.assertIn(
            "grep -Fq 'Sending SSH2_FXP_EXTENDED(posix-rename@openssh.com)'",
            deploy_step,
        )
        self.assertIn("trap cleanup_sftp_probe EXIT", deploy_step)
        for temporary_name in (
            ".iqt-$GITHUB_RUN_ID.apk.tmp",
            ".iqt-$GITHUB_RUN_ID.xray.tmp",
            ".iqt-$GITHUB_RUN_ID.sha256.tmp",
            ".manifest-$GITHUB_RUN_ID.tmp",
        ):
            self.assertIn(f"-rm $PUBLISH_DIR/{temporary_name}", deploy_step)
        self.assertIn("refusing to publish", deploy_step)
        self.assertIn("> /tmp/iqt-sftp-capabilities.log 2>&1", deploy_step)
        self.assertIn("Remote working directory: /incoming", deploy_step)


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
        self.assertEqual(deploy_step.count("          rename $PUBLISH_DIR/"), 4)
        self.assertNotIn("          posix-rename ", deploy_step)
        self.assertNotIn("rename /incoming/", deploy_step)
        self.assertNotIn("rename /.", deploy_step)
        self.assertIn('PUBLISH_DIR="."', deploy_step)
        self.assertIn("put build/app/outputs/flutter-apk/app-release.apk $PUBLISH_DIR/.iqt-", deploy_step)
        manifest_upload = deploy_step.index(
            "put /tmp/iq-update-manifest.json $PUBLISH_DIR/.manifest-"
        )
        manifest_mode = deploy_step.index(
            "chmod 640 $PUBLISH_DIR/.manifest-"
        )
        manifest_publish = deploy_step.index("rename $PUBLISH_DIR/.manifest-")
        apk_hash_check = deploy_step.index(
            'test "$ACTUAL_APK_SHA256" = "$EXPECTED_APK_SHA256"'
        )
        xray_hash_check = deploy_step.index(
            "Verified published Xray source archive SHA-256"
        )
        manifest_compare = deploy_step.index(
            "cmp --silent /tmp/iq-update-manifest.json /tmp/iq-update-manifest-published.json"
        )
        self.assertLess(apk_hash_check, manifest_publish)
        self.assertLess(xray_hash_check, manifest_publish)
        self.assertLess(manifest_upload, manifest_mode)
        self.assertLess(manifest_mode, manifest_publish)
        self.assertLess(manifest_publish, manifest_compare)


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
        self.assertIn("root-owned", automatic)
        self.assertIn("/var/www/ota-jail/iqt-jail/incoming", automatic)
        self.assertIn('PUBLISH_DIR="."', automatic)
        self.assertIn("/var/www/ota-jail/iqt-jail/incoming", security)

    def test_automatic_release_documentation_matches_disabled_dispatcher(self):
        automatic = (ROOT / "docs" / "AUTOMATIC_RELEASES.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("hard-disabled", automatic)
        self.assertIn("${{ false }}", automatic)
        self.assertIn("does not listen to `push` events", automatic)
        self.assertIn(
            "do not create `IQT_BUILDER_DISPATCH_TOKEN`",
            automatic,
        )
        self.assertIn("Manual release is available only", automatic)


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
        self.assertIn("EXPECTED_VERSION", package_step)
        self.assertIn("EXPECTED_BUILD_NUMBER", package_step)
        self.assertIn("versionName='$EXPECTED_VERSION'", package_step)
        self.assertIn("versionCode='$EXPECTED_BUILD_NUMBER'", package_step)
        self.assertIn("apksigner", signer_step)
        self.assertIn("verify --verbose --print-certs", signer_step)
        self.assertIn(
            "cc96499ac23bf3a9101b2a7cc7d19feef852e61a5902860abe15218a8968b017",
            signer_step,
        )
        self.assertIn('SIGNER_OUTPUT="$(\"$APKSIGNER\" verify --print-certs "$APK")"', signer_step)
        self.assertIn("certificate SHA-256 digest:", signer_step)
        self.assertIn("EXPECTED_SIGNER_SHA256", signer_step)
        self.assertIn('if [[ "$SIGNER_SHA256" != "$EXPECTED_SIGNER_SHA256" ]]; then', signer_step)
        self.assertIn('if [[ -z "$SIGNER_SHA256" ]]; then', signer_step)
        self.assertIn("APK signer certificate matches the approved permanent IQ Tunnel key.", signer_step)

    def test_release_verifies_apk_before_publishing_signed_manifest(self):
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

        apk_hash_check = publish_step.index(
            'test "$ACTUAL_APK_SHA256" = "$EXPECTED_APK_SHA256"'
        )
        xray_archive_download = publish_step.index(
            '"$PUBLIC_BASE/xray-core-v26.11.9-source.tar.gz" -o /tmp/iq-xray-core-published.tar.gz'
        )
        xray_sidecar_download = publish_step.index(
            '"$PUBLIC_BASE/xray-core-v26.11.9-source.tar.gz.sha256" -o /tmp/iq-xray-core-published.tar.gz.sha256'
        )
        xray_hash_check = publish_step.index(
            "Published Xray source archive SHA-256 does not match"
        )
        manifest_upload = publish_step.index(
            "put /tmp/iq-update-manifest.json $PUBLISH_DIR/.manifest-"
        )
        manifest_compare = publish_step.index(
            "cmp --silent /tmp/iq-update-manifest.json /tmp/iq-update-manifest-published.json"
        )
        first_sftp_batch = publish_step.split("SFTP_BATCH", 1)[0]
        self.assertNotIn(
            "put /tmp/iq-update-manifest.json $PUBLISH_DIR/.manifest-",
            first_sftp_batch,
        )
        self.assertLess(apk_hash_check, manifest_upload)
        self.assertLess(xray_archive_download, xray_sidecar_download)
        self.assertLess(xray_sidecar_download, xray_hash_check)
        self.assertLess(xray_hash_check, manifest_upload)
        self.assertLess(manifest_upload, manifest_compare)
        self.assertIn("SFTP_MANIFEST", publish_step)


    def test_published_manifest_build_number_must_be_a_json_integer(self):
        workflow = self.read_workflow("android-release.yml")
        # Validate both the version-selection and pre-publish verification paths.
        self.assertEqual(workflow.count("type(raw_current_build) is not int"), 2)
        self.assertEqual(workflow.count("raw_current_build < 0"), 2)
        self.assertNotIn('int(current["build_number"])', workflow)

    def test_signed_artifact_manifest_build_number_must_be_a_json_integer(self):
        workflow = self.read_workflow("android-signed-artifact.yml")
        self.assertIn('raw_current_build = current["build_number"]', workflow)
        self.assertIn("type(raw_current_build) is not int", workflow)
        self.assertIn("raw_current_build < 0", workflow)
        self.assertNotIn('int(current["build_number"])', workflow)

    def test_all_build_paths_enforce_fail_closed_vault_source(self):
        gate = ROOT / ".github" / "scripts" / "verify_vault_fail_closed.py"
        gate_text = gate.read_text(encoding="utf-8")
        self.assertIn("createIfMissing: true", gate_text)
        self.assertIn("createIfMissing: false", gate_text)
        self.assertIn("REQUIRED_PROFILE_STORE_TEST_MARKERS", gate_text)

        ci = self.read_workflow("android-ci.yml")
        release = self.read_workflow("android-release.yml")
        signed = self.read_workflow("android-signed-artifact.yml")
        self.assertIn("python3 .github/scripts/verify_vault_fail_closed.py", ci)
        self.assertIn("python3 .github/scripts/verify_vault_fail_closed.py", release)
        self.assertIn("python3 .github/scripts/verify_vault_fail_closed.py", signed)
        self.assertEqual(
            signed.count("python3 .github/scripts/verify_vault_fail_closed.py"),
            1,
        )

        source_copy = release.index("rsync -a --delete")
        vault_gate = release.index("python3 .github/scripts/verify_vault_fail_closed.py")
        self.assertLess(source_copy, vault_gate)

    def test_release_workflows_reject_debuggable_apks_and_check_version_identity(self):
        for workflow_name in ("android-release.yml", "android-signed-artifact.yml"):
            workflow = self.read_workflow(workflow_name)
            self.assertIn("--expect-not-debuggable", workflow)
            self.assertIn("versionName='$EXPECTED_VERSION'", workflow)
            self.assertIn("versionCode='$EXPECTED_BUILD_NUMBER'", workflow)

        verifier = (ROOT / ".github" / "scripts" / "verify_android_backup_policy.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("--expect-not-debuggable", verifier)
        self.assertIn("Release APK is marked android:debuggable=true", verifier)


    def test_signed_artifact_version_identity_parses_pubspec_build_number(self):
        workflow = self.read_workflow("android-signed-artifact.yml")
        self.assertIn('line.startswith("version:")', workflow)
        self.assertIn('version, separator, build_number = version_lines[0].partition("+")', workflow)
        metadata_start = workflow.index("          VERSION_METADATA=")
        metadata_end = workflow.index("          EXPECTED_VERSION=", metadata_start)
        metadata_parser = workflow[metadata_start:metadata_end]
        self.assertIn("if (", metadata_parser)
        self.assertIn("or not build_number.isdigit()", metadata_parser)
        self.assertNotIn('re.search(r"^version:', metadata_parser)


    def test_signed_artifact_workflow_enforces_packaged_backup_policy_and_identity(self):
        workflow = self.read_workflow("android-signed-artifact.yml")
        configure = workflow.index(
            "python3 .github/scripts/configure_android_backup_policy.py"
        )
        build = workflow.index("flutter build apk --release")
        verify = workflow.index(
            "python3 .github/scripts/verify_android_backup_policy.py"
        )
        identity = workflow.index('"$AAPT" dump badging "$APK"')
        artifact = workflow.index("name: iq-tunnel-android-backup-policy-evidence")
        signed_apk = workflow.index("name: iq-tunnel-signed-release-apk")
        self.assertLess(configure, build)
        self.assertGreater(verify, build)
        self.assertGreater(identity, verify)
        self.assertLess(artifact, signed_apk)
        self.assertIn("package: name='com.iqtunnel.iq_tunnel'", workflow)
        self.assertIn("retention-days: 30", workflow)
        self.assertIn("--expect-not-debuggable", workflow)
        self.assertIn("versionName='$EXPECTED_VERSION'", workflow)
        self.assertIn("versionCode='$EXPECTED_BUILD_NUMBER'", workflow)


if __name__ == "__main__":
    unittest.main()
