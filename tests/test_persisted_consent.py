"""Offline regressions for consent in the immutable public starter."""
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

class PublicConsentTests(unittest.TestCase):
    def test_persisted_denial_overrides_inherited_opt_in(self):
        text=(ROOT/'bootstrap.sh').read_text()
        function='stage0_feedback_allowed() {'+text.split('stage0_feedback_allowed() {',1)[1].split('\n}\n',1)[0]+'\n}\n'
        with tempfile.TemporaryDirectory() as tmp:
            helper=Path(tmp)/'helper.py'
            helper.write_text(text.split("<<'PY_YHSM_ONBOARDING_STATE'\n",1)[1].split("\nPY_YHSM_ONBOARDING_STATE",1)[0])
            env=dict(os.environ,HOME=tmp,XDG_STATE_HOME=str(Path(tmp)/'state'),FIXTURE_HELPER=str(helper),YHSM_AUTOMATIC_ISSUE_FEEDBACK='1')
            subprocess.run(['python3','-I','-B',str(helper),'telemetry-set','denied'],env=env,check=True,capture_output=True)
            script='yhsm_onboarding_state() { python3 -I -B "$FIXTURE_HELPER" "$@"; };\n'+function+'\n! stage0_feedback_allowed\n'
            result=subprocess.run(['bash','-c',script],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_stage0_issue_permission_is_independent_of_repository_access(self):
        text=(ROOT/'bootstrap.sh').read_text()
        function='verify_private_repository_access() {'+text.split('verify_private_repository_access() {',1)[1].split('\n}\n',1)[0]+'\n}\n'
        for feedback,smoke in ((0,0),(1,0),(0,1)):
            with self.subTest(feedback=feedback,smoke=smoke), tempfile.TemporaryDirectory() as tmp:
                script='''set -eu
TARGET_REPO=example/customer
log_ok() { :; }; log_error() { :; }
run_interruptible_child() { "$@"; }
gh() {
  if [[ "$1" == issue ]]; then printf issue >> "$FIXTURE_CALLS"; return 13; fi
  [[ "$1" == repo && "$2" == view ]]
}
'''+function+'\nverify_private_repository_access\n'
                calls=Path(tmp)/'calls'
                result=subprocess.run(['bash','-c',script],env=dict(os.environ,
                    YHSM_AUTOMATIC_ISSUE_FEEDBACK=str(feedback),ISSUE_SMOKE_TEST=str(smoke),
                    FIXTURE_CALLS=str(calls)),capture_output=True,text=True)
                self.assertEqual(result.returncode,13 if feedback or smoke else 0,result.stderr)
                self.assertEqual(calls.exists(),bool(feedback or smoke))

    def test_stage0_licence_acceptance_is_reused_without_a_terminal(self):
        text=(ROOT/'bootstrap.sh').read_text()
        function='require_pilot_license_acceptance() {'+text.split('require_pilot_license_acceptance() {',1)[1].split('\n}\n',1)[0]+'\n}\n'
        with tempfile.TemporaryDirectory() as tmp:
            script='''set -eu
yhsm_onboarding_state() { python3 -I -B "$FIXTURE_HELPER" "$@"; }
pilot_license_digest() { printf '%s' "$FIXTURE_DIGEST"; }
show_pilot_notice() { :; }
log_ok() { printf '%s\\n' "$*"; }
log_error() { printf '%s\\n' "$*" >&2; }
'''+function+'\nrequire_pilot_license_acceptance\n'
            helper=Path(tmp)/'helper.py'
            helper.write_text(text.split("<<'PY_YHSM_ONBOARDING_STATE'\n",1)[1].split("\nPY_YHSM_ONBOARDING_STATE",1)[0])
            env=dict(os.environ,HOME=tmp,FIXTURE_HELPER=str(helper),
                     FIXTURE_DIGEST='a'*64,ACCEPT_PILOT_LICENSES='a'*64)
            env.pop('XDG_STATE_HOME',None)
            first=subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
            self.assertEqual(first.returncode,0,first.stdout+first.stderr)
            env['ACCEPT_PILOT_LICENSES']=''
            second=subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
            self.assertEqual(second.returncode,0,second.stdout+second.stderr)
            self.assertIn('reused',second.stdout)
            env['FIXTURE_DIGEST']='b'*64
            changed=subprocess.run(['bash','-c',script],env=env,text=True,capture_output=True)
            self.assertNotEqual(changed.returncode,0)


if __name__ == "__main__": unittest.main()
