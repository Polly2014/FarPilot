import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "acceptance"))

import make_failure_candidate
import make_loopback_manifest

TARGETS = {
    "linux-x86_64": "farpilot-linux-x86_64",
    "linux-aarch64": "farpilot-linux-aarch64",
    "macos-x86_64": "farpilot-macos-x86_64",
    "macos-aarch64": "farpilot-macos-aarch64",
    "windows-x86_64": "farpilot-windows-x86_64.exe",
}


class AcceptanceManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.assets = {}
        for target, name in TARGETS.items():
            path = self.root / name
            path.write_bytes((target + "\n").encode())
            self.assets[target] = path
        self.gateway = self.root / "install-gateway.sh"
        self.gateway.write_text("#!/bin/sh\nexit 0\n")

    def tearDown(self):
        self.temp.cleanup()

    def test_manifest_uses_only_loopback_https_urls_and_exact_digests(self):
        manifest = make_loopback_manifest.build_manifest(
            "0.1.1",
            "https://127.0.0.1:18443/",
            self.assets,
            self.gateway,
        )
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "0.1.1")
        self.assertEqual(manifest["tag"], "v0.1.1")
        self.assertEqual(set(manifest["assets"]), set(TARGETS))
        for target, path in self.assets.items():
            record = manifest["assets"][target]
            self.assertEqual(
                record["sha256"], hashlib.sha256(path.read_bytes()).hexdigest()
            )
            self.assertEqual(
                record["url"], f"https://127.0.0.1:18443/{path.name}"
            )
        self.assertEqual(
            manifest["installers"]["gateway"]["url"],
            "https://127.0.0.1:18443/install-gateway.sh",
        )

    def test_non_loopback_or_non_https_base_url_is_rejected(self):
        for url in [
            "http://127.0.0.1:18443/",
            "https://localhost:18443/",
            "https://example.com/",
            "https://127.0.0.2:18443/",
        ]:
            with self.subTest(url=url), self.assertRaises(SystemExit):
                make_loopback_manifest.build_manifest(
                    "0.1.1", url, self.assets, self.gateway
                )

    def test_manifest_rejects_missing_target_and_symlink(self):
        incomplete = dict(self.assets)
        incomplete.pop("linux-aarch64")
        with self.assertRaises(SystemExit):
            make_loopback_manifest.build_manifest(
                "0.1.1", "https://127.0.0.1:18443/", incomplete, self.gateway
            )
        link = self.root / "linked"
        link.symlink_to(self.assets["linux-x86_64"])
        linked = dict(self.assets)
        linked["linux-x86_64"] = link
        with self.assertRaises(SystemExit):
            make_loopback_manifest.build_manifest(
                "0.1.1", "https://127.0.0.1:18443/", linked, self.gateway
            )


class FailureCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_gateway_candidate_reports_version_then_fails_startup(self):
        path = self.root / "farpilot"
        make_failure_candidate.write_candidate(path, "0.1.2", "gateway-start")
        version = subprocess.run(
            [path, "--version"], check=True, capture_output=True, text=True
        )
        self.assertEqual(version.stdout, "farpilot 0.1.2\n")
        started = subprocess.run([path, "gateway", "serve"], capture_output=True)
        self.assertEqual(started.returncode, 42)

    def test_cli_candidate_fails_only_after_activation(self):
        staged = self.root / "staged-farpilot"
        target = self.root / "bin" / "farpilot"
        target.parent.mkdir()
        make_failure_candidate.write_candidate(staged, "0.1.2", "cli-post-activation")
        env = os.environ | {
            "FARPILOT_ACCEPTANCE_TARGET": str(target),
            "FARPILOT_ACCEPTANCE_FAIL_AFTER_ACTIVATION": "1",
        }
        self.assertEqual(
            subprocess.run(
                [staged, "--version"], env=env, check=True, capture_output=True, text=True
            ).stdout,
            "farpilot 0.1.2\n",
        )
        target.write_bytes(staged.read_bytes())
        target.chmod(0o755)
        self.assertEqual(subprocess.run([target, "--version"], env=env).returncode, 42)


if __name__ == "__main__":
    unittest.main()
