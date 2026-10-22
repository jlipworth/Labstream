import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from workflow_common import GitHub, WorkflowError, repository_name
from xcode_lease import acquire, inherited, status


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ci = load('ci-wait')
issues = load('issues')
workspace = load('workspace-status')
state = load('workflow-state')
SHA = 'a' * 40


class CIWaitTests(unittest.TestCase):
    def test_only_latest_exact_required_status_counts(self):
        rows = [dict(id=1, context='hygiene', state='failure'), dict(id=2, context='hygiene', state='success')]
        self.assertEqual(ci.evaluate(SHA, rows, [], ['hygiene'])[0], 0)
        self.assertIsNone(ci.evaluate(SHA, rows, [], ['missing'])[0])

    def test_non_success_conclusions_are_not_passes(self):
        for conclusion, expected in [('failure', 1), ('timed_out', 1), ('cancelled', 3), ('skipped', 3), ('neutral', 3), ('success', 0)]:
            row = dict(id=1, name='tests', head_sha=SHA, status='completed', conclusion=conclusion)
            self.assertEqual(ci.evaluate(SHA, [], [row], ['tests'])[0], expected)

    def test_foreign_commit_and_ambiguous_sources_rejected(self):
        row = dict(id=1, name='tests', head_sha='b' * 40, status='completed', conclusion='success')
        with self.assertRaises(WorkflowError):
            ci.evaluate(SHA, [], [row], ['tests'])
        row['head_sha'] = SHA
        with self.assertRaises(WorkflowError):
            ci.evaluate(SHA, [dict(id=1, context='tests', state='success')], [row], ['tests'])

    def test_branch_drift_never_substitutes_new_commit(self):
        client = mock.Mock(repo='owner/repo')
        client.get.return_value = {'object': {'sha': 'b' * 40}}
        self.assertEqual(ci.snapshot(client, SHA, 'feature', ['tests'])[0], 3)
        client.get.assert_called_once()

    def test_wrong_status_sha_rejected(self):
        client = mock.Mock(repo='owner/repo')
        client.get.side_effect = [{'object': {'sha': SHA}}, {'sha': 'b' * 40}]
        with self.assertRaises(WorkflowError):
            ci.snapshot(client, SHA, 'feature', ['tests'])


    def test_malformed_and_empty_required_sets_fail_closed(self):
        for statuses, checks, required in [([{}], [], ['tests']), ([], [{}], ['tests']), ([], [], [])]:
            with self.assertRaises(WorkflowError):
                ci.evaluate(SHA, statuses, checks, required)


class GitHubTests(unittest.TestCase):
    def test_pagination_combines_pages_and_rejects_truncation(self):
        client = GitHub('owner/repo')
        with mock.patch.object(client, 'get', side_effect=[[{}] * 100, [{'end': True}]]):
            self.assertEqual(len(client.pages('endpoint')), 101)
        with mock.patch.object(client, 'get', return_value=[{}] * 100):
            with self.assertRaises(WorkflowError):
                client.pages('endpoint', max_pages=2)
        with mock.patch.object(client, 'get', return_value={}):
            with self.assertRaises(WorkflowError):
                client.pages('endpoint')

    def test_api_failure_is_not_empty_success(self):
        with mock.patch('workflow_common.run', side_effect=WorkflowError('gh failed')):
            with self.assertRaises(WorkflowError):
                GitHub('owner/repo').get('endpoint')

    def test_repository_detection(self):
        for url in ['git@github.com:owner/repo.git', 'https://github.com/owner/repo.git']:
            with mock.patch('workflow_common.git', return_value=url):
                self.assertEqual(repository_name(Path('.')), 'owner/repo')
        with mock.patch('workflow_common.git', return_value='https://user:secret@example.invalid/repo'):
            with self.assertRaises(WorkflowError):
                repository_name(Path('.'))


class DeadlineTests(unittest.TestCase):
    def test_expired_deadline_does_not_call_api(self):
        from workflow_common import DeadlineExceeded
        client = GitHub('owner/repo'); client.deadline = time.monotonic() - 1
        with mock.patch('workflow_common.run') as run:
            with self.assertRaises(DeadlineExceeded): client.get('endpoint')
            run.assert_not_called()


