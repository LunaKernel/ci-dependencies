#!/usr/bin/env python3
"""官方依赖的导出与归档；v1 内容协议来自固定主项目输入。"""
import argparse
import gzip
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent


def load_protocol(root):
    sys.path.insert(0, str(root / 'tools'))
    spec = importlib.util.spec_from_file_location('ci_dependency_protocol', root / 'tools/ci_dependencies.py')
    protocol = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(protocol)
    for name in ('FORMAT', 'TOOLCHAIN_KEYS', 'require', 'sha256', 'digest_pin', 'local_path',
                 'backport_inputs', 'needed_commits', 'json_bytes', 'checked_backports', 'tree_sha256'):
        globals()[name] = getattr(protocol, name)


def run_git(repo, *args):
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.hooksPath',
                       GIT_CONFIG_VALUE_0=os.devnull, GIT_NO_LAZY_FETCH='1',
                       GIT_NO_REPLACE_OBJECTS='1', GIT_PAGER='cat')
    return subprocess.run(['git', '-c', 'log.mailmap=false', '-C', str(repo), *args], check=True,
                          capture_output=True, timeout=60, env=environment).stdout


def producer_record(root):
    files = ('tools/backport_manifest.sh', 'tools/ci_dependencies.py', 'tools/tree_sha256.py')
    return {'project_commit': os.environ['PROJECT_COMMIT'],
            'files': {name: sha256(root / name) for name in files},
            'dependency_commit': run_git(TOOLS.parent, 'rev-parse', 'HEAD').decode().strip(),
            'dependency_files': {path.relative_to(TOOLS.parent).as_posix(): sha256(path)
                                 for path in sorted(TOOLS.iterdir()) if path.suffix in ('.py', '.sh')},
            'pins_sha256': sha256(root / '.env')}


def export_backports(root, destination):
    require(not destination.exists(), '拒绝覆盖已有回移包目录')
    audit_env = dict(os.environ, BACKPORT_SOURCE_AUDIT='1', PYTHONDONTWRITEBYTECODE='1')
    subprocess.run(['bash', str(TOOLS / 'audit_sources.sh')], env=audit_env, check=True, timeout=900)
    destination.mkdir(parents=True)
    (destination / 'patches').mkdir()
    sources = {
        'aosp': ('AOSP_BACKPORT_AUDIT_SOURCE_DIR', 'COMMON_REPO'),
        'stable': ('LINUX_STABLE_AUDIT_SOURCE_DIR', 'LINUX_STABLE_AUDIT_REPO'),
        'mainline': ('LINUX_MAINLINE_AUDIT_SOURCE_DIR', 'LINUX_MAINLINE_AUDIT_REPO'),
        'kbuild': ('KBUILD_AUDIT_SOURCE_DIR', 'KBUILD_AUDIT_REPO'),
    }
    records = {}
    for commit, source in needed_commits(root).items():
        directory_key, url_key = sources[source]
        repo = local_path(Path(os.environ['DEPENDENCY_WORK_DIR']), os.environ[directory_key])
        patch = destination / 'patches' / (commit + '.patch')
        patch.write_bytes(run_git(repo, 'show', '--format=', commit))
        records[commit] = {
            'source': source, 'url': os.environ[url_key], 'sha256': sha256(patch),
            'parents': run_git(repo, 'rev-list', '--parents', '-n', '1', commit).decode().split()[1:],
            'date': run_git(repo, 'show', '-s', '--format=%cs', commit).decode().strip(),
            'subject': run_git(repo, 'show', '-s', '--format=%s', commit).decode().strip(),
            'message': run_git(repo, 'show', '-s', '--format=%B', commit).decode(),
            'paths': run_git(repo, 'diff-tree', '--no-commit-id', '--name-only', '-r', commit).decode().splitlines(),
        }
    shutil.copyfile(root / 'LICENSE', destination / 'LICENSE')
    data = {'format': FORMAT, 'kind': 'backports', 'inputs': backport_inputs(root), 'commits': records,
            'producer': producer_record(root),
            'files': {path.relative_to(destination).as_posix(): sha256(path)
                      for path in sorted(destination.rglob('*')) if path.is_file()}}
    (destination / 'manifest.json').write_bytes(json_bytes(data))
    print('BACKPORT_BUNDLE_MANIFEST_SHA256=' + sha256(destination / 'manifest.json'))


def write_archive(source, output, *, zstd=False):
    require(not output.exists(), '拒绝覆盖已有依赖归档')
    with output.open('xb') as raw:
        process = subprocess.Popen(['zstd', '-q', '-T2', '-3', '-c'], stdin=subprocess.PIPE, stdout=raw) if zstd else None
        zipped = process.stdin if zstd else gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0, compresslevel=6)
        try:
            with tarfile.open(fileobj=zipped, mode='w|') as bundle:
                for path in sorted(source.rglob('*')):
                    bundle.inodes.clear()
                    member = bundle.gettarinfo(path, path.relative_to(source).as_posix())
                    member.uid = member.gid = member.mtime = 0
                    member.uname = member.gname = ''
                    if member.isfile():
                        with path.open('rb') as stream:
                            bundle.addfile(member, stream)
                    else:
                        bundle.addfile(member)
        finally:
            zipped.close()
            if process is not None:
                require(process.wait(timeout=60) == 0, '固定依赖压缩失败')
    return sha256(output)


def export_toolchain(root, output):
    require(not output.exists(), '拒绝覆盖已有工具链归档')
    subprocess.run(['bash', str(TOOLS / 'toolchain_sources.sh')], check=True, timeout=1800)
    payload = Path(os.environ['DEPENDENCY_WORK_DIR']) / 'tools/toolchain' / os.environ['CI_TOOLCHAIN_NAME']
    require(tree_sha256(payload) == digest_pin('CI_TOOLCHAIN_TREE_SHA256'), '制作前工具链安装树不匹配')
    staging = Path(tempfile.mkdtemp(prefix='toolchain-package-', dir=payload.parent))
    try:
        provenance = {'format': FORMAT, 'kind': 'toolchain', 'producer': producer_record(root),
                      'inputs': {key: os.environ[key] for key in TOOLCHAIN_KEYS}}
        (staging / 'provenance.json').write_bytes(json_bytes(provenance))
        # 暂存副本与安装树同文件系统，输出归档可位于另一文件系统。
        shutil.copytree(payload, staging / 'payload', symlinks=True, copy_function=os.link)
        print('CI_TOOLCHAIN_BUNDLE_SHA256=' + write_archive(staging, output, zstd=True))
    finally:
        shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('export-backports', 'pack-backports', 'export-toolchain'))
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--input', type=Path)
    args = parser.parse_args()
    root = Path(os.environ['PROJECT_DIR'])
    load_protocol(root)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.command == 'export-backports':
        export_backports(root, output)
    elif args.command == 'export-toolchain':
        export_toolchain(root, output)
    else:
        require(args.input is not None, '打包需要 --input')
        checked_backports(root, args.input.resolve())
        print('BACKPORT_BUNDLE_SHA256=' + write_archive(args.input.resolve(), output))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit('[FAIL] ' + str(error))
