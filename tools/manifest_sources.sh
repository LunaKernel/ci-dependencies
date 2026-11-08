#!/usr/bin/env bash
set -euo pipefail
TOOLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${TOOLS_DIR}/context.sh"
load_context
BACKPORT_MANIFEST_LIBRARY=1 . "${PROJECT_DIR}/tools/backport_manifest.sh"
. "${TOOLS_DIR}/source_audit.sh"
. "${TOOLS_DIR}/manifest_batch.sh"

declare -a MANIFEST_ROWS=() MANIFESTS=()
declare -A VERIFIED_AUDIT_REPOS=() BATCH_ROWS=() BATCH_GROUPS=() BATCH_PINS=() BATCH_TMP=()
MANIFEST_DIR="${PROJECT_DIR}/patches/backports/kmi6-2026-09-independent"
MANIFESTS_READY=0
SOURCES_READY=0
TMP_ROOT=""
GROUP_COUNT=0

if [ "${DEPENDENCY_INDEPENDENT:-0}" = 1 ]; then
    case "${1:-}" in
        verify-manifests) verify_manifests ;;
        verify-sources) verify_all_sources ;;
        list) [ "$#" = 2 ] || die "list 需要来源名称"; list_commits "$2" ;;
        *) die "用法: independent_sources.sh verify-manifests|verify-sources|list SOURCE" ;;
    esac
else
    INDEPENDENT_MANIFEST=0
    MANIFEST="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST}")"
    MANIFEST_SHA256="${SELECTED_BACKPORT_MANIFEST_SHA256}"
    validate_manifest
    case "${1:-}" in
        verify-manifest) ;;
        verify-sources) verify_sources ;;
        list)
            [ "$#" = 2 ] || die "list 需要来源名称"
            awk -F '\t' -v source="$2" '!/^#/ && $4 == source { print $6 }' "${MANIFEST}"
            ;;
        *) die "用法: manifest_sources.sh verify-manifest|verify-sources|list SOURCE" ;;
    esac
fi
