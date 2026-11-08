#!/usr/bin/env python3
"""校验制作输入的提交身份和可写路径边界。"""
from pathlib import Path
import subprocess
import sys


def verify(root, commit, work):
    # pin 与回移内容必须来自该提交；协议实现逐文件记入 producer provenance。
    names = subprocess.check_output([
        'git', '-C', str(root), 'ls-tree', '-r', '--name-only', commit,
        '--', '.env', 'LICENSE', 'patches/backports',
    ]).decode().splitlines()
    if '.env' not in names or 'LICENSE' not in names:
        raise ValueError('固定项目缺少 pin 或许可证')
    for name in names:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('固定输入缺失或经过符号链接: ' + name)
        expected = subprocess.check_output(['git', '-C', str(root), 'show', commit + ':' + name])
        if path.read_bytes() != expected:
            raise ValueError('主项目输入与固定提交不符: ' + name)
    for path in (work, *work.parents):
        if path.is_symlink():
            raise ValueError('工作目录不得经过符号链接')
    if work == root or root.is_relative_to(work):
        raise ValueError('工作目录不得包含主项目')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit('[FAIL] ' + str(error))
