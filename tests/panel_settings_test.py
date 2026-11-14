import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = ROOT / "Sources" / "PanelCustomization.swift"
VISUALS = ROOT / "Sources" / "KimiPanelVisuals.swift"
FIXTURE = ROOT / "tests" / "fixtures" / "panel-settings" / "main.swift"

CASES = [
    "layoutModel",
    "chipSizing",
    "slotGeometry",
    "dailyCorners",
    "tokenTransition",
]


class PanelSettingsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.runner = Path(cls._tmp.name) / "panel-settings-runner"
        compile_result = subprocess.run(
            ["swiftc", "-target", "arm64-apple-macos13.0",
             str(LAYOUT), str(VISUALS), str(FIXTURE), "-o", str(cls.runner)],
            capture_output=True, text=True)
        if compile_result.returncode != 0:
            raise RuntimeError(
                "failed to compile panel settings runner:\n" + compile_result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_case(self, case):
        result = subprocess.run([str(self.runner), case],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0,
                         f"case {case} failed:\n{result.stderr}{result.stdout}")
        self.assertIn("PASS", result.stdout)

    def test_layout_model(self):
        self.run_case("layoutModel")

    def test_chip_sizing(self):
        self.run_case("chipSizing")

    def test_slot_geometry(self):
        self.run_case("slotGeometry")

    def test_daily_corners(self):
        self.run_case("dailyCorners")

    def test_token_transition(self):
        self.run_case("tokenTransition")


if __name__ == "__main__":
    unittest.main()
