#!/usr/bin/env python3
"""轮换依赖工作目录中按固定快照命名的候选审计记录。"""
import argparse
import datetime
from pathlib import Path
import re
import shutil


def prune(directory, keep):
    if keep < 1:
        raise ValueError('保留份数必须大于零')
    if any(path.is_symlink() for path in (directory, *directory.parents)):
        raise ValueError('审计目录不得经过符号链接')
    if not directory.exists():
        return
    histories = []
    for path in directory.iterdir():
        if not re.fullmatch(r'backport-\d{4}-\d{2}-\d{2}', path.name):
            continue
        if path.is_symlink() or not path.is_dir():
            continue
        datetime.date.fromisoformat(path.name.removeprefix('backport-'))
        histories.append(path)
    for path in sorted(histories, reverse=True)[keep:]:
        shutil.rmtree(path)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--keep', required=True, type=int)
    args = parser.parse_args()
    prune(args.directory, args.keep)
