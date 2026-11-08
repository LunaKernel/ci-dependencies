#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

ensure_audit_repo() {
    local label="$1" target_dir="$2" repo_url="$3"
    local actual_url
    if ! git -C "${target_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        [ ! -e "${target_dir}" ] || die "${label} 路径存在但不是 Git 仓库: ${target_dir}"
        mkdir -p "$(dirname "${target_dir}")"
        log_step "初始化只读审计仓库 ${label}: ${repo_url}"
        git init --bare "${target_dir}" >/dev/null
        git -C "${target_dir}" remote add origin "${repo_url}"
        git -C "${target_dir}" config remote.origin.promisor true
        git -C "${target_dir}" config remote.origin.partialclonefilter blob:none
    fi
    reject_git_object_overrides "${label}" "${target_dir}"
    [ "$(git -C "${target_dir}" rev-parse --is-bare-repository)" = "true" ] || \
        die "${label} 必须是无工作树的 bare 审计仓库"
    actual_url="$(git -C "${target_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo_url}")" ] || \
        die "${label} remote 不匹配: ${actual_url}"
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        # Never export expanded maintenance history as a daily CI cache.
        git -C "${target_dir}" config backport.auditHistoryExpanded true
    fi
}

fetch_audit_ref() {
    local label="$1" repo_dir="$2" ref_name="$3" commit="$4" shallow_since="$5"
    local target_ref="refs/backport-audit/${ref_name}"
    if ! env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取 ${label} 固定审计对象: ${commit}"
        git_network -C "${repo_dir}" fetch --filter=blob:none --no-tags \
            --shallow-since="${shallow_since}" origin "${commit}"
    fi
    env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label} 固定审计对象缺失: ${commit}"
    git -C "${repo_dir}" update-ref "${target_ref}" "${commit}"
    [ "$(git -C "${repo_dir}" rev-parse "${target_ref}")" = "${commit}" ] || \
        die "${label} 审计 ref 固定失败: ${ref_name}"
}

hydrate_audit_history() {
    local label="$1" repo_dir="$2" snapshot="$3" shallow_since="$4"
    local identity
    shift 4
    identity="$(
        {
            printf '%s\n' "${snapshot}" "${shallow_since}"
            printf '%s\n' "$@"
        } | sha256sum | awk '{ print $1 }'
    )"
    [ "$(git -C "${repo_dir}" config --get backport.auditHydratedIdentity 2>/dev/null || true)" = "${identity}" ] && return
    log_step "水合 ${label} 固定浅历史，确保审计阶段完全离线"
    git_network -C "${repo_dir}" fetch --no-tags --filter=blob:none \
        --shallow-since="${shallow_since}" origin "$@"
    git -C "${repo_dir}" config backport.auditHydratedIdentity "${identity}"
    git -C "${repo_dir}" config --unset-all backport.auditHydratedSnapshot 2>/dev/null || true
}

hydrate_audit_patches() {
    local label="$1" repo_dir="$2" commit
    shift 2
    [ "$#" -gt 0 ] || return
    log_step "水合 ${label} 已选补丁对象，确保 patch/build 阶段不联网"
    for commit in "$@"; do
        if env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" -c log.mailmap=false \
            show --format= "${commit}" >/dev/null 2>&1; then
            continue
        fi
        git_network -C "${repo_dir}" -c log.mailmap=false show --format= "${commit}" >/dev/null
        env GIT_NO_LAZY_FETCH=1 git -C "${repo_dir}" -c log.mailmap=false \
            show --format= "${commit}" >/dev/null || \
            die "${label} 补丁对象未完整水合: ${commit}"
    done
}