class IssueTests(unittest.TestCase):
    def test_comment_only_match_and_full_comments(self):
        client = mock.Mock(repo='owner/repo')
        row = {'number': 5, 'title': 'Unrelated title', 'state': 'open', 'html_url': 'https://example.invalid/5', 'body': '', 'labels': []}
        client.pages.side_effect = [[], [row]]
        client.get.side_effect = [{'total_count': 1, 'items': [row]}, {'total_count': 0, 'items': []}]
        client.issue.return_value = dict(row, comments=[{'body': 'stalled after wake', 'html_url': 'https://example.invalid/c'}])
        result = issues.find(client, 'stalled wake')
        self.assertTrue(result['results'][0]['comment_match'])
        self.assertEqual(result['results'][0]['comments'][0]['body'], 'stalled after wake')

    def test_incomplete_search_fails_closed(self):
        client = mock.Mock(repo='owner/repo')
        client.pages.return_value = []
        for response in [{'incomplete_results': True}, {'total_count': 101}]:
            client.get.return_value = response
            with self.assertRaises(WorkflowError):
                issues.find(client, 'queue')

    def test_dormant_open_retained_recently_updated_old_closed_excluded(self):
        client = mock.Mock(repo='owner/repo')
        rows = [dict(number=1, title='queue', state='closed', closed_at='2001-01-01'),
                dict(number=2, title='queue', state='open', html_url='https://example.invalid/2')]
        client.pages.side_effect = [rows[:1], rows[1:]]
        client.get.return_value = {'total_count': 0, 'items': []}
        client.issue.return_value = dict(rows[1], body='', comments=[])
        self.assertEqual([r['number'] for r in issues.find(client, 'queue')['results']], [2])


class LocalStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for args in [('init', '-q'), ('config', 'user.name', 'Fixture'), ('config', 'user.email', 'fixture@example.invalid')]:
            subprocess.run(['git', *args], cwd=self.root, check=True)
        (self.root/'file').write_text('one')
        subprocess.run(['git','add','.'], cwd=self.root, check=True)
        subprocess.run(['git','commit','-qm','one'], cwd=self.root, check=True)
        self.head = subprocess.check_output(['git','rev-parse','HEAD'], cwd=self.root, text=True).strip()

    def tearDown(self):
        self.tmp.cleanup()

    def test_receipt_requires_real_evidence_and_not_needed_reason(self):
        s = state.load(self.root/'state.json')
        args = argparse_namespace(command='receipt', kind='validation', name='tests', status='passed', evidence=None, note='')
        with self.assertRaises(WorkflowError):
            state.update(s, args, self.root, self.head)
        (self.root/'run.json').write_text('{}')
        args.evidence = 'run.json'
        state.update(s,args,self.root,self.head)
        self.assertEqual(s['receipts'][0]['head'],self.head)
        args.kind='docs';args.status='not-needed';args.evidence=None
        with self.assertRaises(WorkflowError):
            state.update(s,args,self.root,self.head)

    def test_finding_identity_and_review_transition(self):
        s = state.load(self.root/'state.json')
        args = argparse_namespace(command='finding', action='add', id='F1', summary='race', severity='high', note='found')
        state.update(s,args,self.root,self.head)
        with self.assertRaises(WorkflowError):
            state.update(s,args,self.root,self.head)
        args = argparse_namespace(command='finding', action='set', id='F1', status='fixed', note='changed', commit=self.head, evidence=None)
        state.update(s,args,self.root,self.head)
        self.assertEqual(s['findings'][0]['status'],'fixed')
        args.status='verified'
        with self.assertRaises(WorkflowError):
            state.update(s,args,self.root,self.head)
        self.assertEqual(len(s['findings'][0]['history']),2)

    def test_history_preserves_resolution_and_evidence_on_reopen(self):
        record = state.load(self.root/'state.json')
        state.update(record, argparse_namespace(command='finding', action='add', id='F1', summary='race', severity='high', note='found'), self.root, self.head)
        evidence = self.root/'evidence'; evidence.write_text('reviewed')
        state.update(record, argparse_namespace(command='finding', action='set', id='F1', status='verified', note='reviewed', commit=self.head, evidence=str(evidence)), self.root, self.head)
        state.update(record, argparse_namespace(command='finding', action='set', id='F1', status='open', note='regressed', commit=None, evidence=None), self.root, self.head)
        old = record['findings'][0]['history'][-2]
        self.assertEqual(old['resolution_commit'], self.head)
        self.assertEqual(old['evidence'], str(evidence.resolve()))

    def test_show_marks_verified_findings_and_checkpoint_stale(self):
        store = self.root/'state.json'
        record = state.load(store)
        fingerprint = state.source_fingerprint(self.root)
        record['checkpoint'] = {'fingerprint': fingerprint}
        record['findings'] = [{'id':'F1','status':'verified','history':[], 'fingerprint':fingerprint}]
        state.save(store, record)
        (self.root/'file').write_text('regressed')
        with mock.patch.object(state, 'repository_root', return_value=self.root), mock.patch.object(state, 'print_json') as output:
            self.assertEqual(state.main(['--file', str(store), 'show']), 0)
        report = output.call_args.args[0]
        self.assertTrue(report['checkpoint_stale'])
        self.assertTrue(report['findings'][0]['review_stale'])
        self.assertEqual(report['pending_review'], ['F1'])

    def test_malformed_state_not_overwritten(self):
        p=self.root/'state.json';p.write_text('{}')
        with self.assertRaises(WorkflowError):state.load(p)
        self.assertEqual(p.read_text(),'{}')

    def test_local_workspace_handles_spaces_and_dirty_files(self):
        result=workspace.snapshot(self.root)
        self.assertEqual(len(result['worktrees']),1)
        self.assertFalse(result['worktrees'][0]['dirty'])
        (self.root/'new file').write_text('two')
        self.assertTrue(workspace.snapshot(self.root)['worktrees'][0]['dirty'])

    def test_fingerprint_changes_for_tracked_and_untracked_content(self):
        from workflow_common import source_fingerprint
        baseline=source_fingerprint(self.root)
        (self.root/'file').write_text('changed')
        self.assertNotEqual(baseline,source_fingerprint(self.root))
        (self.root/'file').write_text('one')
        (self.root/'new').write_text('new')
        new=source_fingerprint(self.root)
        self.assertNotEqual(baseline,new)
        (self.root/'new').write_text('different')
        self.assertNotEqual(new,source_fingerprint(self.root))

    def test_commit_reference_to_pr_does_not_break_issue_inventory(self):
        client=mock.Mock(repo='owner/repo')
        client.pages.return_value=[]
        client.issue.return_value={'number':9,'pull_request':{},'html_url':'https://example.invalid/9'}
        with mock.patch.object(workspace,'worktrees',return_value=[{'branch':'work','issue_candidates':[9]}]):
            result=workspace.snapshot(self.root,client)
        self.assertEqual(result['errors'],[])
        self.assertEqual(result['reference_pull_requests'][0]['number'],9)

    def test_remote_failure_is_reported(self):
        client=mock.Mock(repo='owner/repo');client.pages.side_effect=WorkflowError('unavailable')
        result=workspace.snapshot(self.root,client)
        self.assertEqual(result['github'],'unavailable')
        self.assertTrue(result['errors'])


