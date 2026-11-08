#!/usr/bin/env bash
# 从固定主项目输入制作官方回移与工具链 v1 依赖。
set -euo pipefail
TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${TOOLS_DIR}/context.sh"
load_context "$@"
. "${TOOLS_DIR}/prepare_sources.sh"
if [ -z "${OUTPUT_DIR}" ]; then
    mkdir -p "${TOOLS_DIR}/../output"
    OUTPUT_DIR="$(mktemp -d "${TOOLS_DIR}/../output/prepared.XXXXXX")"
else
    OUTPUT_DIR="$(realpath -m -- "${OUTPUT_DIR}")"
    [ ! -e "${OUTPUT_DIR}" ] || die "拒绝覆盖已有输出目录"
    mkdir -p "${OUTPUT_DIR}"
fi
export OUTPUT_DIR
printf '[INFO] 依赖制作目录: %s\n' "${OUTPUT_DIR}"
prepare_sources
python3 -I "${TOOLS_DIR}/producer.py" export-toolchain --output "${OUTPUT_DIR}/toolchain.tar.zst"
python3 -I "${TOOLS_DIR}/producer.py" export-backports --output "${OUTPUT_DIR}/backports"
export BACKPORT_BUNDLE_MANIFEST_SHA256
BACKPORT_BUNDLE_MANIFEST_SHA256="$(sha256sum "${OUTPUT_DIR}/backports/manifest.json" | cut -d ' ' -f1)"
python3 -I "${TOOLS_DIR}/producer.py" pack-backports --input "${OUTPUT_DIR}/backports" --output "${OUTPUT_DIR}/backports.tar.gz"
{
    printf 'BACKPORT_BUNDLE_MANIFEST_SHA256=%s\n' "${BACKPORT_BUNDLE_MANIFEST_SHA256}"
    printf 'BACKPORT_BUNDLE_SHA256=%s\n' "$(sha256sum "${OUTPUT_DIR}/backports.tar.gz" | cut -d ' ' -f1)"
    printf 'CI_TOOLCHAIN_BUNDLE_SHA256=%s\n' "$(sha256sum "${OUTPUT_DIR}/toolchain.tar.zst" | cut -d ' ' -f1)"
} > "${OUTPUT_DIR}/pins.env"
printf '[OK] 固定依赖制作完成: %s\n' "${OUTPUT_DIR}"