hydrate_kbuild_objects() {
    local oid cache type actual reused=0
    local -a missing=()
    for oid in "$@"; do
        if env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" cat-file -e "${oid}" 2>/dev/null; then
            continue
        fi
        for cache in "${LINUX_MAINLINE_AUDIT_DIR}" "${AOSP_BACKPORT_AUDIT_DIR}" "${LINUX_STABLE_AUDIT_DIR}" "${COMMON_DIR}"; do
            if ! env GIT_NO_LAZY_FETCH=1 git -C "${cache}" cat-file -e "${oid}" 2>/dev/null; then
                continue
            fi
            type="$(env GIT_NO_LAZY_FETCH=1 git -C "${cache}" cat-file -t "${oid}")"
            actual="$(env GIT_NO_LAZY_FETCH=1 git -C "${cache}" cat-file "${type}" "${oid}" |
                git -C "${KBUILD_AUDIT_DIR}" hash-object -w -t "${type}" --stdin)"
            [ "${actual}" = "${oid}" ] || die "Kbuild 本地对象复用摘要不匹配"
            reused=$((reused + 1))
            break
        done
        if ! env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" cat-file -e "${oid}" 2>/dev/null; then
            missing+=("${oid}")
        fi
    done
    [ "${reused}" = 0 ] || log_info "Kbuild 复用 ${reused} 个已有 Git 对象"
    if [ "${#missing[@]}" -gt 0 ]; then
        # Depth 1 retains explicitly requested trees but omits their children.
        git_network -C "${KBUILD_AUDIT_DIR}" fetch --no-tags --filter=tree:1 origin "${missing[@]}"
    fi
    for oid in "$@"; do
        env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" cat-file -e "${oid}" 2>/dev/null || \
            die "Kbuild 必要对象缺失: ${oid}"
    done
}

prepare_kbuild_audit() {
    local commit parent tree paths path state component entry mode type oid filename
    local -a commits=() states=() next=() objects=() blobs=() commit_paths=()
    mapfile -t commits < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list kbuild)
    [ "${#commits[@]}" -gt 0 ] || return 0
    ensure_audit_repo "Kbuild 官方构建工具历史" "${KBUILD_AUDIT_DIR}" "${KBUILD_AUDIT_REPO}"
    git -C "${KBUILD_AUDIT_DIR}" config remote.origin.partialclonefilter tree:0
    if ! env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" merge-base --is-ancestor \
        "${KBUILD_AUDIT_BASE_COMMIT}" "${KBUILD_AUDIT_COMMIT}" 2>/dev/null; then
        git_network -C "${KBUILD_AUDIT_DIR}" fetch --no-tags --filter=tree:0 --depth=17 origin "${KBUILD_AUDIT_COMMIT}"
    fi
    env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" merge-base --is-ancestor \
        "${KBUILD_AUDIT_BASE_COMMIT}" "${KBUILD_AUDIT_COMMIT}" || die "Kbuild 固定祖先链不完整"
    git -C "${KBUILD_AUDIT_DIR}" update-ref refs/backport-audit/kbuild/base "${KBUILD_AUDIT_BASE_COMMIT}"
    git -C "${KBUILD_AUDIT_DIR}" update-ref "refs/backport-audit/kbuild/${KBUILD_AUDIT_REF}" "${KBUILD_AUDIT_COMMIT}"
    for commit in "${commits[@]}"; do
        env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" merge-base --is-ancestor \
            "${commit}" "${KBUILD_AUDIT_COMMIT}" || die "Kbuild 所选提交不属于固定终点"
        paths="$(awk -F '\t' -v commit="${commit}" '!/^#/ && $6 == commit { print $9 }' \
            "${HOST_WORKSPACE_DIR}"/patches/backports/kmi6-2026-09-independent/*.tsv)"
        for parent in "${commit}" "${commit}^"; do
            tree="$(env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" cat-file commit "${parent}" |
                awk 'NR == 1 { print $2 }')"
            IFS=, read -ra commit_paths <<<"${paths}"
            for path in "${commit_paths[@]}"; do states+=("${tree} ${path}"); done
        done
    done
    # Walk only the paths declared by pinned manifests; never fetch a whole tree.
    while [ "${#states[@]}" -gt 0 ]; do
        objects=()
        for state in "${states[@]}"; do objects+=("${state%% *}"); done
        mapfile -t objects < <(printf '%s\n' "${objects[@]}" | LC_ALL=C sort -u)
        hydrate_kbuild_objects "${objects[@]}"
        next=()
        for state in "${states[@]}"; do
            tree="${state%% *}" path="${state#* }" component="${state#* }"
            component="${component%%/*}"
            entry="$(env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" ls-tree "${tree}" -- "${component}")"
            read -r mode type oid filename <<<"${entry}"
            [[ "${oid}" =~ ^[0-9a-f]{40}$ ]] || die "Kbuild 来源路径缺失: ${path}"
            if [[ "${path}" = */* ]]; then
                [ "${type}" = tree ] || die "Kbuild 来源目录类型异常: ${path}"
                next+=("${oid} ${path#*/}")
            else
                [ "${type}" = blob ] || die "Kbuild 来源文件类型异常: ${path}"
                blobs+=("${oid}")
            fi
        done
        states=("${next[@]}")
    done
    mapfile -t blobs < <(printf '%s\n' "${blobs[@]}" | LC_ALL=C sort -u)
    hydrate_kbuild_objects "${blobs[@]}"
    for commit in "${commits[@]}"; do
        env GIT_NO_LAZY_FETCH=1 git -C "${KBUILD_AUDIT_DIR}" show --format= "${commit}" >/dev/null || \
            die "Kbuild 补丁仍缺少离线审计对象: ${commit}"
    done
    log_success "Kbuild 固定提交及必要差异对象已准备，可完全离线审计"
}

