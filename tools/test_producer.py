#!/usr/bin/env python3
"""制作端离线集成测试：真实 Git 来源、v1 往返、输入与历史边界。"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent
PROJECT = None


def run(*args, cwd=None, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)


def git(root, *args):
    return run('git', '-c', 'user.name=Producer Test', '-c', 'user.email=test@example.invalid',
               '-C', str(root), *args).stdout.strip()


class ProducerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dependency-test-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / 'project'
        self.work = self.base / 'work'
        self.root.mkdir()
        (self.root / 'tools').mkdir()
        for name in ('ci_dependencies.py', 'tree_sha256.py'):
            shutil.copyfile(PROJECT / 'tools' / name, self.root / 'tools' / name)
        (self.root / 'patches').mkdir()
        shutil.copyfile(PROJECT / 'patches/backport_manifest.sh', self.root / 'patches/backport_manifest.sh')
        upstream = self.base / 'upstream'
        upstream.mkdir()
        git(upstream, 'init', '-q')
        (upstream / 'kernel/time').mkdir(parents=True)
        timer = upstream / 'kernel/time/timer.c'
        timer.write_text('int timer = 0;\n')
        git(upstream, 'add', '.')
        git(upstream, 'commit', '-qm', 'baseline')
        self.baseline = git(upstream, 'rev-parse', 'HEAD')
        timer.write_text('int timer = 1;\n')
        git(upstream, 'commit', '-qam', 'timer: improve fast path')
        commit = git(upstream, 'rev-parse', 'HEAD')
        date = git(upstream, 'show', '-s', '--format=%cs', commit)
        patch = run('git', '-C', str(upstream), 'show', '--format=', commit).stdout
        patch_id = subprocess.run(['git', 'patch-id', '--stable'], input=patch, text=True,
                                  capture_output=True, check=True, timeout=10).stdout.split()[0]
        self.pins = {
            'COMMON_REPO': 'https://example.invalid/common', 'COMMON_COMMIT': self.baseline,
            'ENABLE_BACKPORT_AUDIT': '1', 'ENABLE_SELECTED_BACKPORTS': '0',
            'SELECTED_BACKPORT_MANIFEST': 'patches/backports/selected.tsv',
            'BACKPORT_AUDIT_SNAPSHOT': date, 'CI_TOOLCHAIN_NAME': 'fixture', 'CI_CLANG_REVISION': 'fixture',
            'AOSP_BACKPORT_AUDIT_SOURCE_DIR': 'sources/aosp',
            'LINUX_STABLE_AUDIT_SOURCE_DIR': 'sources/stable',
            'LINUX_MAINLINE_AUDIT_SOURCE_DIR': 'sources/mainline',
            'KBUILD_AUDIT_SOURCE_DIR': 'sources/kbuild',
            'LINUX_STABLE_AUDIT_REPO': 'https://example.invalid/stable',
            'LINUX_MAINLINE_AUDIT_REPO': 'https://example.invalid/mainline',
            'LINUX_MAINLINE_AUDIT_COMMIT': commit,
            'ENABLE_TIMER_BASE_FAST_PATH': '1', 'TIMER_BASE_FAST_PATH_COMMIT': commit,
            'TIMER_BASE_FAST_PATH_COMMIT_DATE': date, 'TIMER_BASE_FAST_PATH_PATCH_ID': patch_id,
            'ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX': '0', 'ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX': '0',
        }
        for source, url in [('aosp', self.pins['COMMON_REPO']),
                            ('stable', self.pins['LINUX_STABLE_AUDIT_REPO']),
                            ('mainline', self.pins['LINUX_MAINLINE_AUDIT_REPO'])]:
            target = self.work / 'sources' / source
            target.parent.mkdir(parents=True, exist_ok=True)
            if source == 'mainline':
                run('git', 'clone', '-q', '--bare', '--no-local', str(upstream), str(target))
                git(target, 'remote', 'set-url', 'origin', url)
            else:
                run('git', 'init', '-q', '--bare', str(target))
                git(target, 'remote', 'add', 'origin', url)
        (self.root / '.env').write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in self.pins.items()))
        (self.root / 'LICENSE').write_text('Synthetic public test fixture.\n')
        git(self.root, 'init', '-q')
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'public fixture')
        self.commit = git(self.root, 'rev-parse', 'HEAD')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('GIT_', 'PROJECT_', 'DEPENDENCY_', 'BACKPORT_'))}
        self.env.update(PROJECT_DIR=str(self.root), PROJECT_COMMIT=self.commit,
                        DEPENDENCY_WORK_DIR=str(self.work), PYTHONDONTWRITEBYTECODE='1')

    def shell(self, script, check=True):
        return run('bash', '-euc', '. "$1/context.sh"; load_context; ' + script,
                   'test', str(TOOLS), cwd=self.base, env=self.env, check=check)

    def test_source_audit_export_pack_and_consumer(self):
        result = self.shell('python3 -I "$TOOLS_DIR/producer.py" export-backports --output "$DEPENDENCY_WORK_DIR/export"; '
                            'export BACKPORT_BUNDLE_MANIFEST_SHA256="$(sha256sum "$DEPENDENCY_WORK_DIR/export/manifest.json" | cut -d " " -f1)"; '
                            'python3 -I "$TOOLS_DIR/producer.py" pack-backports --input "$DEPENDENCY_WORK_DIR/export" --output "$DEPENDENCY_WORK_DIR/backports.tar.gz"', check=False)
        if result.returncode:
            self.fail(result.stdout)
        sys.path.insert(0, str(self.root / 'tools'))
        self.addCleanup(sys.path.pop, 0)
        spec = importlib.util.spec_from_file_location('protocol_test', self.root / 'tools/ci_dependencies.py')
        protocol = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(protocol)
        extracted = self.work / 'extracted'
        extracted.mkdir()
        protocol.extract_archive(self.work / 'backports.tar.gz', extracted)
        from unittest.mock import patch
        with patch.dict(os.environ, {**self.pins, 'BACKPORT_BUNDLE_MANIFEST_SHA256': protocol.sha256(extracted / 'manifest.json')}, clear=True):
            self.assertEqual(protocol.checked_backports(self.root, extracted), extracted)
        data = json.loads((self.work / 'export/manifest.json').read_text())
        self.assertEqual(set(data['commits']), {self.pins['TIMER_BASE_FAST_PATH_COMMIT']})
        self.assertIn('dependency_files', data['producer'])
        self.assertEqual(data['producer']['project_commit'], self.commit)
        self.assertTrue((self.work / 'backports.tar.gz').is_file())
        self.assertEqual(git(self.root, 'status', '--porcelain'), '')
        self.assertFalse((self.root / 'patches/init.sh').exists())
        self.assertFalse((self.root / 'patches/patch.sh').exists())

    def test_toolchain_export_across_filesystems(self):
        from unittest.mock import patch
        other = tempfile.TemporaryDirectory(prefix='dependency-output-', dir='/var/tmp')
        self.addCleanup(other.cleanup)
        output = Path(other.name) / 'toolchain.tar.zst'
        if output.parent.stat().st_dev == self.work.stat().st_dev:
            self.skipTest('跨文件系统测试需要 /tmp 与 /var/tmp 位于不同文件系统')
        spec = importlib.util.spec_from_file_location('producer_test', TOOLS / 'producer.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.load_protocol(self.root)
        self.addCleanup(sys.path.pop, 0)
        payload = self.work / 'tools/toolchain/fixture'
        payload.mkdir(parents=True)
        (payload / 'compiler').write_text('public toolchain fixture\n')
        (payload / 'compiler').chmod(0o775)
        (payload / 'link').symlink_to('compiler')
        pins = {name: 'fixture' for name in module.TOOLCHAIN_KEYS}
        pins.update(CI_TOOLCHAIN_NAME='fixture', DEPENDENCY_WORK_DIR=str(self.work),
                    CI_TOOLCHAIN_TREE_SHA256=module.tree_sha256(payload))
        with patch.dict(os.environ, pins), patch.object(module, 'producer_record', return_value={'test': True}), \
                patch.object(module.subprocess, 'run') as prepare:
            module.export_toolchain(self.root, output)
            prepare.assert_called_once()
        self.assertTrue(output.is_file())
        self.assertEqual(sorted(p.name for p in payload.parent.iterdir()), ['fixture'])

    def test_candidate_history_entry(self):
        commit = self.pins['TIMER_BASE_FAST_PATH_COMMIT']
        for source in ('aosp', 'stable'):
            git(self.work / 'sources' / source, 'fetch', '-q', str(self.work / 'sources/mainline'), commit)
        self.pins.update(COMMON_BRANCH='fixture', AOSP_BACKPORT_AUDIT_REFS='fixture:' + commit,
                         LINUX_STABLE_AUDIT_REF='fixture', LINUX_STABLE_AUDIT_BASE_COMMIT=self.baseline,
                         LINUX_STABLE_AUDIT_COMMIT=commit, LINUX_MAINLINE_AUDIT_BASE_COMMIT=self.baseline,
                         WORK_HISTORY_KEEP='3')
        (self.root / '.env').write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in self.pins.items()))
        git(self.root, 'commit', '-qam', 'public history fixture')
        self.env['PROJECT_COMMIT'] = git(self.root, 'rev-parse', 'HEAD')
        result = run('bash', str(TOOLS / 'backport_audit.sh'), env=self.env, check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        candidates = self.work / ('audit/backport-' + self.pins['BACKPORT_AUDIT_SNAPSHOT']) / 'candidates.tsv'
        self.assertIn('DEEP_REVIEW_PERFORMANCE', candidates.read_text())

    def test_wrong_remote_rejected(self):
        git(self.work / 'sources/mainline', 'remote', 'set-url', 'origin', 'https://example.invalid/wrong')
        result = run('bash', str(TOOLS / 'audit_sources.sh'), env=self.env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('remote 不匹配', result.stdout)

    def test_wrong_date_rejected(self):
        result = self.shell('. "$TOOLS_DIR/legacy_audit.sh"; TIMER_BASE_FAST_PATH_COMMIT_DATE=1900-01-01; audit_legacy_sources', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('日期不匹配', result.stdout)

    def test_missing_ancestry_rejected(self):
        result = self.shell('. "$TOOLS_DIR/legacy_audit.sh"; LINUX_MAINLINE_AUDIT_COMMIT="$COMMON_COMMIT"; audit_legacy_sources', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('不属于固定', result.stdout)

    def test_changed_input_rejected_before_output(self):
        with (self.root / '.env').open('a') as stream:
            stream.write('ENABLE_TIMER_BASE_FAST_PATH=0\n')
        result = run('bash', str(TOOLS / 'audit_sources.sh'), env=self.env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('固定提交不符', result.stdout)

    def test_history_rotation_boundary(self):
        spec = importlib.util.spec_from_file_location('prune_history', TOOLS / 'prune_history.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        audit = self.work / 'audit'
        audit.mkdir()
        for day in range(1, 6):
            (audit / ('backport-2026-01-0' + str(day))).mkdir()
        (audit / 'unrelated').mkdir()
        outside = self.base / 'outside'
        outside.mkdir()
        (audit / 'backport-2025-01-01').symlink_to(outside, target_is_directory=True)
        module.prune(audit, 3)
        self.assertFalse((audit / 'backport-2026-01-01').exists())
        self.assertTrue((audit / 'backport-2026-01-03').exists())
        self.assertTrue((audit / 'unrelated').exists())
        self.assertTrue(outside.exists())
        self.assertTrue((audit / 'backport-2025-01-01').is_symlink())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', required=True, type=Path)
    args, rest = parser.parse_known_args()
    PROJECT = args.project.resolve()
    unittest.main(argv=[sys.argv[0], *rest])
