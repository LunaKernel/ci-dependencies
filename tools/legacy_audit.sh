#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

verify_linux_mainline_source_exact() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" actual_date actual_paths patch_id

    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 tools/prepare_sources.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
        die "${label}不属于固定 Linux mainline 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label}提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}触及非预期路径: ${actual_paths}"
    patch_id="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" | git patch-id --stable | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label}patch-id 不匹配"
}

verify_linux_stable_source() {
    local label="$1" commit="$2" expected_patch_id="$3"
    local patch_file patch_id
    patch_file="$(mktemp)"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        cat-file -e "${commit}^{commit}" 2>/dev/null || \
        die "${label}对象缺失，请先运行 tools/prepare_sources.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${commit}" > "${patch_file}"
    patch_id="$(git patch-id --stable < "${patch_file}" | awk '{ print $1 }')"
    rm -f "${patch_file}"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

verify_linux_stable_source_exact() {
    local label="$1" commit="$2" commit_date="$3" expected_patch_id="$4"
    local expected_paths="$5" upstream_commit="$6"
    local actual_date actual_paths commit_message upstream_patch_id upstream_paths

    [ -n "${LINUX_STABLE_AUDIT_COMMIT}" ] || die "缺少 Linux stable 固定审计终点"
    verify_linux_stable_source "${label}" "${commit}" "${expected_patch_id}"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${LINUX_STABLE_AUDIT_COMMIT}" || \
        die "${label} 不属于固定 Linux 6.12.y 审计快照"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label} 触及非预期路径: ${actual_paths}"
    commit_message="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_STABLE_AUDIT_DIR}" \
        -c log.mailmap=false show -s --format=%B "${commit}")"
    grep -Fx "[ Upstream commit ${upstream_commit} ]" <<<"${commit_message}" >/dev/null || \
        die "${label} 未绑定固定 Linux mainline 上游提交"
    [ -n "${LINUX_MAINLINE_AUDIT_COMMIT}" ] || die "缺少 Linux mainline 固定审计终点"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        cat-file -e "${upstream_commit}^{commit}" 2>/dev/null || \
        die "${label} Linux mainline 上游对象缺失，请先运行 tools/prepare_sources.sh"
    env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        merge-base --is-ancestor "${upstream_commit}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
        die "${label} 上游提交不属于固定 Linux mainline 快照"
    upstream_paths="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${upstream_commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${upstream_paths}" = "${expected_paths}" ] || \
        die "${label} Linux mainline 上游触及非预期路径: ${upstream_paths}"
    upstream_patch_id="$(env GIT_NO_LAZY_FETCH=1 git --git-dir="${LINUX_MAINLINE_AUDIT_DIR}" \
        -c log.mailmap=false show --format= "${upstream_commit}" | \
        git patch-id --stable | awk '{ print $1 }')"
    [ "${upstream_patch_id}" = "${expected_patch_id}" ] || \
        die "${label} Linux mainline 上游 patch-id 不匹配"
}

audit_legacy_raw_source() {
    local label="$1" repo="$2" commit="$3" expected_patch_id="$4" expected_paths="$5"
    local actual_paths patch_id
    env GIT_NO_LAZY_FETCH=1 git -C "${repo}" cat-file -e "${commit}^{commit}" || die "${label}对象缺失"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${repo}" diff-tree \
        --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label}路径集合异常"
    patch_id="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${repo}" \
        show --format= "${commit}" | git patch-id --stable | awk '{ print $1 }')"
    [ "${patch_id}" = "${expected_patch_id}" ] || die "${label} patch-id 不匹配"
}

