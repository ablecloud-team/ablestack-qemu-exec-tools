import pathlib, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class RelocatedRetryTest(unittest.TestCase):
    def test_source_runtime_absence_stays_alive_and_requests_cloud_relocation(self):
        source = (ROOT / 'lib/ftctl/dr_scheduler.sh').read_text()
        start = source.index('      if [[ "${rc}" == "98"')
        block = source[start:source.index('      if [[ "${rc}" == "99"', start)]
        for code, recovery, error in [('98', 'PENDING', 'DR_SOURCE_SITE_UNAVAILABLE'),
                                      ('110', 'REQUIRED', 'DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE')]:
            with tempfile.TemporaryDirectory() as directory:
                output = pathlib.Path(directory) / 'updates'
                script = r'''set -euo pipefail
rc="$1"; output="$2"; plan=plan; cycle_run=producer; sequence=9
state_path=run; status_path=status; sequence_path=sequence
source_retry_attempt=0; cycle_type=incremental; cycle_request_bound=true; control_generation=1
ftctl_now_iso8601() { echo now; }
ftctl_dr_runtime_state_get_from_path() { :; }
ftctl_dr_scheduler_source_retry_delay() { echo 15; }
ftctl_state_set_path() { printf '%s\n' "$@" >> "$output"; }
ftctl_dr_scheduler_update_state() { printf '%s\n' "$@" >> "$output"; }
ftctl_dr_scheduler_iso_from_epoch() { echo later; }
ftctl_log_event() { :; }
ftctl_dr_scheduler_sleep_or_stop() { echo bounded-wait >> "$output"; }
for attempt in 1; do
''' + block + '\ndone\n'
                subprocess.run(['bash', '-c', script, 'retry-test', code, str(output)], check=True)
                text = output.read_text()
                self.assertIn('scheduler_recovery_state=' + recovery, text)
                self.assertIn('error_code=' + error, text)
                self.assertIn('requested_cycle_state=PENDING', text)
                self.assertIn('pending_source_sequence=9', text)
                self.assertIn('bounded-wait', text)

if __name__ == '__main__':
    unittest.main()
