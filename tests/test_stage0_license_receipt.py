"""Offline receipt regressions; never execute installation, login or customer steps."""
from pathlib import Path
import json
import os
import pty
import re
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFERRED = '''if [[ "${PILOT_ACCEPTANCE_NEW:-0}" == 1 ]]; then
  yhsm_onboarding_state licence-accept "$(pilot_license_digest)" || exit 75
fi

'''

class LicenceReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.candidate = (ROOT / 'bootstrap.sh').read_text()
        cls.receipt = cls.candidate.split('# BEGIN GENERATED LICENCE RECEIPT\n',1)[1].split('# END GENERATED LICENCE RECEIPT',1)[0]
        cls.helper = cls.receipt.split("<<'PY_YHSM_STAGE0_LICENCE'\n",1)[1].split('PY_YHSM_STAGE0_LICENCE\n',1)[0]
        cls.accept = re.search(r'(?ms)^require_pilot_license_acceptance\(\) \{\n.*?^\}\n',cls.candidate).group()

    def run_accept(self, root, digest='a' * 64, explicit='', before='', after=''):
        script = '''set -eu
pilot_license_digest() { printf '%s' "$FIXTURE_DIGEST"; }
show_pilot_notice() { :; }
log_ok() { printf '%s\\n' "$*"; }
log_error() { printf '%s\\n' "$*" >&2; }
''' + self.receipt + self.accept + '\n' + before + '''
require_pilot_license_acceptance
''' + after + '\nprintf SUCCESS_AFTER_LICENCE\\n'
        return subprocess.run(['bash', '-c', script], input='', text=True,
            capture_output=True, timeout=10, env=dict(os.environ, HOME=str(root),
                XDG_STATE_HOME=str(root / 'state'), FIXTURE_DIGEST=digest,
                ACCEPT_PILOT_LICENSES=explicit))

    def receipt_path(self, root):
        return next((root / 'state/yhsm/onboarding').glob('licence-*.json'))

    def test_restarts_and_application_update_reuse_acceptance_headlessly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = self.run_accept(root, explicit='a' * 64)
            self.assertEqual(first.returncode, 0, first.stderr)
            saved = self.receipt_path(root).read_bytes()
            for app_revision in ('release-one', 'release-two'):
                result = self.run_accept(root, before='# ' + app_revision)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('PilotLicenseAcceptance=reused', result.stdout)
                self.assertEqual(self.receipt_path(root).read_bytes(), saved)
            data = json.loads(saved)
            self.assertEqual(set(data), {'schema','binding','kind','digest','accepted','at'})
            self.assertEqual(data['accepted'], True)
            self.assertEqual(self.receipt_path(root).stat().st_mode & 0o777, 0o600)

    def test_changed_digest_requires_new_explicit_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertEqual(self.run_accept(root, explicit='a'*64).returncode, 0)
            result = self.run_accept(root, digest='b'*64)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SUCCESS_AFTER_LICENCE', result.stdout)
            result = self.run_accept(root, digest='b'*64, explicit='a'*64)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('reused', result.stdout)
            self.assertEqual(self.run_accept(root, digest='b'*64, explicit='b'*64).returncode, 0)
            self.assertEqual(len(list((root/'state/yhsm/onboarding').glob('licence-*.json'))), 2)

    def test_first_headless_start_cannot_invent_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_accept(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('SUCCESS_AFTER_LICENCE', result.stdout)
            self.assertFalse((root/'state').exists())

    def test_interactive_yes_is_asked_once_then_reused_without_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = '''set -eu
ACCEPT_PILOT_LICENSES=''
pilot_license_digest() { printf '%s' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; }
show_pilot_notice() { :; }
log_ok() { printf '%s\\n' "$*"; }; log_error() { printf '%s\\n' "$*" >&2; }
yhsm_ui_heading() { printf LICENCE_QUESTION; }
yhsm_ui_text() { printf '%s' "$1"; }
yhsm_ui_prompt() { printf CHOICE_READY; }
''' + self.receipt + self.accept + '\nrequire_pilot_license_acceptance\n'
            master, slave = pty.openpty()
            proc = subprocess.Popen(['bash','-c',script], stdin=slave, stdout=slave, stderr=slave,
                env=dict(os.environ, HOME=str(root), XDG_STATE_HOME=str(root/'state')))
            os.close(slave)
            output = b''
            try:
                deadline = time.monotonic() + 8
                while b'CHOICE_READY' not in output:
                    if time.monotonic() > deadline:
                        self.fail('licence prompt timeout')
                    if select.select([master], [], [], 0.2)[0]:
                        output += os.read(master, 65536)
                os.write(master, b'j\n')
                self.assertEqual(proc.wait(timeout=8), 0, output.decode(errors='replace'))
            finally:
                if proc.poll() is None:
                    proc.kill(); proc.wait()
                os.close(master)
            self.assertEqual(output.count(b'LICENCE_QUESTION'), 1)
            self.assertEqual(self.run_accept(root).returncode, 0)

    def test_corrupt_or_unsafe_receipts_stop_without_replacement(self):
        for condition in ('corrupt', 'mode', 'symlink', 'hardlink'):
            with self.subTest(condition=condition), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                self.assertEqual(self.run_accept(root, explicit='a'*64).returncode, 0)
                path = self.receipt_path(root)
                if condition == 'corrupt':
                    path.write_text('{broken')
                elif condition == 'mode':
                    path.chmod(0o644)
                elif condition == 'symlink':
                    saved = root/'saved'; saved.write_bytes(path.read_bytes())
                    path.unlink(); path.symlink_to(saved)
                else:
                    os.link(path, root/'linked')
                before = path.read_bytes()
                result = self.run_accept(root, explicit='a'*64)
                self.assertEqual(result.returncode, 75, result.stdout+result.stderr)
                self.assertNotIn('SUCCESS_AFTER_LICENCE', result.stdout)
                self.assertEqual(path.read_bytes(), before)

    def test_missing_python_acceptance_is_saved_before_target_phase(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_accept(Path(tmp), explicit='a'*64, before='''
command() {
  if [[ "$*" == '-v python3' ]]; then return 1; fi
  builtin command "$@"
}
''', after='''
[[ "$PILOT_ACCEPTANCE_NEW" == 1 ]]
unset -f command
''' + DEFERRED)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.run_accept(Path(tmp)).returncode, 0)
        self.assertLess(self.candidate.index(DEFERRED),
                        self.candidate.index('yhsm_ui_heading phase.target'))

    def test_only_licence_commands_are_exposed_and_no_other_records_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.run_accept(root, explicit='a'*64)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({p.name.split('-')[0] for p in (root/'state/yhsm/onboarding').iterdir()},
                             {'licence', 'state.lock'})
            result = self.run_accept(root, before='yhsm_onboarding_state telemetry-set accepted')
            self.assertEqual(result.returncode, 75)
            self.assertFalse(list((root/'state/yhsm/onboarding').glob('telemetry-*')))
        self.assertIn(self.helper, self.candidate)

    def test_exact_licence_digest_and_read_only_display(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['bash',str(ROOT/'bootstrap.sh'),'--show-licenses'],
                env=dict(os.environ,HOME=tmp,XDG_STATE_HOME=str(Path(tmp)/'state')),
                capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('PilotLicenseDigest=fd3948443f3b0dea85413d4f1094b1ac5aec90cf739ade8b230d665f60732b38',result.stdout)
            self.assertFalse(list(Path(tmp).iterdir()))
            help_result = subprocess.run(['bash',str(ROOT/'bootstrap.sh'),'--help'],
                env=dict(os.environ,HOME=tmp,YHSM_UI_LANGUAGE='de'),
                capture_output=True,text=True,timeout=10)
            self.assertEqual(help_result.returncode,0,help_result.stderr)
            self.assertNotIn('Zustimmung zu diesen Texten für diesen Lauf.',help_result.stdout)
            self.assertIn('Zustimmung für diesen Host/Benutzer',help_result.stdout)


if __name__ == '__main__':
    unittest.main()
