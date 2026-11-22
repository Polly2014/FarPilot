from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "deploy" / "windows" / "install.ps1"
INSTALLER_TEST = ROOT / "deploy" / "windows" / "test-install.ps1"


class WindowsManagedProcessContract(unittest.TestCase):
    def test_installer_uses_the_runner_task_contract(self):
        installer = INSTALLER.read_text()
        self.assertIn(
            "New-ScheduledTaskAction -Execute $Executable -Argument 'run'",
            installer,
        )
        self.assertIn("farpilot-host-runner.exe", installer)
        self.assertNotIn("-WindowStyle Hidden", installer)

    def test_installer_stops_release_and_alias_processes(self):
        installer = INSTALLER.read_text()
        test = INSTALLER_TEST.read_text()
        self.assertIn("ManagedAliases", installer)
        for required in [
            "managed bin alias CLI process was not stopped",
            "managed current alias CLI process was not stopped",
            "managed release runner process was not stopped",
            "managed bin alias runner process was not stopped",
            "managed current alias runner process was not stopped",
            "external same-name runner process was stopped",
        ]:
            self.assertIn(required, test)


if __name__ == "__main__":
    unittest.main()
