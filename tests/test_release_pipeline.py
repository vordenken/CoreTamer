"""Exercise release scripts in disposable repositories without signing or publishing."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Stand-ins record command arguments and produce only the files needed by the scripts.
# Actual compilation, architectures and signatures are also checked by a local build.
MOCK_TOOL = r"""#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["COMMAND_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == os.environ.get("FAIL_TOOL"):
    sys.exit(9)
if name == "xcodebuild":
    derived = Path(args[args.index("-derivedDataPath") + 1])
    app = derived / "Build/Products/Release/CoreTamer.app"
    framework = app / "Contents/Frameworks/Sparkle.framework/Versions/B"
    for directory in ["Updater.app", "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc"]:
        (framework / directory).mkdir(parents=True)
    for binary in ["Contents/MacOS/CoreTamer", "Contents/Helpers/CoreTamerController",
                   "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"]:
        path = app / binary
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
elif name == "ditto":
    if "-c" in args:
        Path(args[-1]).write_text("fake zip")
    else:
        shutil.copytree(args[-2], args[-1])
elif name == "strings":
    print("/Users/example/private" if os.environ.get("EMBED_PATH") else "clean binary")
elif name == "tar":
    work = Path(args[args.index("-C") + 1])
    if "create-dmg" in args[1]:
        tool = work / "create-dmg-1.3.0/create-dmg"
        tool.parent.mkdir(parents=True, exist_ok=True)
        tool.write_text('#!/bin/bash\nprintf dmg > "${@: -2:1}"\n')
    else:
        tool = work / "bin/sign_update"
        tool.parent.mkdir(parents=True, exist_ok=True)
        tool.write_text("#!/bin/bash\n" + os.environ.get(
            "SIGNER_BODY", "printf 'sparkle:edSignature=\"test-signature\" length=\"3\"\\n'") + "\n")
        tool.chmod(0o700)
elif name == "codesign" and os.environ.get("FAIL_EXPORTED_SIGNATURE"):
    if "--verify" in args and args[-1].endswith("/output/CoreTamer.app"):
        sys.exit(9)
