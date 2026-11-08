#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

manifest_pin_name() {
	local base key
	base="$(basename "$1" .tsv)"
	key="$(tr '[:lower:]-' '[:upper:]_' <<<"${base}")"
	printf 'INDEPENDENT_%s_SHA256\n' "${key}"
}

discover_manifests() {
	local manifest base pin_name pin_value variable expected_file
	MANIFESTS=()
	if [ -d "${MANIFEST_DIR}" ]; then
		shopt -s nullglob
		MANIFESTS=("${MANIFEST_DIR}"/[0-9][0-9][0-9]-*.tsv)
		shopt -u nullglob
	fi
	for manifest in "${MANIFESTS[@]}"; do
		base="$(basename "${manifest}")"
		[[ "${base}" =~ ^[0-9]{3}-[a-z0-9]+(-[a-z0-9]+)*\.tsv$ ]] || \
			die "独立回移清单文件名非法: ${base}"
		[ -f "${manifest}" ] && [ ! -L "${manifest}" ] || \
			die "独立回移清单缺失或不安全: ${base}"
		pin_name="$(manifest_pin_name "${manifest}")"
		pin_value="${!pin_name:-}"
		[[ "${pin_value}" =~ ^[0-9a-f]{64}$ ]] || \
			die "${base} 缺少独立 SHA-256 pin: ${pin_name}"
	done
	while IFS= read -r variable; do
		case "${variable}" in
			INDEPENDENT_[0-9][0-9][0-9]_*_SHA256)
				expected_file="${variable#INDEPENDENT_}"
				expected_file="${expected_file%_SHA256}"
				expected_file="$(tr '[:upper:]_' '[:lower:]-' <<<"${expected_file}").tsv"
				[ -f "${MANIFEST_DIR}/${expected_file}" ] || \
					die "独立回移 SHA-256 pin 没有对应清单: ${variable}"
				;;
		esac
	done < <(compgen -A variable | LC_ALL=C sort)
}

select_manifest() {
	local manifest="$1"
	[ "${MANIFESTS_READY}" = 1 ] && [ -n "${BATCH_PINS[${manifest}]:-}" ] || \
		die "清单尚未由本次调用验证"
	MANIFEST="${manifest}"
	MANIFEST_SHA256="${BATCH_PINS[${manifest}]}"
	INDEPENDENT_MANIFEST=1
	mapfile -t MANIFEST_ROWS <<<"${BATCH_ROWS[${manifest}]}"
	GROUP_COUNT="${BATCH_GROUPS[${manifest}]}"
	TMP_ROOT="${BATCH_TMP[${manifest}]:-}"
}

verify_manifests() {
	local manifest pin_name row duplicates overlap
	local order group action source ref commit rest
	local -a new_commits=() old_commits=()
	[ "${MANIFESTS_READY}" != 1 ] || return 0
	discover_manifests
	for manifest in "${MANIFESTS[@]}"; do
		MANIFEST="${manifest}"
		pin_name="$(manifest_pin_name "${manifest}")"
		MANIFEST_SHA256="${!pin_name}"
		INDEPENDENT_MANIFEST=1
		validate_manifest
		BATCH_ROWS["${manifest}"]="$(printf '%s\n' "${MANIFEST_ROWS[@]}")"
		BATCH_GROUPS["${manifest}"]="${GROUP_COUNT}"
		BATCH_PINS["${manifest}"]="${MANIFEST_SHA256}"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
			new_commits+=("${commit}")
		done
	done
	if [ "${#MANIFESTS[@]}" = 0 ]; then
		MANIFESTS_READY=1
		return 0
	fi
	duplicates="$(printf '%s\n' "${new_commits[@]}" | LC_ALL=C sort | uniq -d)"
	[ -z "${duplicates}" ] || die "独立回移清单存在重复官方提交:\n${duplicates}"
	MANIFEST="$(resolve_workspace_path "${SELECTED_BACKPORT_MANIFEST:-patches/backports/kmi6-2026-09-selected-backports.tsv}")"
	MANIFEST_SHA256="${SELECTED_BACKPORT_MANIFEST_SHA256:-}"
	INDEPENDENT_MANIFEST=0
	validate_manifest
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
		old_commits+=("${commit}")
	done
	overlap="$(printf '%s\n' "${new_commits[@]}" "${old_commits[@]}" | LC_ALL=C sort | uniq -d)"
	[ -z "${overlap}" ] || die "独立回移与现有固定集合重复:\n${overlap}"
	MANIFESTS_READY=1
}

list_commits() {
	local requested_source="$1" manifest row order group action source ref commit rest
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS=$'\t' read -r order group action source ref commit rest <<<"${row}"
			[ "${source}" != "${requested_source}" ] || printf '%s\n' "${commit}"
		done
	done
}

verify_all_sources() {
	local manifest
	[ "${SOURCES_READY}" != 1 ] || return 0
	verify_manifests
	for manifest in "${MANIFESTS[@]}"; do
		select_manifest "${manifest}"
		verify_sources
	done
	SOURCES_READY=1
}
