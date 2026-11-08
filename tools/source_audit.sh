#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

verify_audit_repo() {
	local label="$1" repo="$2" expected_url="$3"
	local actual_url git_dir replace_refs unexpected_config
	# 同次调用的审计仓库不被修改；清单共用的仓库只验证一次。
	[ "${VERIFIED_AUDIT_REPOS["${repo}|${expected_url}"]:-}" != 1 ] || return 0
	[ "$(git -C "${repo}" rev-parse --is-bare-repository 2>/dev/null)" = true ] || \
		die "${label} 不是 bare 审计仓库，请先运行 tools/prepare_sources.sh"
	git_dir="$(git -C "${repo}" rev-parse --absolute-git-dir)"
	actual_url="$(git -C "${repo}" remote get-url origin 2>/dev/null || true)"
	[ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${expected_url}")" ] || \
		die "${label} remote 不匹配: ${actual_url}"
	replace_refs="$(git -C "${repo}" for-each-ref --format='%(refname)' refs/replace/)"
	[ -z "${replace_refs}" ] || die "${label} 存在 refs/replace 对象替换"
	[ ! -s "${git_dir}/info/grafts" ] || die "${label} 存在 info/grafts 对象替换"
	[ ! -s "${git_dir}/info/attributes" ] || die "${label} 存在 info/attributes 差异覆盖"
	[ ! -s "${git_dir}/objects/info/alternates" ] || die "${label} 存在外部 object alternates"
	unexpected_config="$(git -C "${repo}" config --name-only --list | LC_ALL=C sort -u | awk '
		/^core\.(repositoryformatversion|filemode|bare|hookspath)$/ { next }
		/^remote\.origin\.(url|fetch|promisor|partialclonefilter)$/ { next }
		/^backport\.[a-z0-9.]+$/ { next }
		{ print }
	')"
	[ -z "${unexpected_config}" ] || die "${label} 存在非白名单 Git 配置:\n${unexpected_config}"
	VERIFIED_AUDIT_REPOS["${repo}|${expected_url}"]=1
}

aosp_tip() {
	local requested_ref="$1" pair found=""
	for pair in ${AOSP_BACKPORT_AUDIT_REFS:-}; do
		[ "${pair%%:*}" = "${requested_ref}" ] || continue
		[ -z "${found}" ] || die "AOSP ref 重复: ${requested_ref}"
		found="${pair#*:}"
	done
	[ -n "${found}" ] || die "AOSP ref 未固定: ${requested_ref}"
	printf '%s\n' "${found}"
}

source_repo_and_tip() {
	local source="$1" ref="$2"
	case "${source}" in
		aosp)
			SOURCE_REPO="${AOSP_DIR}"
			SOURCE_TIP="$(aosp_tip "${ref}")"
			;;
		stable)
			[ "${ref}" = "${LINUX_STABLE_AUDIT_REF:-}" ] || die "Linux stable ref 不匹配"
			SOURCE_REPO="${STABLE_DIR}"
			SOURCE_TIP="${LINUX_STABLE_AUDIT_COMMIT:-}"
			;;
		mainline)
			[ "${ref}" = "snapshot-${BACKPORT_AUDIT_SNAPSHOT:-}" ] || die "Linux mainline ref 不匹配"
			SOURCE_REPO="${MAINLINE_DIR}"
			SOURCE_TIP="${LINUX_MAINLINE_AUDIT_COMMIT:-}"
			;;
		kbuild)
			[ "${ref}" = "${KBUILD_AUDIT_REF:-}" ] || die "Kbuild ref 不匹配"
			SOURCE_REPO="${KBUILD_DIR}"
			SOURCE_TIP="${KBUILD_AUDIT_COMMIT:-}"
			;;
		*) die "未知官方来源: ${source}" ;;
	esac
	[ -n "${SOURCE_TIP}" ] || die "${source} 审计终点为空"
}

