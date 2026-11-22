import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "release_manifest.py"
VALIDATOR = ROOT / "scripts" / "validate_release_assets.py"
TARGETS = {
    "linux-x86_64": "farpilot-linux-x86_64",
    "linux-aarch64": "farpilot-linux-aarch64",
    "macos-x86_64": "farpilot-macos-x86_64",
    "macos-aarch64": "farpilot-macos-aarch64",
    "windows-x86_64": "farpilot-windows-x86_64.zip",
}


class ReleaseManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        for target, name in TARGETS.items():
            (self.directory / name).write_bytes((target + "\n").encode())
        (self.directory / "install-gateway.sh").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )

    def tearDown(self):
        self.temp.cleanup()

    def generator_command(self, version="0.2.0", output=None):
        output = output or self.directory / "manifest.json"
        command = [
            sys.executable,
            str(GENERATOR),
            "--version",
            version,
            "--repository",
            "Polly2014/FarPilot",
            "--output",
            str(output),
        ]
        for target, name in TARGETS.items():
            command.extend(["--asset", f"{target}={self.directory / name}"])
        command.extend(
            [
                "--installer",
                f"gateway={self.directory / 'install-gateway.sh'}",
            ]
        )
        return command

    def generate(self, output=None):
        output = output or self.directory / "manifest.json"
        subprocess.run(self.generator_command(output=output), check=True)
        return output

    def validator_result(self, manifest=None, reported_version="0.2.0"):
        manifest = manifest or self.directory / "manifest.json"
        return subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--manifest",
                str(manifest),
                "--release-dir",
                str(self.directory),
                "--reported-version",
                reported_version,
            ],
            capture_output=True,
            text=True,
        )

    def test_manifest_has_exact_assets_urls_formats_and_digests(self):
        manifest_path = self.generate()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["version"], "0.2.0")
        self.assertEqual(manifest["tag"], "v0.2.0")
        self.assertEqual(set(manifest["assets"]), set(TARGETS))
        for target, name in TARGETS.items():
            expected = hashlib.sha256((self.directory / name).read_bytes()).hexdigest()
            record = manifest["assets"][target]
            self.assertEqual(record["sha256"], expected)
            self.assertEqual(
                record["url"],
                f"https://github.com/Polly2014/FarPilot/releases/download/v0.2.0/{name}",
            )
        self.assertEqual(manifest["assets"]["windows-x86_64"]["format"], "zip")
        for target in set(TARGETS) - {"windows-x86_64"}:
            self.assertEqual(manifest["assets"][target]["format"], "binary")
        installer = manifest["installers"]["gateway"]
        self.assertTrue(installer["url"].endswith("/v0.2.0/install-gateway.sh"))
        self.assertEqual(
            installer["sha256"],
            hashlib.sha256((self.directory / "install-gateway.sh").read_bytes()).hexdigest(),
        )
        self.assertTrue(manifest_path.read_bytes().endswith(b"\n"))

    def test_generator_output_is_deterministic(self):
        first = self.generate(self.directory / "first.json")
        second = self.generate(self.directory / "second.json")
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_invalid_version_is_rejected(self):
        result = subprocess.run(
            self.generator_command("release/latest"), capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("semantic version", result.stderr)

    def test_missing_required_target_file_is_rejected(self):
        command = self.generator_command()
        missing = str(self.directory / TARGETS["linux-aarch64"])
        command[command.index(f"linux-aarch64={missing}")] = (
            f"linux-aarch64={missing}.missing"
        )
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)

    def test_generator_rejects_duplicate_resolved_source_paths(self):
        command = self.generator_command()
        original = self.directory / TARGETS["linux-x86_64"]
        duplicate = self.directory / "subdir" / ".." / TARGETS["linux-x86_64"]
        (self.directory / "subdir").mkdir()
        argument = f"linux-aarch64={self.directory / TARGETS['linux-aarch64']}"
        command[command.index(argument)] = f"linux-aarch64={duplicate}"
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unique source path", result.stderr)
        self.assertTrue(original.is_file())

    def test_generator_rejects_duplicate_output_basenames(self):
        first = self.directory / "first" / "farpilot-shared"
        second = self.directory / "second" / "farpilot-shared"
        first.parent.mkdir()
        second.parent.mkdir()
        first.write_bytes(b"first")
        second.write_bytes(b"second")
        command = self.generator_command()
        first_argument = f"linux-x86_64={self.directory / TARGETS['linux-x86_64']}"
        second_argument = f"linux-aarch64={self.directory / TARGETS['linux-aarch64']}"
        command[command.index(first_argument)] = f"linux-x86_64={first}"
        command[command.index(second_argument)] = f"linux-aarch64={second}"
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unique output filename", result.stderr)

    def test_generator_rejects_asset_and_installer_filename_collision(self):
        collision_dir = self.directory / "installer"
        collision_dir.mkdir()
        collision = collision_dir / TARGETS["linux-x86_64"]
        collision.write_bytes(b"installer")
        command = self.generator_command()
        installer_argument = f"gateway={self.directory / 'install-gateway.sh'}"
        command[command.index(installer_argument)] = f"gateway={collision}"
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unique output filename", result.stderr)

    def test_generator_rejects_symlink_source(self):
        source = self.directory / TARGETS["linux-x86_64"]
        link = self.directory / "linked-linux-x86_64"
        link.symlink_to(source)
        command = self.generator_command()
        argument = f"linux-x86_64={source}"
        command[command.index(argument)] = f"linux-x86_64={link}"
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stderr)

    def test_generator_rejects_repository_dot_segments(self):
        for repository in ("../..", "./FarPilot", "Polly2014/..", "./repo"):
            command = self.generator_command()
            repository_index = command.index("--repository") + 1
            command[repository_index] = repository
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("owner/name", result.stderr)

    def test_validator_rejects_reported_version_mismatch(self):
        self.generate()
        result = self.validator_result(reported_version="0.2.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version mismatch", result.stderr)

    def test_validator_rejects_non_https_or_non_github_url(self):
        manifest_path = self.generate()
        for bad_url in (
            "http://github.com/Polly2014/FarPilot/releases/file",
            "https://downloads.example/farpilot-linux-x86_64",
        ):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["assets"]["linux-x86_64"]["url"] = bad_url
            candidate = self.directory / "bad-url.json"
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            result = self.validator_result(candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("HTTPS github.com", result.stderr)

    def test_validator_rejects_duplicate_asset_urls_and_filenames(self):
        manifest_path = self.generate()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["assets"]["macos-aarch64"] = dict(
            manifest["assets"]["linux-x86_64"]
        )
        candidate = self.directory / "duplicate-assets.json"
        candidate.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.validator_result(candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unique asset URL", result.stderr)

    def test_validator_rejects_duplicate_decoded_asset_filenames(self):
        manifest_path = self.generate()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        record = manifest["assets"]["macos-aarch64"]
        record["url"] = (
            "https://github.com/Polly2014/FarPilot/releases/download/"
            "v0.2.0/farpilot-linux-x86_%36%34"
        )
        candidate = self.directory / "duplicate-filenames.json"
        candidate.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.validator_result(candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unique asset filename", result.stderr)

    def test_validator_rejects_gateway_asset_filename_collision(self):
        manifest_path = self.generate()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["installers"]["gateway"] = {
            "url": manifest["assets"]["linux-x86_64"]["url"],
            "sha256": manifest["assets"]["linux-x86_64"]["sha256"],
        }
        candidate = self.directory / "gateway-collision.json"
        candidate.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.validator_result(candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("collides with asset filename", result.stderr)

    def test_validator_rejects_repository_path_tricks(self):
        manifest_path = self.generate()
        bad_urls = (
            "https://github.com/../FarPilot/releases/download/v0.2.0/farpilot-linux-x86_64",
            "https://github.com/Polly2014/../releases/download/v0.2.0/farpilot-linux-x86_64",
            "https://github.com/Polly2014%2FFarPilot/releases/download/v0.2.0/farpilot-linux-x86_64",
            "https://github.com/Polly2014/FarPilot/releases/download/v0.2.0/farpilot%2Flinux-x86_64",
            "https://github.com/Polly2014/FarPilot/releases/download/v0.2.0/farpilot%5Clinux-x86_64",
        )
        for index, bad_url in enumerate(bad_urls):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["assets"]["linux-x86_64"]["url"] = bad_url
            candidate = self.directory / f"path-trick-{index}.json"
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            result = self.validator_result(candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release URL path", result.stderr)

    def test_validator_rejects_inconsistent_repository(self):
        manifest_path = self.generate()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        record = manifest["assets"]["macos-aarch64"]
        record["url"] = record["url"].replace(
            "Polly2014/FarPilot", "OtherOwner/FarPilot"
        )
        candidate = self.directory / "inconsistent-repository.json"
        candidate.write_text(json.dumps(manifest), encoding="utf-8")
        result = self.validator_result(candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("consistent owner/repository", result.stderr)

    def test_validator_rejects_malformed_digest(self):
        manifest_path = self.generate()
        for digest in ("a" * 63, "A" * 64, "g" * 64):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["assets"]["linux-x86_64"]["sha256"] = digest
            candidate = self.directory / "bad-digest.json"
            candidate.write_text(json.dumps(manifest), encoding="utf-8")
            result = self.validator_result(candidate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid SHA-256", result.stderr)

    def test_validator_rejects_digest_mismatch(self):
        manifest_path = self.generate()
        (self.directory / TARGETS["linux-x86_64"]).write_bytes(b"tampered")
        result = self.validator_result(manifest_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest mismatch", result.stderr)

    def test_validator_rejects_missing_release_file(self):
        manifest_path = self.generate()
        (self.directory / TARGETS["linux-x86_64"]).unlink()
        result = self.validator_result(manifest_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("file is missing", result.stderr)

    def test_validator_accepts_complete_release(self):
        self.generate()
        result = self.validator_result()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