hydrate_audit_commit_history() {
    local label="$1" repo_dir="$2" snapshot="$3" shallow_since="$4"
    local identity
    shift 4
    identity="$(
        {
            printf '%s\n' "${snapshot}" "${shallow_since}"
            printf '%s\n' "$@"
        } | sha256sum | awk '{ print $1 }'
    )"
    [ "$(git -C "${repo_dir}" config --get backport.auditCommitHistoryIdentity 2>/dev/null || true)" = "${identity}" ] && return
    log_step "水合 ${label} 固定提交与 tree 历史，确保离线漏斗完整"
    git_network -C "${repo_dir}" fetch --no-tags --filter=blob:none \
        --shallow-since="${shallow_since}" origin "$@"
    git -C "${repo_dir}" config backport.auditCommitHistoryIdentity "${identity}"
}

required_aosp_refs() {
    local feature enabled ref manifest
    for feature in F2FS_DIO_OVERWRITE_FAST_PATH BLK_WBT_DONE_FAST_PATH \
        MEMCG_RSTAT_FAST_PATH TCP_RECV_MSTAMP_FAST_PATH IPV6_MLD_UAF_FIX; do
        enabled="ENABLE_${feature}" ref="${feature}_AOSP_REF"
        [ "${!enabled:-0}" = 1 ] || continue
        [ -n "${!ref:-}" ] || die "${feature} 缺少 AOSP 来源 ref"
        printf '%s\n' "${!ref}"
    done
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = 1 ]; then
        manifest="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST:-patches/backports/kmi6-2026-09-selected-backports.tsv}")"
        awk -F '\t' '!/^#/ && $4 == "aosp" { print $5 }' "${manifest}"
    fi
    for manifest in "${HOST_WORKSPACE_DIR}"/patches/backports/kmi6-2026-09-independent/[0-9][0-9][0-9]-*.tsv; do
        [ -f "${manifest}" ] || continue
        awk -F '\t' '!/^#/ && $4 == "aosp" { print $5 }' "${manifest}"
    done
}