audit_legacy_sources() {
    local feature commit_pin patch_pin paths
    if [ "${ENABLE_TIMER_BASE_FAST_PATH}" = 1 ]; then
        verify_linux_mainline_source_exact timer "${TIMER_BASE_FAST_PATH_COMMIT}" \
            "${TIMER_BASE_FAST_PATH_COMMIT_DATE}" "${TIMER_BASE_FAST_PATH_PATCH_ID}" "kernel/time/timer.c"
    fi
    for feature in F2FS_DIO_OVERWRITE BLK_WBT_DONE MEMCG_RSTAT TCP_RECV_MSTAMP IPV6_MLD; do
        case "${feature}" in
            IPV6_MLD) commit_pin=IPV6_MLD_UAF_FIX_COMMIT; patch_pin=IPV6_MLD_UAF_FIX_PATCH_ID; paths=net/ipv6/mcast.c ;;
            *) commit_pin="${feature}_FAST_PATH_COMMIT"; patch_pin="${feature}_FAST_PATH_PATCH_ID"
                case "${feature}" in
                    F2FS_DIO_OVERWRITE) paths=fs/f2fs/data.c ;;
                    BLK_WBT_DONE) paths=block/blk-wbt.c ;;
                    MEMCG_RSTAT) paths=mm/memcontrol.c ;;
                    TCP_RECV_MSTAMP) paths='net/ipv4/tcp.c net/ipv4/tcp_input.c' ;;
                esac ;;
        esac
        if [ "${feature}" = IPV6_MLD ]; then feature=IPV6_MLD_UAF_FIX; else feature="${feature}_FAST_PATH"; fi
        feature="ENABLE_${feature}"
        if [ "${!feature:-0}" = 1 ]; then
            local prefix="${feature#ENABLE_}" ref_pin date_pin
            ref_pin="${prefix}_AOSP_REF"; date_pin="${prefix}_COMMIT_DATE"
            verify_aosp_backport_source "${feature}" "${!ref_pin}" "${!commit_pin}" \
                "${!date_pin}" "${!patch_pin}" "${paths}"
        fi
    done
    for feature in F2FS_ACL_ENTRY_BOUNDS F2FS_LISTXATTR_BOUNDS BLKCG_RSTAT_RELEASE; do
        commit_pin="${feature}_STABLE_COMMIT"; patch_pin="${feature}_PATCH_ID"
        case "${feature}" in
            F2FS_ACL_ENTRY_BOUNDS) paths=fs/f2fs/acl.c ;;
            F2FS_LISTXATTR_BOUNDS) paths=fs/f2fs/xattr.c ;;
            BLKCG_RSTAT_RELEASE) paths=block/blk-cgroup.c ;;
        esac
        feature="ENABLE_${feature}_FIX"
        if [ "${!feature:-0}" = 1 ]; then
            verify_linux_stable_source "${feature}" "${!commit_pin}" "${!patch_pin}"
            audit_legacy_raw_source "${feature}" "${LINUX_STABLE_AUDIT_DIR}" \
                "${!commit_pin}" "${!patch_pin}" "${paths}"
        fi
    done
    if [ "${ENABLE_F2FS_FOREGROUND_GC_DEADLOCK_FIX}" = 1 ]; then
        verify_linux_stable_source f2fs_gc "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}"
        verify_linux_stable_source f2fs_gc_merge "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}"
        audit_legacy_raw_source f2fs_gc "${LINUX_STABLE_AUDIT_DIR}" \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" "${F2FS_FOREGROUND_GC_DEADLOCK_PATCH_ID}" \
            "fs/f2fs/data.c fs/f2fs/f2fs.h fs/f2fs/segment.c"
        audit_legacy_raw_source f2fs_gc_merge "${LINUX_STABLE_AUDIT_DIR}" \
            "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}" "${F2FS_GC_MERGE_DEADLOCK_PATCH_ID}" "fs/f2fs/segment.c"
        [ "$(git -C "${LINUX_STABLE_AUDIT_DIR}" rev-parse "${F2FS_GC_MERGE_DEADLOCK_STABLE_COMMIT}^")" = \
            "${F2FS_FOREGROUND_GC_DEADLOCK_STABLE_COMMIT}" ] || die "F2FS GC 死锁组合提交顺序异常"
    fi
    if [ "${ENABLE_IPV6_MLD_DELAYED_WORK_UAF_FIX}" = 1 ]; then
        verify_linux_stable_source_exact ipv6_mld_delayed_work "${IPV6_MLD_DELAYED_WORK_STABLE_COMMIT}" \
            "${IPV6_MLD_DELAYED_WORK_COMMIT_DATE}" "${IPV6_MLD_DELAYED_WORK_OFFICIAL_PATCH_ID}" \
            "include/net/addrconf.h net/ipv6/mcast.c" "${IPV6_MLD_DELAYED_WORK_UPSTREAM_COMMIT}"
    fi
}

verify_aosp_backport_source() {
    local label="$1" source_ref="$2" commit="$3" commit_date="$4" patch_id="$5" expected_paths="$6"
    local actual_date actual_patch_id actual_paths pair source_ref_commit=""
    [ "${ENABLE_BACKPORT_AUDIT}" = "1" ] || die "${label} 需要启用固定 AOSP 审计源"
    for pair in ${AOSP_BACKPORT_AUDIT_REFS}; do
        if [ "${pair%%:*}" = "${source_ref}" ]; then
            source_ref_commit="${pair#*:}"
            break
        fi
    done
    [ -n "${source_ref_commit}" ] || die "${label} 来源 ref 未固定: ${source_ref}"
    env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        merge-base --is-ancestor "${commit}" "${source_ref_commit}" || \
        die "${label} 不属于固定 AOSP 来源 ref"
    actual_date="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${AOSP_BACKPORT_AUDIT_DIR}" show -s --format=%cs "${commit}")"
    [ "${actual_date}" = "${commit_date}" ] || die "${label} 提交日期不匹配: ${actual_date}"
    [[ "${commit_date}" < "${BACKPORT_AUDIT_SNAPSHOT}" ||
       "${commit_date}" = "${BACKPORT_AUDIT_SNAPSHOT}" ]] || \
        die "${label} 晚于固定审计快照"
    actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${AOSP_BACKPORT_AUDIT_DIR}" \
        diff-tree --no-commit-id --name-only -r "${commit}" | LC_ALL=C sort | paste -sd ' ' -)"
    [ "${actual_paths}" = "${expected_paths}" ] || die "${label} 触及非预期路径: ${actual_paths}"
    actual_patch_id="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false \
        -C "${AOSP_BACKPORT_AUDIT_DIR}" show --format= "${commit}" |
        git patch-id --stable | awk '{ print $1 }')"
    [ "${actual_patch_id}" = "${patch_id}" ] || die "${label} patch-id 不匹配"
    log_success "${label} 官方来源已固定"
}
