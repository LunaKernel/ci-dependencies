#!/usr/bin/env bash
set -euo pipefail
export DEPENDENCY_INDEPENDENT=1
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/manifest_sources.sh" "$@"