def argparse_namespace(**kwargs):
    from argparse import Namespace
    return Namespace(**kwargs)


class LeaseTests(unittest.TestCase):
    def test_stale_metadata_is_not_active(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock';Path(str(path)+'.json').write_text('{"pid":1}')
            self.assertFalse(status(path)['active'])

    def test_nested_lease_is_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock'
            with acquire(path,'outer',1) as fd:
                self.assertEqual(inherited(path),fd)
                with acquire(path,'inner',0) as nested:self.assertEqual(nested,fd)
                self.assertTrue(status(path)['active'])
            self.assertFalse(status(path)['active'])

    def test_contention_and_release_after_command_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock'
            with acquire(path,'outer',1):
                env=dict(os.environ)
                for key in ['LABSTREAM_XCODE_LEASE_FD','LABSTREAM_XCODE_LEASE_TOKEN']:
                    env.pop(key,None)
                result=subprocess.run([sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'--lock',str(path),'run','--wait-timeout','0','--',sys.executable,'-c','pass'],env=env,capture_output=True)
                self.assertEqual(result.returncode,75)
            result=subprocess.run([sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'--lock',str(path),'run','--',sys.executable,'-c','raise SystemExit(7)'],capture_output=True)
            self.assertEqual(result.returncode,7)
            self.assertFalse(status(path)['active'])

    def test_interrupt_releases_lock_and_stops_owned_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock'
            proc=subprocess.Popen([sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'--lock',str(path),'run','--',sys.executable,'-c','import time; time.sleep(30)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+5
                while not status(path)['active'] and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(status(path)['active'])
                proc.terminate()
                self.assertEqual(proc.wait(timeout=8),130)
                self.assertFalse(status(path)['active'])
            finally:
                if proc.poll() is None:proc.kill();proc.wait()

    def test_interrupt_nested_bounded_runner_releases_descendant_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock'; ready=Path(tmp)/'ready'
            child_code = 'import pathlib,time; pathlib.Path(' + repr(str(ready)) + ').touch(); time.sleep(30)'
            proc=subprocess.Popen([sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'--lock',str(path),'run','--',sys.executable,str(SCRIPTS/'run-bounded-command.py'),'--timeout','60','--output',str(Path(tmp)/'log'),'--',sys.executable,'-c',child_code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                deadline=time.monotonic()+5
                while not ready.exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(ready.exists())
                proc.terminate(); self.assertEqual(proc.wait(timeout=10),130)
                self.assertFalse(status(path)['active'])
            finally:
                if proc.poll() is None:proc.kill();proc.wait()

    def test_bounded_wrapper_preserves_nested_lease(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'lock'
            result=subprocess.run([sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'--lock',str(path),'run','--',sys.executable,str(SCRIPTS/'run-bounded-command.py'),'--timeout','5','--output',str(Path(tmp)/'log'),'--',sys.executable,str(SCRIPTS/'xcodebuild-lease.py'),'run','--wait-timeout','0','--',sys.executable,'-c','print("nested")'],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('nested',(Path(tmp)/'log').read_text())
            self.assertFalse(status(path)['active'])


if __name__ == '__main__':unittest.main()
