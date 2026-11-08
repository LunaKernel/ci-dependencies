#!/usr/bin/env bash
# 完整官方来源证明，保持主项目与内核工作树只读。
set -euo pipefail
TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${TOOLS_DIR}/context.sh"
load_context "$@"
. "${TOOLS_DIR}/source_audit.sh"
. "${TOOLS_DIR}/legacy_audit.sh"
declare -A VERIFIED_AUDIT_REPOS=()
verify_audit_repo "AOSP common 审计源" "${AOSP_DIR}" "${COMMON_REPO}"
verify_audit_repo "Linux stable 审计源" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
verify_audit_repo "Linux mainline 审计源" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
audit_legacy_sources
[ "${ENABLE_SELECTED_BACKPORTS:-0}" != 1 ] || bash "${BACKPORT_TOOL}" verify-sources
bash "${INDEPENDENT_BACKPORT_TOOL}" verify-sources
log_success "全部启用回移的官方来源证明通过"
