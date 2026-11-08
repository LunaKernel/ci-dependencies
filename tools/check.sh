#!/usr/bin/env bash
set -euo pipefail
TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[ "$#" = 2 ] && [ "$1" = --project ] || { printf '用法: bash tools/check.sh --project ROOT\n' >&2; exit 1; }
for script in "${TOOLS_DIR}"/*.sh; do bash -n "${script}"; done
python3 -I -c 'import ast,pathlib,sys; [ast.parse(p.read_text(), filename=str(p)) for p in pathlib.Path(sys.argv[1]).glob("*.py")]' "${TOOLS_DIR}"
python3 -I "${TOOLS_DIR}/test_producer.py" --project "$2"
git -C "${TOOLS_DIR}/.." diff --check
