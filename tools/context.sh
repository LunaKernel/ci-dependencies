#!/usr/bin/env bash
# 绑定主项目固定输入，将所有可写来源和工具置于独立工作目录。

TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${TOOLS_DIR}/git_source.sh"

load_context() {
    local name
    PROJECT_DIR="${PROJECT_DIR:-}"
    PROJECT_COMMIT="${PROJECT_COMMIT:-}"
    DEPENDENCY_WORK_DIR="${DEPENDENCY_WORK_DIR:-${TOOLS_DIR}/../work}"
    OUTPUT_DIR="${OUTPUT_DIR:-}"
    INIT_AUDIT_HISTORY="${INIT_AUDIT_HISTORY:-0}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --project|--project-commit|--work|--output)
                [ "$#" -ge 2 ] || die "$1 缺少参数"
                case "$1" in
                    --project) PROJECT_DIR="$2" ;;
                    --project-commit) PROJECT_COMMIT="$2" ;;
                    --work) DEPENDENCY_WORK_DIR="$2" ;;
                    --output) OUTPUT_DIR="$2" ;;
                esac
                shift 2 ;;
            --audit-history) INIT_AUDIT_HISTORY=1; shift ;;
            *) die "用法: --project ROOT --project-commit SHA [--work DIR] [--output NEW_DIR] [--audit-history]" ;;
        esac
    done
    [ -n "${PROJECT_DIR}" ] || die "缺少 --project"
    [[ "${PROJECT_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "--project-commit 必须是完整固定提交"
    PROJECT_DIR="$(cd -- "${PROJECT_DIR}" && pwd -P)"
    DEPENDENCY_WORK_DIR="$(realpath -m -- "${DEPENDENCY_WORK_DIR}")"
    [ "${DEPENDENCY_WORK_DIR}" != "${PROJECT_DIR}" ] || die "制作工作目录不得覆盖主项目"
    for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS; do
        [ -z "${!name:-}" ] || die "拒绝 Git 环境覆盖: ${name}"
    done
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
    export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 GIT_PAGER=cat
    export PYTHONDONTWRITEBYTECODE=1
    [ "$(git -C "${PROJECT_DIR}" rev-parse HEAD)" = "${PROJECT_COMMIT}" ] || die "主项目 HEAD 与固定输入不符"
    python3 -I "${TOOLS_DIR}/verify_input.py" "${PROJECT_DIR}" "${PROJECT_COMMIT}" "${DEPENDENCY_WORK_DIR}"
    set -a
    . "${PROJECT_DIR}/.env"
    set +a
    export PROJECT_DIR PROJECT_COMMIT DEPENDENCY_WORK_DIR OUTPUT_DIR INIT_AUDIT_HISTORY
    export BACKPORT_SOURCE_AUDIT=1
    WORKSPACE_DIR="${PROJECT_DIR}"
    HOST_WORKSPACE_DIR="${PROJECT_DIR}"
    WORK_DIR="${DEPENDENCY_WORK_DIR}"
    ENVIRONMENT_DIR="${WORK_DIR}/tools"
    CI_TOOLCHAIN_DIR="${ENVIRONMENT_DIR}/toolchain/${CI_TOOLCHAIN_NAME}"
    DL_DIR="${WORK_DIR}/cache/downloads/toolchain-${CI_CLANG_REVISION}"
    AOSP_DIR="${WORK_DIR}/${AOSP_BACKPORT_AUDIT_SOURCE_DIR}"
    STABLE_DIR="${WORK_DIR}/${LINUX_STABLE_AUDIT_SOURCE_DIR}"
    MAINLINE_DIR="${WORK_DIR}/${LINUX_MAINLINE_AUDIT_SOURCE_DIR}"
    KBUILD_DIR="${WORK_DIR}/${KBUILD_AUDIT_SOURCE_DIR}"
    AOSP_BACKPORT_AUDIT_DIR="${AOSP_DIR}"
    LINUX_STABLE_AUDIT_DIR="${STABLE_DIR}"
    LINUX_MAINLINE_AUDIT_DIR="${MAINLINE_DIR}"
    KBUILD_AUDIT_DIR="${KBUILD_DIR}"
    COMMON_DIR="${AOSP_DIR}"
    BACKPORT_TOOL="${TOOLS_DIR}/manifest_sources.sh"
    INDEPENDENT_BACKPORT_TOOL="${TOOLS_DIR}/independent_sources.sh"
    INIT_FETCH_JOBS="${INIT_FETCH_JOBS:-1}"
    case "${INIT_FETCH_JOBS}" in 1|2) ;; *) die "INIT_FETCH_JOBS 只允许 1 或 2" ;; esac
    mkdir -p "${WORK_DIR}"
}

resolve_workspace_path() {
    case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "${PROJECT_DIR}" "$1" ;; esac
}

tree_sha256() {
    python3 -I "${PROJECT_DIR}/tools/tree_sha256.py" "$1"
}

backport_bundle_enabled() { return 1; }
