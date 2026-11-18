from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "deploy" / "windows" / "install.ps1"
INSTALLER_TEST = ROOT / "deploy" / "windows" / "test-install.ps1"


class WindowsHiddenTaskContract(unittest.TestCase):
    def test_installer_uses_a_hidden_wrapper_and_retains_host_executable(self):
        installer = INSTALLER.read_text()
        for required in [
            "Get-FarPilotHostTaskActionSpec",
            "Resolve-FarPilotHostExecutableFromTaskAction",
            "-WindowStyle Hidden",
            "-EncodedCommand",
            "HostExecutable",
        ]:
            self.assertIn(required, installer)
        self.assertIn("$TaskState.HostExecutable", installer)

    def test_installer_regression_asserts_hidden_task_behavior(self):
        test = INSTALLER_TEST.read_text()
        for required in [
            "startup task wrapper is not PowerShell",
            "startup task is not hidden",
            "startup task host executable is wrong",
        ]:
            self.assertIn(required, test)


if __name__ == "__main__":
    unittest.main()