verify_source_row() {
	local row="$1" order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id actual_date actual_paths actual_patch_id
	local parents patch_output
	IFS=$'\t' read -r order group action source ref commit date patch_id paths \
		project_patch project_sha project_patch_id <<<"${row}"
	source_repo_and_tip "${source}" "${ref}"
	[ -d "${SOURCE_REPO}" ] || die "${source} 审计仓库缺失，请先运行 tools/prepare_sources.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" cat-file -e "${SOURCE_TIP}^{commit}" 2>/dev/null || \
		die "${source} 固定审计终点对象缺失，请先运行 tools/prepare_sources.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" cat-file -e "${commit}^{commit}" 2>/dev/null || \
		die "${group} 官方提交对象缺失，请先运行 tools/prepare_sources.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" merge-base --is-ancestor \
		"${commit}" "${SOURCE_TIP}" || die "${group} 不属于固定 ${source} 审计终点"
	parents="$(env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" rev-list --parents -n 1 "${commit}")"
	[ "$(awk '{ print NF }' <<<"${parents}")" = 2 ] || die "${group} 官方对象不是单父提交"
	actual_date="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
		show -s --format=%cs "${commit}")"
	[ "${actual_date}" = "${date}" ] || die "${group} 官方提交日期不匹配: ${actual_date}"
	actual_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${SOURCE_REPO}" diff-tree \
		--no-commit-id --name-only -r "${commit}" | LC_ALL=C sort -u | paste -sd, -)"
	[ "${actual_paths}" = "${paths}" ] || die "${group} 官方提交路径不匹配: ${actual_paths}"
	patch_output="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${SOURCE_REPO}" \
		show --format= "${commit}" | git patch-id --stable)"
	[ "$(wc -l <<<"${patch_output}")" = 1 ] || die "${group} 官方提交 patch-id 输出异常"
	actual_patch_id="${patch_output%% *}"
	[ "${actual_patch_id}" = "${patch_id}" ] || die "${group} 官方提交 patch-id 不匹配"
	if [ "${source}" = stable ]; then
		verify_stable_origin "${group}" "${commit}" "${actual_paths}"
	fi

	if [ "${action}" = adapt ]; then
		verify_project_patch "${group}" "${paths}" "${project_patch}" \
			"${project_sha}" "${project_patch_id}" "${source}" "${commit}"
	fi
}

verify_stable_origin() {
	local group="$1" commit="$2" stable_paths="$3"
	local message upstream upstream_paths stable_subject upstream_subject count
	case " ${LINUX_STABLE_STANDALONE_COMMITS:-} " in
		*" ${commit} "*) return ;;
	esac
	message="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
		show -s --format=%B "${commit}")"
	upstream="$(printf '%s\n' "${message}" | sed -n -E \
		-e 's/^\[ Upstream commit ([0-9a-f]{40}) \]$/\1/p' \
		-e 's/^commit ([0-9a-f]{40}) upstream\.$/\1/p' | LC_ALL=C sort -u)"
	count="$(grep -c . <<<"${upstream}" || true)"
	[ "${count}" = 1 ] || die "${group} stable 提交未唯一绑定 mainline 原始提交"
	env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" cat-file \
		-e "${upstream}^{commit}" 2>/dev/null || \
		die "${group} mainline 原始提交对象缺失，请先运行 tools/prepare_sources.sh"
	env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" merge-base --is-ancestor \
		"${upstream}" "${LINUX_MAINLINE_AUDIT_COMMIT}" || \
		die "${group} mainline 原始提交不属于固定审计快照"
	upstream_paths="$(env GIT_NO_LAZY_FETCH=1 git -C "${MAINLINE_DIR}" diff-tree \
		--no-commit-id --name-only -r "${upstream}" | LC_ALL=C sort -u | paste -sd, -)"
	[ "${upstream_paths}" = "${stable_paths}" ] || \
		die "${group} stable 与 mainline 原始提交路径不一致"
	stable_subject="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
		show -s --format=%s "${commit}")"
	upstream_subject="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${MAINLINE_DIR}" \
		show -s --format=%s "${upstream}")"
	[ "${stable_subject}" = "${upstream_subject}" ] || \
		die "${group} stable 与 mainline 原始提交标题不一致"
}

verify_sources() {
	local row stable_message order group action source ref commit date patch_id paths
	local project_patch project_sha project_patch_id
	verify_audit_repo "AOSP common 审计源" "${AOSP_DIR}" "${COMMON_REPO}"
	verify_audit_repo "Linux stable 审计源" "${STABLE_DIR}" "${LINUX_STABLE_AUDIT_REPO}"
	verify_audit_repo "Linux mainline 审计源" "${MAINLINE_DIR}" "${LINUX_MAINLINE_AUDIT_REPO}"
	if awk -F '\t' '!/^#/ && $4 == "kbuild" { found=1 } END { exit !found }' "${MANIFEST}"; then
		verify_audit_repo "Kbuild 官方审计源" "${KBUILD_DIR}" "${KBUILD_AUDIT_REPO}"
	fi
	for row in "${MANIFEST_ROWS[@]}"; do
		verify_source_row "${row}"
	done
	if [ "${INDEPENDENT_MANIFEST}" != 1 ]; then
		stable_message="$(env GIT_NO_LAZY_FETCH=1 git -c log.mailmap=false -C "${STABLE_DIR}" \
			show -s --format=%B 7be222de96c0f9eee6e65eeb017ef855ee185cfa)"
		grep -Fx '[ Upstream commit 2d9c4a4ed4eef1f82c5b16b037aee8bad819fd53 ]' \
			<<<"${stable_message}" >/dev/null || die "普通 F2FS stable 修复未绑定固定 mainline 提交"
	fi
}