"""


class ReleasePipelineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="coretamer-release-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        for name in ("build.sh", "release.sh", "update_appcast.py"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        pin = Path("CoreTamer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        (self.root / pin).parent.mkdir(parents=True)
        shutil.copy2(ROOT / pin, self.root / pin)
        shutil.copy2(ROOT / "appcast.xml", self.root / "appcast.xml")
        self.version("1.2.3")
        self.work = self.root / "work"
        self.work.mkdir()
        self.outputs = self.root / "github-output"
        self.log = self.root / "commands.jsonl"
        self.env = {
            **os.environ,
            "RUNNER_TEMP": str(self.work),
            "GITHUB_OUTPUT": str(self.outputs),
            "REF_NAME": "main",
            "RUN_NUMBER": "20",
            "EVENT_NAME": "push",
            "ACTOR": "maintainer",
            "OUTPUT_DIR": str(self.root / "output"),
            "COMMAND_LOG": str(self.log),
            "SPARKLE_VERSION": "2.10.0",
            "CREATE_DMG_VERSION": "1.3.0",
            # A dummy value, never a real key.
            "SPARKLE_PRIVATE_KEY": "test-only-key",
            "VERSION": "1.2.3",
            "TAG": "v1.2.3",
            "BUILD": "30",
            "CHANNEL": "stable",
            "PRERELEASE": "false",
        }
        for key in ("BUILD_NUMBER", "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM"):
            self.env.pop(key, None)
        self.git("init", "-b", "main")
        self.git("add", "semver.txt")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-m", "Fixture version")
        self.sha = self.git("rev-parse", "HEAD")
        self.env.update(GITHUB_SHA=self.sha, HEAD_SHA=self.sha, BEFORE=self.sha)

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout.strip()

    def version(self, version):
        (self.root / "semver.txt").write_text(
            f"{version}\n---\n### Changes\n- Current change\n\n## 1.0.0\n- Old change\n"
        )

    def run_script(self, command, **env):
        script, *args = command.split()
        return subprocess.run(
            ["bash", str(self.root / "scripts" / script), *args],
            cwd=self.root, env={**self.env, **env}, capture_output=True, text=True,
        )

    def prepare(self, **env):
        result = self.run_script("release.sh prepare", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in self.outputs.read_text().splitlines())

    def mock_tools(self):
        tools = self.root / "bin"
        tools.mkdir()
        for name in ("xcodebuild", "ditto", "xattr", "codesign", "lipo", "file",
                     "strings", "curl", "tar"):
            path = tools / name
            path.write_text(MOCK_TOOL)
            path.chmod(0o700)
        self.env["PATH"] = f"{tools}:{os.path.dirname(sys.executable)}:{os.environ['PATH']}"

    def commands(self, name):
        return [
            command[1:] for command in map(json.loads, self.log.read_text().splitlines())
            if command[0] == name
        ]

    def test_stable_metadata_and_only_current_changelog(self):
        self.assertEqual(self.prepare(), {
            "version": "1.2.3", "tag": "v1.2.3", "channel": "stable",
            "prerelease": "false", "build": "30",
        })
        notes = (self.work / "changelog.txt").read_text()
        self.assertIn("Current change", notes)
        self.assertNotIn("Old change", notes)

    def test_beta_sequence_ignores_malformed_and_other_version_tags(self):
        for tag in ("v1.2.3-beta2", "v1.2.3-beta10", "v1.2.3-betaX", "v1x2x3-beta90"):
            self.git("tag", tag)
        # Existing beta tags are on another commit, so this is the next release, not a retry.
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "--allow-empty", "-m", "Next fixture")
        result = self.prepare(REF_NAME="feature/release", GITHUB_SHA=self.git("rev-parse", "HEAD"))
        self.assertEqual(result["tag"], "v1.2.3-beta11")
        self.assertEqual(result["prerelease"], "true")

    def test_retry_reuses_annotated_tag_on_same_commit(self):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "tag", "-a", "v1.2.3-beta3", "-m", "Fixture beta")
        self.assertEqual(self.prepare(REF_NAME="feature/release")["tag"], "v1.2.3-beta3")

    def test_first_beta(self):
        self.assertEqual(self.prepare(REF_NAME="feature/release")["tag"], "v1.2.3-beta1")

    def test_refuses_to_move_stable_tag(self):
        self.git("tag", "v1.2.3")
        result = self.run_script("release.sh prepare", GITHUB_SHA="f" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to move", result.stderr)

    def test_invalid_metadata_fails_with_context(self):
        for env in ({"REF_NAME": "bugfix/fix"}, {"RUN_NUMBER": "zero"}):
            with self.subTest(env=env):
                result = self.run_script("release.sh prepare", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
        self.version("1.2.3-beta1")
        self.assertIn("Invalid version", self.run_script("release.sh prepare").stderr)
        (self.root / "semver.txt").write_text("1.2.3\n")
        self.assertIn("release notes", self.run_script("release.sh prepare").stderr)

    def test_check_skips_bots_and_unchanged_main(self):
        for env in ({}, {"ACTOR": "github-actions[bot]"}, {"ACTOR": "coretamer-ci-bot[bot]"}):
            with self.subTest(env=env):
                result = self.run_script("release.sh check", **env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.outputs.read_text().splitlines()[-1], "should-build=false")

    def test_check_builds_initial_push_dispatch_feature_and_changed_version(self):
        for env in (
            {"BEFORE": "0" * 40}, {"EVENT_NAME": "workflow_dispatch"},
            {"REF_NAME": "feature/release"},
        ):
            with self.subTest(env=env):
                self.assertEqual(self.run_script("release.sh check", **env).returncode, 0)
                self.assertEqual(self.outputs.read_text().splitlines()[-1], "should-build=true")
        self.version("1.2.4")
        self.git("add", "semver.txt")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit", "-m", "Fixture bump")
        result = self.run_script("release.sh check", HEAD_SHA=self.git("rev-parse", "HEAD"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs.read_text().splitlines()[-1], "should-build=true")

    def test_check_reports_invalid_branch_and_failed_comparison(self):
        for env in ({"REF_NAME": "bugfix/fix"}, {"BEFORE": "not-a-commit"}):
            result = self.run_script("release.sh check", **env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR:", result.stderr)

    def test_release_notes_include_installation_and_beta_warning_only_for_betas(self):
        self.prepare()
        for beta in ("true", "false"):
            result = self.run_script("release.sh notes", PRERELEASE=beta)
            self.assertEqual(result.returncode, 0, result.stderr)
            notes = (self.work / "release_notes.md").read_text()
            self.assertEqual("beta release" in notes, beta == "true")
            self.assertIn("CoreTamer.dmg", notes)
            self.assertIn("not notarized", notes)
            self.assertIn("Current change", notes)
        (self.work / "changelog.txt").unlink()
        self.assertNotEqual(self.run_script("release.sh notes").returncode, 0)

    def test_build_defaults_and_nested_signing_order(self):
        self.mock_tools()
        output = self.root / "output"
        (output / "CoreTamer.app").mkdir(parents=True)
        (output / "CoreTamer.app/obsolete").touch()
        result = self.run_script("build.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = self.commands("xcodebuild")[0]
        self.assertIn("ARCHS=arm64 x86_64", settings)
        self.assertIn("CODE_SIGN_IDENTITY=-", settings)
        self.assertFalse(any(s.startswith("CURRENT_PROJECT_VERSION=") for s in settings))
        self.assertFalse((output / "CoreTamer.app/obsolete").exists())
        self.assertTrue((output / "CoreTamer.zip").exists())
        signed = [c for c in self.commands("codesign") if "--sign" in c]
        self.assertTrue(signed[0][-1].endswith("/Autoupdate"))
        self.assertTrue(signed[-2][-1].endswith("/CoreTamerController"))
        self.assertTrue(signed[-1][-1].endswith("/CoreTamer.app"))
        self.assertTrue(all("--options" in c and "runtime" in c for c in signed))
        self.assertEqual(len(self.commands("lipo")), 4)

    def test_build_accepts_ci_identity_team_and_build_number(self):
        self.mock_tools()
        result = self.run_script(
            "build.sh", BUILD_NUMBER="42", CODE_SIGN_IDENTITY="test-identity",
            DEVELOPMENT_TEAM="TESTTEAM",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = self.commands("xcodebuild")[0]
        for setting in ("CURRENT_PROJECT_VERSION=42", "CODE_SIGN_IDENTITY=test-identity",
                        "DEVELOPMENT_TEAM=TESTTEAM"):
            self.assertIn(setting, settings)
        self.assertTrue(all("--timestamp" in c for c in self.commands("codesign") if "--sign" in c))

    def test_build_rejects_invalid_inputs_before_invoking_tools(self):
        self.mock_tools()
        for number in ("0", "-1", "1.2", "abc"):
            result = self.run_script("build.sh", BUILD_NUMBER=number)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BUILD_NUMBER", result.stderr)
        self.version("1.2.3-beta1")
        self.assertNotEqual(self.run_script("build.sh").returncode, 0)
        self.assertFalse(self.log.exists())

    def test_build_propagates_compiler_signature_and_architecture_failures(self):
        self.mock_tools()
        for tool in ("xcodebuild", "codesign", "lipo"):
            result = self.run_script("build.sh", FAIL_TOOL=tool)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR:", result.stderr)

    def test_build_rejects_private_paths_and_cloud_corrupted_export(self):
        self.mock_tools()
        result = self.run_script("build.sh", EMBED_PATH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local /Users/ path", result.stderr)
        result = self.run_script("build.sh", FAIL_EXPORTED_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-cloud-synced", result.stderr)

    def test_package_creates_and_signs_dmg(self):
        self.mock_tools()
        self.assertNotEqual(self.run_script("release.sh package", CODE_SIGN_IDENTITY="fixture").returncode, 0)
        (self.root / "output/CoreTamer.app").mkdir(parents=True)
        result = self.run_script("release.sh package", CODE_SIGN_IDENTITY="fixture")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / "CoreTamer.dmg").exists())
        self.assertIn("fixture", self.commands("codesign")[0])

    def test_signing_updates_a_copy_and_removes_private_key(self):
        self.mock_tools()
        self.prepare()
        (self.work / "CoreTamer.dmg").write_text("dmg")
        original = (self.root / "appcast.xml").read_bytes()
        result = self.run_script("release.sh sign")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "appcast.xml").read_bytes(), original)
        self.assertIn('sparkle:version="30"', (self.work / "appcast.xml").read_text())
        self.assertEqual(list(self.work.glob("sparkle-key.*")), [])
        self.assertNotIn(self.env["SPARKLE_PRIVATE_KEY"], result.stdout + result.stderr)

    def test_signing_failures_remove_private_key_and_do_not_publish_feed(self):
        self.mock_tools()
        self.prepare()
        (self.work / "CoreTamer.dmg").write_text("dmg")
        for body in ("exit 9", "echo no-signature"):
            result = self.run_script("release.sh sign", SIGNER_BODY=body)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ERROR:", result.stderr)
            self.assertEqual(list(self.work.glob("sparkle-key.*")), [])
            self.assertFalse((self.work / "appcast.xml").exists())

    def test_signing_requires_package_and_matching_pin(self):
        self.mock_tools()
        result = self.run_script("release.sh sign")
        self.assertNotEqual(result.returncode, 0)
        (self.work / "CoreTamer.dmg").touch()
        result = self.run_script("release.sh sign", SPARKLE_VERSION="2.9.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from pin", result.stderr)
        self.assertFalse(self.log.exists())

    def test_unknown_release_command_is_an_error(self):
        result = self.run_script("release.sh unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)

    def test_workflow_contract_and_pinned_tools(self):
        workflow = (ROOT / ".github/workflows/build-release.yml").read_text()
        pin = json.loads((ROOT / "CoreTamer.xcodeproj/project.xcworkspace/"
                         "xcshareddata/swiftpm/Package.resolved").read_text())
        self.assertIn(f"SPARKLE_VERSION: '{pin['pins'][0]['state']['version']}'", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("overwrite_files: false", workflow)
        self.assertIn("bash scripts/test.sh --unit-only", workflow)
        self.assertLess(workflow.index("bash scripts/test.sh --unit-only"),
                        workflow.index("name: Import signing certificate"))
        self.assertLess(workflow.index("name: Publish GitHub Release"),
                        workflow.index("name: Publish canonical appcast"))


if __name__ == "__main__":
    unittest.main()
