import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "Sources" / "QuotaCycleHistory.swift"
STORE = ROOT / "Sources" / "QuotaCycleStore.swift"
FIXTURE = ROOT / "tests" / "fixtures" / "quota-cycle-history" / "main.swift"


class QuotaCycleHistoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.runner = Path(cls._tmp.name) / "quota-cycle-history-runner"
        compile_result = subprocess.run(
            ["swiftc", str(MODEL), str(STORE), str(FIXTURE), "-o", str(cls.runner)],
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

    def test_window_change_candidate_requires_independent_confirmation(self):
        self.run_case("windowChangedCandidateConfirms")

    def test_window_change_candidate_rolls_back_on_old_window(self):
        self.run_case("windowChangedCandidateRollsBack")

    def test_window_change_candidate_expires_past_confirmation_window(self):
        self.run_case("windowChangedCandidateExpires")

    def test_replayed_or_too_fast_request_does_not_confirm_candidate(self):
        self.run_case("replayDoesNotConfirm")

    def test_natural_rotation_accepts_zero_to_zero(self):
        self.run_case("naturalRotationZeroToZero")

    def test_full_cycle_natural_rotation(self):
        self.run_case("fullCycleNatural")

    def test_reset_moved_backward_is_rejected(self):
        self.run_case("resetMovedBackwardRejected")

    def test_forward_reset_move_without_drop_stays_pending(self):
        self.run_case("forwardResetMoveWithoutDrop")

    def test_proportion_fix_creates_candidate_and_rolls_back(self):
        self.run_case("proportionFixCandidate")

    def test_gap_across_three_weeks_closes_single_cycle(self):
        self.run_case("gapAcrossThreeWeeks")

    def test_first_observation_mid_cycle_is_incomplete(self):
        self.run_case("firstObservationMidCycle")

    def test_scope_key_round_trip_with_restart(self):
        self.run_case("scopeRoundTrip")

    def test_scope_isolation_between_fake_api_keys(self):
        self.run_case("scopeIsolation")

    def test_salt_and_permission_enforcement(self):
        self.run_case("scopePermissions")

    def test_corrupt_future_and_time_regression_files_preserved(self):
        self.run_case("corruptAndFuturePreserved")

    def test_writer_failure_keeps_last_good_disk_state(self):
        self.run_case("writerFailureKeepsLastGood")

    def test_save_dedup_and_heartbeat_semantics(self):
        self.run_case("saveDedupAndHeartbeat")


if __name__ == "__main__":
    unittest.main()
