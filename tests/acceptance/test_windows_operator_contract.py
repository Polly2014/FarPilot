from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "acceptance" / "windows_stage05.ps1"


class WindowsStage05Contract(unittest.TestCase):
    def test_operator_script_is_pinned_sanitized_and_non_evaluating(self):
        text = SCRIPT.read_text()
        for required in [
            "43676588975",
            "farpilot-windows-x86_64-fd71c316e08f50a8e0f1e5fbf3a15d4238792b41",
            "4BCAC3FD7D3E56D214190A02EA1ACDC67B8C68F72E815A43D3D76B0387A72698",
            "2DFE35317AECD898EA1F2DD9A64E8167D597207533FC674817D53526C6ADC36F",
            "e252a0e1870bcffc31c92ba72101149839f2a276",
            "-LocalPackagePath",
            "Start-ScheduledTask",
            "hidden_task",
            "ConvertTo-Json",
        ]:
            self.assertIn(required, text)
        lowered = text.lower()
        self.assertNotIn("invoke-expression", lowered)
        self.assertNotIn("| iex", lowered)
        self.assertNotIn("host-identity.json).read", lowered)
        self.assertNotIn("ssh_public_key", lowered)


if __name__ == "__main__":
    unittest.main()
