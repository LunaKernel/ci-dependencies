#!/usr/bin/env python3
"""仅从依赖仓源码制作可复现的 AnyKernel3 模板归档。"""
import argparse
import gzip
import hashlib
from pathlib import Path
import tarfile


SOURCE = Path(__file__).resolve().parent.parent / 'ak3_template'


def pack(output):
    paths = [SOURCE, *sorted(SOURCE.rglob('*'))]
    for path in paths:
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError('模板只允许普通文件和目录: ' + str(path))
    # 显式构造头，避免宿主文件权限、时间、用户名和 gzip 文件名影响归档。
    with output.open('xb') as raw:
        with gzip.GzipFile(fileobj=raw, mode='wb', filename='', mtime=0, compresslevel=6) as zipped:
            with tarfile.open(fileobj=zipped, mode='w|', format=tarfile.USTAR_FORMAT) as bundle:
                for path in paths:
                    member = tarfile.TarInfo(path.relative_to(SOURCE.parent).as_posix())
                    member.mode = 0o755 if path.is_dir() else 0o644
                    if path.is_dir():
                        member.type = tarfile.DIRTYPE
                        bundle.addfile(member)
                    else:
                        member.size = path.stat().st_size
                        with path.open('rb') as stream:
                            bundle.addfile(member, stream)
    print(hashlib.sha256(output.read_bytes()).hexdigest() + '  ' + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path,
                        help='新归档路径；父目录必须已存在，拒绝覆盖')
    args = parser.parse_args()
    pack(args.output)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, tarfile.TarError) as error:
        raise SystemExit('[FAIL] ' + str(error))
