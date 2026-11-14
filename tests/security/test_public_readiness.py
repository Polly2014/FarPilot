import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "public_readiness_audit.py"


class PublicReadinessAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.name", "Synthetic Tester"], cwd=self.repo, check=True)
        subprocess.run(["git", "config", "user.email", "synthetic@example.invalid"], cwd=self.repo, check=True)

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, name: str, content, message="fixture"):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        subprocess.run(["git", "add", name], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=self.repo, check=True)

    def remove_and_commit(self, name: str):
        subprocess.run(["git", "rm", "-q", name], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "remove fixture"], cwd=self.repo, check=True)

    def run_audit(self, repo=None, private=None, summary=None):
        repo = repo or self.repo
        private = private or self.base / "private.json"
        summary = summary or self.base / "summary.json"
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                str(SCANNER),
                "--repo",
                str(repo),
                "--private-report",
                str(private),
                "--summary",
                str(summary),
            ],
            capture_output=True,
            text=True,
        )
        private_data = json.loads(private.read_text()) if private.exists() else None
        summary_data = json.loads(summary.read_text()) if summary.exists() else None
        return result, private_data, summary_data, private, summary

    def test_removed_history_secret_is_detected_without_echoing_value(self):
        fake = "ghp_" + "a" * 36
        self.commit("config.txt", f"token={fake}\n")
        self.remove_and_commit("config.txt")
        result, private, summary, _, _ = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertGreater(summary["counts"]["github_token"], 0)
        combined = result.stdout + result.stderr + json.dumps(private) + json.dumps(summary)
        self.assertNotIn(fake, combined)
        self.assertNotIn("config.txt", combined)

    def test_private_key_is_categorized_without_content(self):
        marker = "-----BEGIN " + "PRIVATE KEY-----\nPRIVATE\n"
        self.commit("fixture.txt", marker)
        result, private, summary, _, _ = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["counts"]["private_key"], 1)
        self.assertNotIn(marker, json.dumps(private))

    def test_clean_repository_is_ready(self):
        self.commit("README.md", "synthetic public documentation\n")
        result, private, summary, private_path, summary_path = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["verdict"], "ready")
        self.assertEqual(private["findings"], [])
        self.assertEqual(stat.S_IMODE(private_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(summary_path.stat().st_mode), 0o600)

    def test_risky_tracked_filenames_are_blocking(self):
        for name in ["prod.env", "certificate.pfx", "archive.p12", "state.sqlite", "cache.db"]:
            self.commit(name, "synthetic\n", message=name)
        result, _, summary, _, _ = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["counts"]["risky_filename"], 5)
        self.assertEqual(summary["verdict"], "blocked")

    def test_credential_patterns_are_categorized(self):
        github = "ghp_" + "b" * 36
        aws = "AKIA" + "C" * 16
        credential_url = "https://synthetic-user:synthetic-pass@example.invalid/path"
        secret_assignment = "client_secret=" + "synthetic-value-123456789"
        self.commit("patterns.txt", "\n".join([github, aws, credential_url, secret_assignment]))
        result, _, summary, _, _ = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        for category in ["github_token", "aws_access_key", "credential_url", "secret_assignment"]:
            self.assertEqual(summary["counts"][category], 1)

    def test_source_placeholders_are_not_treated_as_secrets(self):
        self.commit(
            "example.txt",
            "token={fake}\ntoken=removed\npassword=<redacted>\nclient_secret=$ENV_VALUE\n",
        )
        result, _, summary, _, _ = self.run_audit()
        self.assertEqual(result.returncode, 0, summary)
        self.assertEqual(summary["verdict"], "ready")

    def test_metadata_only_findings_require_review_not_block(self):
        private_ip = "10." + "23.45.67"
        internal_host = "build.internal." + "example.invalid"
        self.commit("metadata.txt", private_ip + "\n" + internal_host + "\n")
        result, _, summary, _, _ = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["verdict"], "review_required")
        self.assertGreater(summary["severity_counts"]["review"], 0)

    def test_binary_blob_is_handled_without_leaking_bytes(self):
        self.commit("binary.dat", b"\x00\xff\xfe" + b"binary" * 100)
        result, private, summary, _, _ = self.run_audit()
        self.assertIn(summary["verdict"], {"ready", "review_required"})
        self.assertNotIn("binarybinary", json.dumps(private))
        self.assertIn(result.returncode, {0, 2})

    def test_duplicate_blob_is_scanned_once(self):
        fake = "ghp_" + "d" * 36
        self.commit("one.txt", fake + "\n")
        (self.repo / "two.txt").write_text(fake + "\n")
        subprocess.run(["git", "add", "two.txt"], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "duplicate blob"], cwd=self.repo, check=True)
        _, _, summary, _, _ = self.run_audit()
        self.assertEqual(summary["counts"]["github_token"], 1)
        self.assertEqual(summary["objects_scanned"], 1)

    def test_output_inside_repo_and_symlink_outputs_are_rejected(self):
        self.commit("README.md", "clean\n")
        inside = self.repo / "audit.json"
        result, _, _, _, _ = self.run_audit(private=inside, summary=self.base / "summary.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside", result.stderr.lower())
        target = self.base / "target.json"
        target.write_text("{}")
        link = self.base / "link.json"
        link.symlink_to(target)
        result, _, _, _, _ = self.run_audit(private=link, summary=self.base / "summary2.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())

        real_parent = self.base / "real-parent"
        real_parent.mkdir()
        linked_parent = self.base / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        result, _, _, _, _ = self.run_audit(
            private=linked_parent / "private.json",
            summary=self.base / "summary3.json",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())

    def test_non_git_repository_is_rejected(self):
        not_repo = self.base / "not-repo"
        not_repo.mkdir()
        result, _, _, _, _ = self.run_audit(repo=not_repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git repository", result.stderr.lower())

    def test_summary_is_sanitized_and_private_report_is_redacted(self):
        fake = "ghp_" + "e" * 36
        self.commit("secret-name.txt", fake)
        _, private, summary, _, _ = self.run_audit()
        self.assertEqual(
            set(summary),
            {
                "schema_version",
                "scanner_version",
                "scanned_at",
                "refs",
                "objects_scanned",
                "counts",
                "severity_counts",
                "gitleaks",
                "verdict",
            },
        )
        finding = private["findings"][0]
        self.assertEqual(set(finding), {"category", "source", "object", "path_hash", "severity"})
        self.assertEqual(len(finding["object"]), 12)
        self.assertEqual(len(finding["path_hash"]), 16)
        self.assertNotIn(fake, json.dumps(private) + json.dumps(summary))
        self.assertNotIn("secret-name.txt", json.dumps(private) + json.dumps(summary))


if __name__ == "__main__":
    unittest.main()
