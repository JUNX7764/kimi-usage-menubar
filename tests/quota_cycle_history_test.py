import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "Sources" / "QuotaCycleHistory.swift"
FIXTURE = ROOT / "tests" / "fixtures" / "quota-cycle-history" / "main.swift"


class QuotaCycleHistoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.runner = Path(cls._tmp.name) / "quota-cycle-history-runner"
        compile_result = subprocess.run(
            ["swiftc", str(MODEL), str(FIXTURE), "-o", str(cls.runner)],
            capture_output=True, text=True)
        if compile_result.returncode != 0:
            raise RuntimeError(
                "failed to compile quota cycle history runner:\n"
                + compile_result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_case(self, case):
        result = subprocess.run([str(self.runner), case],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         f"case {case} failed:\n{result.stderr}{result.stdout}")
        self.assertIn("PASS", result.stdout)

    def test_first_observation(self):
        self.run_case("firstObservation")

    def test_same_window_growth_updates_last_observation(self):
        self.run_case("sameWindowGrowth")

    def test_exact_duplicate_keeps_single_cycle_and_id(self):
        self.run_case("exactDuplicate")

    def test_reset_drift_within_tolerance_stays_same_cycle(self):
        self.run_case("resetDriftWithinTolerance")

    def test_reset_drift_beyond_tolerance_is_not_silently_merged(self):
        self.run_case("resetDriftBeyondTolerance")

    def test_non_finite_used_percent_rejected(self):
        self.run_case("nonFiniteRejected")

    def test_out_of_range_used_percent_rejected(self):
        self.run_case("outOfRangeRejected")

    def test_out_of_order_request_started_at_rejected(self):
        self.run_case("outOfOrderRejected")


if __name__ == "__main__":
    unittest.main()
