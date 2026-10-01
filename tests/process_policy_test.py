#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Apache-2.0.
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('policy', ROOT / 'lib/agent_policy/process_policy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PolicyTests(unittest.TestCase):
    def test_new_state_parent_is_secure_under_group_umask(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ablestack-qemu-exec-tools' / 'process-policy'
            old_umask = os.umask(0o002)
            try:
                p.private_directory(path)
            finally:
                os.umask(old_umask)
            self.assertEqual(0o755, path.parent.stat().st_mode & 0o777)
            self.assertEqual(0o700, path.stat().st_mode & 0o777)

    def test_manual_allowlist_byte_identical(self):
        text = '# administrator policy\nFILTER_RPC_ARGS="--allow-rpcs=guest-shutdown,' + ','.join(p.REQUIRED) + '" # retain\nOTHER=value\n'
        self.assertEqual(text, p.rewrite_environment(text)[0])

    def test_allowlist_keeps_unrelated_rights_and_comment(self):
        text = '# comment\n  FILTER_RPC_ARGS="--allow-rpcs=guest-shutdown" # owner\nOTHER=value\n'
        result, _ = p.rewrite_environment(text)
        self.assertIn('guest-shutdown,guest-exec', result)
        self.assertTrue(result.endswith(' # owner\nOTHER=value\n'))
        self.assertEqual(result, p.rewrite_environment(result)[0])

    def test_blocklist_preserves_unrelated_denials(self):
        self.assertEqual(['--block-rpcs=guest-shutdown'], p.rewrite_args(['--block-rpcs=guest-exec,guest-shutdown,guest-file-read']))

    def test_rocky8_effective_blacklist_is_not_ready(self):
        blocked = p.REQUIRED[:8]
        dumped = '[general]\nblacklist=' + ','.join(reversed(blocked)) + '\n'
        self.assertEqual(list(blocked), p.missing_rpcs(dumped, ['--blacklist=' + ','.join(blocked)]))
        self.assertEqual([], p.missing_rpcs('[general]\nblacklist=guest-shutdown\n', ['--blacklist=guest-shutdown']))

    def test_legacy_environment_preserves_hook_and_unrelated_denials(self):
        before = '# vendor defaults\nBLACKLIST_RPC="guest-exec,guest-shutdown" # owner\nFSFREEZE_HOOK_PATHNAME=/etc/qemu-ga/fsfreeze-hook\n'
        after = p.rewrite_legacy_environment(before, {False: ['guest-exec', 'guest-shutdown']})
        self.assertEqual(before.replace('guest-exec,', ''), after)
        self.assertEqual(after, p.rewrite_legacy_environment(after, {False: ['guest-shutdown']}))

    def test_legacy_empty_allow_and_duplicate_aliases(self):
        self.assertEqual(list(p.REQUIRED), p.missing_rpcs('[general]\nwhitelist=\n', ['--whitelist=']))
        self.assertEqual([], p.missing_rpcs('[general]\nwhitelist=\n', []))
        with self.assertRaises(ValueError):
            p.rewrite_args(['--blacklist=guest-exec', '--block-rpcs=guest-ping'])
        with self.assertRaises(ValueError):
            p.missing_rpcs('[general]\nblacklist=guest-exec\nblock-rpcs=guest-ping\n', [])

    def test_legacy_environment_expansion_duplicate_and_mismatch_rejected(self):
        for value in ('BLACKLIST_RPC="$DYNAMIC"\n', 'BLACKLIST_RPC="`command`"\n',
                      'BLACKLIST_RPC=guest-*\n', 'BLACKLIST_RPC=x\nBLACKLIST_RPC=y\n'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.rewrite_legacy_environment(value, {False: ['guest-exec']})
        with self.assertRaisesRegex(RuntimeError, 'Runtime filter differs'):
            p.rewrite_legacy_environment('BLACKLIST_RPC=guest-ping\n', {False: ['guest-exec']})

    def test_legacy_unit_is_repaired_without_replacing_execstart(self):
        unit = 'EnvironmentFile=/etc/sysconfig/qemu-ga\nExecStart=/usr/bin/qemu-ga --blacklist=${BLACKLIST_RPC} -F${FSFREEZE_HOOK_PATHNAME}'
        before = 'BLACKLIST_RPC=guest-exec,guest-shutdown\nFSFREEZE_HOOK_PATHNAME=/etc/qemu-ga/fsfreeze-hook\n'
        with patch.object(p, 'run', return_value=unit), patch.object(p, 'regular'), patch.object(Path, 'read_text', return_value=before):
            changes = p.plan(['--blacklist=guest-exec,guest-shutdown', '-F/etc/qemu-ga/fsfreeze-hook'], None)
        self.assertEqual(before.replace('guest-exec,', '').encode(), changes[Path('/etc/sysconfig/qemu-ga')])

    def test_legacy_ini_and_short_args(self):
        self.assertEqual('[general]\nblacklist=guest-shutdown\n', p.rewrite_ini('[general]\nblacklist=guest-exec,guest-shutdown\n'))
        with patch.object(p, 'run', return_value='EnvironmentFile=/etc/sysconfig/qemu-ga\nExecStart=qemu-ga $FILTER_RPC_ARGS'), patch.object(p, 'regular'), patch.object(Path, 'read_text', return_value='FILTER_RPC_ARGS="-b guest-exec,guest-shutdown"\n'):
            self.assertIn(b'-b guest-shutdown', p.plan(['-b', 'guest-exec,guest-shutdown'], None)[Path('/etc/sysconfig/qemu-ga')])

    def test_ini_preserves_other_sections(self):
        value = '[general]\nblock-rpcs=guest-exec,guest-shutdown\npath=/dev/virtio-ports/org.qemu.guest_agent.0\n[other]\nallow-rpcs=guest-ping\n'
        self.assertEqual(value.replace('guest-exec,', ''), p.rewrite_ini(value))

    def test_empty_allowlist_enables_only_required(self):
        self.assertEqual(['--allow-rpcs=' + ','.join(p.REQUIRED)], p.rewrite_args(['--allow-rpcs=']))

    def test_duplicate_and_expansion_rejected(self):
        for value in ('FILTER_RPC_ARGS="--allow-rpcs=guest-exec --allow-rpcs=guest-ping"\n',
                      'FILTER_RPC_ARGS="$DYNAMIC"\n', 'FILTER_RPC_ARGS=x\nFILTER_RPC_ARGS=y\n',
                      'FILTER_RPC_ARGS="--allow-rpcs=guest-*"\n'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.rewrite_environment(value)

    def test_apply_restore_and_newer_admin_edit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'qga'; config.write_bytes(b'original'); config.chmod(0o640)
            with patch.object(p, 'ROOT', root / 'state'), patch.object(p, 'regular'), patch.object(p, 'restart') as restart, patch.object(p, 'effective', return_value=([], None, [], '')):
                backup = p.apply({config: b'repaired'})
                self.assertEqual(b'repaired', config.read_bytes())
                self.assertEqual(0o640, config.stat().st_mode & 0o777)
                config.write_bytes(b'new-admin-setting')
                with self.assertRaisesRegex(RuntimeError, 'newer administrator'):
                    p.restore(p.ROOT / backup)
                self.assertEqual(b'new-admin-setting', config.read_bytes())
                config.write_bytes(b'repaired')
                p.restore(p.ROOT / backup)
                self.assertEqual(b'original', config.read_bytes())
                self.assertEqual(2, restart.call_count)

    def test_failed_restart_restores_original(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'qga'; config.write_bytes(b'original')
            with patch.object(p, 'ROOT', root / 'state'), patch.object(p, 'regular'), patch.object(p, 'restart', side_effect=[RuntimeError('restart failed'), None]):
                with self.assertRaisesRegex(RuntimeError, 'original policy restored'):
                    p.apply({config: b'repaired'})
                self.assertEqual(b'original', config.read_bytes())

    def test_failed_rollback_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); config = root / 'qga'; config.write_bytes(b'original')
            with patch.object(p, 'ROOT', root / 'state'), patch.object(p, 'regular'), patch.object(p, 'restart', side_effect=RuntimeError('restart failed')):
                with self.assertRaisesRegex(RuntimeError, 'ROLLBACK_REQUIRED'):
                    p.apply({config: b'repaired'})

    def test_rocky_braced_environment_reference(self):
        from unittest.mock import mock_open
        unit = 'EnvironmentFile=/etc/sysconfig/qemu-ga\nExecStart=/usr/bin/qemu-ga ${FILTER_RPC_ARGS}'
        with patch.object(p, 'run', return_value=unit), patch.object(p, 'regular'), patch.object(Path, 'read_text', return_value='FILTER_RPC_ARGS="--block-rpcs=guest-exec"\n'):
            changes = p.plan(['--block-rpcs=guest-exec'], None)
            self.assertIn(Path('/etc/sysconfig/qemu-ga'), changes)

    def test_custom_execstart_is_not_overwritten(self):
        with patch.object(p, 'run', return_value='[Service]\nExecStart=/usr/bin/qemu-ga --allow-rpcs=guest-ping\n'):
            with self.assertRaisesRegex(RuntimeError, 'administrator review'):
                p.plan(['--allow-rpcs=guest-ping'], None)


class ProbeCleanupTests(unittest.TestCase):
    def test_each_file_failure_still_closes_and_deletes(self):
        import base64
        from unittest.mock import Mock
        spec = importlib.util.spec_from_file_location('verify', ROOT / 'bin/vm_process_verify.py')
        v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
        marker = b'ablestack-process-' + b'0' * 32
        for failure in (None, 'guest-file-write', 'guest-file-flush', 'guest-file-seek', 'guest-file-read', 'guest-file-close'):
            probe = v.Verifier.__new__(v.Verifier)
            probe.path = '/dedicated/test.tmp'; probe.pid = None
            calls = []
            def rpc(command, arguments=None):
                calls.append(command)
                if command == failure: raise RuntimeError('injected failure')
                if command == 'guest-info': return {'version':'test', 'supported_commands':[{'name':name,'enabled':True} for name in v.RPCS]}
                if command == 'guest-file-open': return 0
                if command == 'guest-file-write': return {'count':len(marker)}
                if command == 'guest-file-read': return {'buf-b64':base64.b64encode(marker).decode()}
                return {}
            probe.rpc = rpc
            probe.execute = Mock(side_effect=[marker, b''])
            result = {}
            with self.subTest(failure=failure), patch.object(v.uuid, 'uuid4', return_value=Mock(hex='0'*32)):
                if failure:
                    with self.assertRaises(RuntimeError): probe.verify(result)
                else: probe.verify(result)
                self.assertIn('guest-file-close', calls)
                probe.execute.assert_called_with('/usr/bin/rm', ['-f', '--', probe.path])
                self.assertTrue(result['fileCleaned'])


if __name__ == '__main__':
    unittest.main()