prepare_aosp_audit_sources() {
    local requested name pair commit
    local -a commits=()
    ensure_audit_repo "AOSP common 回移来源" "${AOSP_BACKPORT_AUDIT_DIR}" "${COMMON_REPO}"
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        requested="$(printf '%s\n' ${AOSP_BACKPORT_AUDIT_REFS} | cut -d: -f1)"
        commits=("${AOSP_BACKPORT_AUDIT_BASE_COMMIT:?缺少回移审计快照基线}")
        fetch_audit_ref "AOSP common September KMI6 构建基线" "${AOSP_BACKPORT_AUDIT_DIR}" \
            "aosp/build-base-kmi6-2026-09" "${COMMON_COMMIT}" "${AOSP_BACKPORT_AUDIT_SHALLOW_SINCE}"
    else
        requested="$(required_aosp_refs | LC_ALL=C sort -u)"
    fi
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        commit=""
        for pair in ${AOSP_BACKPORT_AUDIT_REFS}; do
            [ "${pair%%:*}" = "${name}" ] || continue
            [ -z "${commit}" ] || die "AOSP ref 重复: ${name}"
            commit="${pair#*:}"
        done
        [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "AOSP ref 未固定: ${name}"
        commits+=("${commit}")
        fetch_audit_ref "AOSP ${name}" "${AOSP_BACKPORT_AUDIT_DIR}" \
            "aosp/${name}" "${commit}" "2025-01-01"
    done <<<"${requested}"
    if [ "${#commits[@]}" -gt 0 ]; then
        hydrate_audit_history "AOSP common" "${AOSP_BACKPORT_AUDIT_DIR}" \
            "${BACKPORT_AUDIT_SNAPSHOT}" "2025-01-01" "${commits[@]}"
    fi
}

prepare_sources() {
    [ -n "${BACKPORT_AUDIT_SNAPSHOT}" ] || die "缺少后续改进审计快照日期"
    [ -n "${AOSP_BACKPORT_AUDIT_REFS}" ] || die "缺少 AOSP 后续审计 refs"
    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 审计终点"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 审计终点"
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        [ -n "${LINUX_STABLE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux stable 审计起点"
        [ -n "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" ] || die "缺少 Linux mainline 审计起点"
    fi
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        bash "${BACKPORT_TOOL}" verify-manifest
    fi
    bash "${INDEPENDENT_BACKPORT_TOOL}" verify-manifests

    prepare_aosp_audit_sources

    selected_aosp_patches=()
    for selected_aosp_entry in \
        "${ENABLE_F2FS_DIO_OVERWRITE_FAST_PATH:-0}:${F2FS_DIO_OVERWRITE_FAST_PATH_COMMIT:-}" \
        "${ENABLE_BLK_WBT_DONE_FAST_PATH:-0}:${BLK_WBT_DONE_FAST_PATH_COMMIT:-}" \
        "${ENABLE_MEMCG_RSTAT_FAST_PATH:-0}:${MEMCG_RSTAT_FAST_PATH_COMMIT:-}" \
        "${ENABLE_TCP_RECV_MSTAMP_FAST_PATH:-0}:${TCP_RECV_MSTAMP_FAST_PATH_COMMIT:-}" \
        "${ENABLE_IPV6_MLD_UAF_FIX:-0}:${IPV6_MLD_UAF_FIX_COMMIT:-}"; do
        [ "${selected_aosp_entry%%:*}" = "1" ] || continue
        selected_aosp_patches+=("${selected_aosp_entry#*:}")
    done
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_aosp_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list aosp)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_aosp_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list aosp)
    hydrate_audit_patches "AOSP common" "${AOSP_BACKPORT_AUDIT_DIR}" \
        "${selected_aosp_patches[@]}"

    ensure_audit_repo "Linux 6.12 stable 历史" "${LINUX_STABLE_AUDIT_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
    stable_audit_commits=("${LINUX_STABLE_AUDIT_COMMIT}")
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        fetch_audit_ref "Linux stable v6.12.69" "${LINUX_STABLE_AUDIT_DIR}" \
            "linux-stable/base-v6.12.69" "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "2026-01-01"
        stable_audit_commits=("${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${stable_audit_commits[@]}")
    fi
    fetch_audit_ref "Linux stable ${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_DIR}" \
        "linux-stable/${LINUX_STABLE_AUDIT_REF}" "${LINUX_STABLE_AUDIT_COMMIT}" "2026-02-01"
    hydrate_audit_commit_history "Linux 6.12 stable" "${LINUX_STABLE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2026-02-01" \
        "${stable_audit_commits[@]}"
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        env GIT_NO_LAZY_FETCH=1 git -C "${LINUX_STABLE_AUDIT_DIR}" merge-base --is-ancestor \
            "${LINUX_STABLE_AUDIT_BASE_COMMIT}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
            die "Linux stable 审计历史未形成 v6.12.69 到固定终点的完整祖先链"
    fi
    selected_stable_patches=()
    for selected_stable_entry in \
        "${ENABLE_F2FS_ACL_ENTRY_BOUNDS_FIX:-0}:${F2FS_ACL_ENTRY_BOUNDS_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_LISTXATTR_BOUNDS_FIX:-0}:${F2FS_LISTXATTR_BOUNDS_STABLE_COMMIT:-}" \
        "${ENABLE_BLKCG_RSTAT_RELEASE_FIX:-0}:${BLKCG_RSTAT_RELEASE_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}:${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT:-}" \
        "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX:-0}:${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT:-}" \
        "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}:${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT:-}"; do
        [ "${selected_stable_entry%%:*}" = "1" ] || continue
        selected_stable_patches+=("${selected_stable_entry#*:}")
    done
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_stable_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list stable)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_stable_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list stable)
    hydrate_audit_patches "Linux 6.12 stable" "${LINUX_STABLE_AUDIT_DIR}" \
        "${selected_stable_patches[@]}"

    ensure_audit_repo "Linux mainline 历史" "${LINUX_MAINLINE_AUDIT_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
    mainline_audit_commits=("${LINUX_MAINLINE_AUDIT_COMMIT}")
    if [ "${INIT_AUDIT_HISTORY}" = 1 ]; then
        fetch_audit_ref "Linux mainline v6.12" "${LINUX_MAINLINE_AUDIT_DIR}" \
            "linux-mainline/base-v6.12" "${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "2024-11-01"
        mainline_audit_commits=("${LINUX_MAINLINE_AUDIT_BASE_COMMIT}" "${mainline_audit_commits[@]}")
    fi
    fetch_audit_ref "Linux mainline 快照" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "linux-mainline/snapshot-${BACKPORT_AUDIT_SNAPSHOT}" "${LINUX_MAINLINE_AUDIT_COMMIT}" "2024-11-01"
    hydrate_audit_commit_history "Linux mainline" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "${BACKPORT_AUDIT_SNAPSHOT}" "2024-11-01" \
        "${mainline_audit_commits[@]}"
    selected_mainline_patches=()
    if [ "${ENABLE_TIMER_BASE_FAST_PATH:-0}" = "1" ]; then
        selected_mainline_patches+=("${TIMER_BASE_FAST_PATH_COMMIT}")
    fi
    if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX:-0}" = "1" ]; then
        selected_mainline_patches+=("${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT}")
    fi
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        while IFS= read -r audit_commit; do
            selected_mainline_patches+=("${audit_commit}")
        done < <(bash "${BACKPORT_TOOL}" list mainline)
    fi
    while IFS= read -r audit_commit; do
        [ -n "${audit_commit}" ] && selected_mainline_patches+=("${audit_commit}")
    done < <(bash "${INDEPENDENT_BACKPORT_TOOL}" list mainline)
    hydrate_audit_patches "Linux mainline 已选补丁" "${LINUX_MAINLINE_AUDIT_DIR}" \
        "${selected_mainline_patches[@]}"
    prepare_kbuild_audit
    if [ "${ENABLE_SELECTED_BACKPORTS:-0}" = "1" ]; then
        bash "${BACKPORT_TOOL}" verify-sources
    fi
    bash "${INDEPENDENT_BACKPORT_TOOL}" verify-sources
    log_success "已选回移来源已固定并通过离线审计"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    . "$(dirname -- "${BASH_SOURCE[0]}")/context.sh"
    load_context "$@"
    prepare_sources
    bash "${TOOLS_DIR}/audit_sources.sh"
fi
