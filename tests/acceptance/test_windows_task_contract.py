from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "deploy" / "windows" / "install.ps1"
INSTALLER_TEST = ROOT / "deploy" / "windows" / "test-install.ps1"


class WindowsManagedProcessContract(unittest.TestCase):
    def test_installer_keeps_the_direct_host_task_contract(self):
        installer = INSTALLER.read_text()
        self.assertIn(
            "New-ScheduledTaskAction -Execute $Executable -Argument 'host start'",
            installer,
        )
        self.assertNotIn("Get-FarPilotHostTaskActionSpec", installer)
        self.assertNotIn("-WindowStyle Hidden", installer)

    def test_installer_stops_release_and_alias_processes(self):
        installer = INSTALLER.read_text()
        test = INSTALLER_TEST.read_text()
        self.assertIn("ManagedAliases", installer)
        for required in [
            "managed bin alias process was not stopped",
            "managed current alias process was not stopped",
        ]:
            self.assertIn(required, test)


if __name__ == "__main__":
    unittest.main()
