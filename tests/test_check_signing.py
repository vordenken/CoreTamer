"""Check signing diagnostics without accessing real keys or timestamp services."""

import contextlib
import io
import os
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import check_signing


class SigningCheckTests(unittest.TestCase):
    def test_certificate_import_trusts_codesign_without_trusting_all_applications(self):
        workflow = (Path(__file__).resolve().parent.parent
                    / ".github/workflows/build-release.yml").read_text()
        start = workflow.index('security import "$RUNNER_TEMP/certificate.p12"')
        end = workflow.index("security set-key-partition-list", start)
        imported = workflow[start:end]
        self.assertIn("-T /usr/bin/codesign", imported)
        self.assertNotIn("-A", imported.split())
        self.assertIn(
            'security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain"',
            workflow,
        )

    def test_workflow_diagnoses_after_import_and_before_build(self):
        workflow = (Path(__file__).resolve().parent.parent
                    / ".github/workflows/build-release.yml").read_text()
        diagnostic = workflow.index("- name: Diagnose signing without and with timestamp")
        self.assertLess(workflow.index("- name: Import signing certificate"), diagnostic)
        self.assertLess(diagnostic, workflow.index("- name: Build universal app"))
        self.assertIn("timeout-minutes: 5\n        run: python3 scripts/check_signing.py",
                      workflow[diagnostic:])

    def run_check(self, identity="test-identity", side_effect=None):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with patch.dict(os.environ, {"CODE_SIGN_IDENTITY": identity}), \
                patch.object(check_signing.subprocess, "run", side_effect=side_effect) as run, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = check_signing.main()
        return status, stdout.getvalue(), stderr.getvalue(), run

    def test_signs_and_verifies_both_probes_and_cleans_up(self):
        def inspect_probe(command, **kwargs):
            probe = Path(command[-1])
            self.assertTrue(probe.is_file())
            self.assertEqual(probe.read_bytes(), Path("/usr/bin/true").read_bytes())
            self.assertTrue(kwargs["check"])

        status, stdout, stderr, run = self.run_check(side_effect=inspect_probe)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(run.call_count, 4)
        commands = [call.args[0] for call in run.call_args_list]
        for index, timestamp in ((0, "--timestamp=none"), (2, "--timestamp")):
            self.assertEqual(commands[index][:-1], [
                "codesign", "--force", "--options", "runtime", "--sign",
                "test-identity", timestamp,
            ])
            self.assertEqual(run.call_args_list[index].kwargs["timeout"], 90)
            self.assertEqual(commands[index + 1][:-1], ["codesign", "--verify", "--strict"])
            self.assertEqual(run.call_args_list[index + 1].kwargs["timeout"], 30)
        self.assertFalse(Path(commands[0][-1]).parent.exists())
        self.assertIn("Signing and verification without timestamp passed", stdout)
        self.assertIn("Signing and verification with timestamp passed", stdout)
        self.assertNotIn("test-identity", stdout)

    def test_rejects_missing_and_ad_hoc_identity(self):
        for identity in ("", "-"):
            with self.subTest(identity=identity):
                status, _, stderr, run = self.run_check(identity=identity)
                self.assertEqual(status, 1)
                self.assertIn("require CODE_SIGN_IDENTITY", stderr)
                run.assert_not_called()

    def test_reports_timeout_at_each_stage_and_cleans_up(self):
        for index in range(4):
            with self.subTest(index=index):
                timeout = 90 if index % 2 == 0 else 30
                status, stdout, stderr, run = self.run_check(
                    side_effect=[None] * index + [subprocess.TimeoutExpired("codesign", timeout)]
                )
                self.assertEqual(status, 1)
                self.assertEqual(run.call_count, index + 1)
                label = "without timestamp" if index < 2 else "with timestamp"
                operation = "signing" if index % 2 == 0 else "verification"
                self.assertIn(f"Probe {operation} {label} timed out after {timeout}", stderr)
                self.assertNotIn(f"Signing and verification {label} passed", stdout)
                self.assertFalse(Path(run.call_args.args[0][-1]).parent.exists())

    def test_reports_nonzero_exit_and_missing_tool(self):
        for error, message in (
            (subprocess.CalledProcessError(9, "codesign"), "failed (exit 9)"),
            (FileNotFoundError("codesign unavailable"), "Cannot run codesign"),
        ):
            with self.subTest(error=error):
                status, _, stderr, run = self.run_check(side_effect=error)
                self.assertEqual(status, 1)
                self.assertIn(message, stderr)
                self.assertEqual(run.call_count, 1)
                self.assertFalse(Path(run.call_args.args[0][-1]).parent.exists())
