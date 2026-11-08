#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

verify_toolchain_identity() {
    local rustc_verbose
    [ "$("${CI_TOOLCHAIN_DIR}/bin/clang" --version | sed -n '1p')" = "${CI_CLANG_VERSION_LINE}" ] || \
        die "Clang 编译器版本不匹配"
    rustc_verbose="$("${CI_TOOLCHAIN_DIR}/rust/bin/rustc" --version --verbose)"
    printf '%s\n' "${rustc_verbose}" | grep -Fqx "commit-hash: ${CI_RUSTC_COMMIT_HASH}" || \
        die "Rust 编译器 commit-hash 不匹配"
    printf '%s\n' "${rustc_verbose}" | grep -Fqx "release: ${CI_RUSTC_RELEASE:?缺少 Rust 编译器 release pin}" || \
        die "Rust 编译器 release 不匹配"
    printf '%s\n' "${rustc_verbose}" | sed -n '1p' | \
        grep -Fq "(Android Rust Toolchain version ${CI_RUST_TOOLCHAIN_VERSION})" || \
        die "Rust 工具链构建标识不匹配"
    [ "$("${CI_TOOLCHAIN_DIR}/bin/bindgen" --version)" = "bindgen ${CI_BINDGEN_VERSION}" ] || \
        die "bindgen 版本不匹配"
}

prepare_fixed_git_subtree() {
    local label="$1" cache_dir="$2" repo="$3" commit="$4" subtree="$5"
    local expected_tree="$6" expected_leaf="$7"
    shift 7
    local sparse_paths=("$@")
    local payload_dir actual_url actual_commit actual_tree actual_leaf path

    [ "${#sparse_paths[@]}" -gt 0 ] || die "${label} 缺少稀疏检出路径"
    payload_dir="${cache_dir}/${subtree}"
    mkdir -p "${cache_dir}"
    if [ ! -d "${cache_dir}/.git" ]; then
        [ -z "$(find "${cache_dir}" -mindepth 1 -print -quit)" ] || \
            die "${label} Git 缓存目录不是空目录: ${cache_dir}"
        git -c core.hooksPath=/dev/null init -q "${cache_dir}" || \
            die "初始化 ${label} Git 缓存失败"
        git -C "${cache_dir}" remote add origin "${repo}"
    fi
    reject_git_object_overrides "${label}" "${cache_dir}"
    actual_url="$(git -C "${cache_dir}" remote get-url origin 2>/dev/null || true)"
    [ "$(normalize_git_url "${actual_url}")" = "$(normalize_git_url "${repo}")" ] || \
        die "${label} remote 不匹配: ${actual_url}"
    git -C "${cache_dir}" config core.hooksPath /dev/null
    git -C "${cache_dir}" config fetch.fsckObjects true
    git -C "${cache_dir}" config transfer.fsckObjects true
    git -C "${cache_dir}" config remote.origin.promisor true
    git -C "${cache_dir}" config remote.origin.partialclonefilter blob:none

    if ! git -C "${cache_dir}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log_step "获取固定 ${label} 提交与对象树"
        git_network -c fetch.fsckObjects=true \
            -C "${cache_dir}" fetch --depth=1 --no-tags --filter=blob:none origin "${commit}" || \
            die "获取固定 ${label} 提交失败"
    else
        log_success "复用固定 ${label} 本地提交"
    fi
    actual_commit="$(git -C "${cache_dir}" rev-parse "${commit}^{commit}")"
    [ "${actual_commit}" = "${commit}" ] || die "${label} commit 不匹配: ${actual_commit}"
    actual_tree="$(git -C "${cache_dir}" rev-parse "${commit}:${subtree}")"
    [ "${actual_tree}" = "${expected_tree}" ] || \
        die "${label} 目标 Git tree 不匹配: ${actual_tree}"
    if git -C "${cache_dir}" rev-parse --verify HEAD >/dev/null 2>&1; then
        [ "$(git -C "${cache_dir}" rev-parse HEAD)" = "${commit}" ] || \
            die "${label} checkout commit 不匹配"
        [ -z "$(git -C "${cache_dir}" status --porcelain --untracked-files=all)" ] || \
            die "${label} checkout 存在本地修改"
    fi

    git_network -C "${cache_dir}" sparse-checkout init --cone
    git_network -C "${cache_dir}" sparse-checkout set "${sparse_paths[@]}"
    git_network -C "${cache_dir}" checkout -q --detach "${commit}" || \
        die "检出固定 ${label} 提交失败"
    [ "$(git -C "${cache_dir}" rev-parse HEAD)" = "${commit}" ] || \
        die "${label} checkout commit 发生变化"
    [ -z "$(git -C "${cache_dir}" status --porcelain --untracked-files=all)" ] || \
        die "${label} checkout 存在本地修改"
    actual_leaf="$(tree_sha256 "${payload_dir}")"
    [ "${actual_leaf}" = "${expected_leaf}" ] || \
        die "${label} 已检出文件树 SHA-256 不匹配: ${actual_leaf}"
    log_success "固定 ${label} 对象树完整性校验通过"
}

prepare_clang_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-clang-git-${AOSP_CLANG_COMMIT}"
    local subtree="clang-${CI_CLANG_REVISION}"
    local paths=(
        "${subtree}/bin"
        "${subtree}/include"
        "${subtree}/lib/clang/22/include"
        "${subtree}/lib/clang/22/share"
        "${subtree}/lib/x86_64-unknown-linux-gnu"
        "${subtree}/libexec"
        "${subtree}/prebuilt_include"
        "${subtree}/share"
    )
    prepare_fixed_git_subtree "AOSP Clang 工具链" "${cache_dir}" \
        "${AOSP_CLANG_REPO}" "${AOSP_CLANG_COMMIT}" "${subtree}" \
        "${CI_CLANG_GIT_TREE}" "${CI_CLANG_LEAF_TREE_SHA256}" "${paths[@]}"
}

prepare_rust_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-rust-${AOSP_RUST_COMMIT}"
    local paths=(
        "${CI_RUST_SUBTREE}/bin"
        "${CI_RUST_SUBTREE}/etc"
        "${CI_RUST_SUBTREE}/lib64"
        "${CI_RUST_SUBTREE}/libexec"
        "${CI_RUST_SUBTREE}/share/doc/rustc/licenses"
        "${CI_RUST_SUBTREE}/lib/rustlib/etc"
        "${CI_RUST_SUBTREE}/lib/rustlib/src"
        "${CI_RUST_SUBTREE}/lib/rustlib/x86_64-unknown-linux-gnu"
    )
    prepare_fixed_git_subtree "AOSP Rust 工具链" "${cache_dir}" \
        "${AOSP_RUST_REPO}" "${AOSP_RUST_COMMIT}" "${CI_RUST_SUBTREE}" \
        "${CI_RUST_GIT_TREE}" "${CI_RUST_LEAF_TREE_SHA256}" "${paths[@]}"
}

prepare_build_tools_source_tree() {
    local cache_dir="${WORK_DIR}/cache/toolchains/aosp-build-tools-${AOSP_BUILD_TOOLS_COMMIT}"
    local paths=(
        "${CI_BUILD_TOOLS_SUBTREE}/bin"
        "${CI_BUILD_TOOLS_SUBTREE}/include"
        "${CI_BUILD_TOOLS_SUBTREE}/lib64"
        "${CI_BUILD_TOOLS_SUBTREE}/share"
    )
    prepare_fixed_git_subtree "AOSP kernel build-tools" "${cache_dir}" \
        "${AOSP_BUILD_TOOLS_REPO}" "${AOSP_BUILD_TOOLS_COMMIT}" \
        "${CI_BUILD_TOOLS_SUBTREE}" "${CI_BUILD_TOOLS_GIT_TREE}" \
        "${CI_BUILD_TOOLS_LEAF_TREE_SHA256}" "${paths[@]}"
}

stop_toolchain_fetches() {
    local pid
    trap '' INT TERM
    # Include a job interrupted between its launch and PID registration.
    for pid in $(jobs -pr); do fetch_pids+=("${pid}"); done
    for pid in "${fetch_pids[@]}"; do
        kill -TERM -- "-${pid}" 2>/dev/null || true
    done
    if [ "${#fetch_pids[@]}" -gt 0 ]; then
        sleep 0.2
        for pid in "${fetch_pids[@]}"; do
            kill -KILL -- "-${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        done
    fi
}

run_init_tasks() {
    local task index next=0 monitor_enabled=0
    local -a fetch_pids=() tasks=("$@")

    case "$-" in *m*) monitor_enabled=1 ;; esac
    # Separate process groups let cancellation stop Git and all its helpers.
    set -m
    trap stop_toolchain_fetches EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while [ "${next}" -lt "${#tasks[@]}" ] || [ "${#fetch_pids[@]}" -gt 0 ]; do
        for index in "${!fetch_pids[@]}"; do
            # Plain wait retains completed statuses on Bash 5.2. Reap every
            # completed worker before filling slots, including failed workers.
            if ! kill -0 "${fetch_pids[$index]}" 2>/dev/null; then
                wait "${fetch_pids[$index]}" || die "固定依赖准备失败，停止安装"
                unset 'fetch_pids[index]'
            fi
        done
        fetch_pids=("${fetch_pids[@]}")
        while [ "${#fetch_pids[@]}" -lt "${INIT_FETCH_JOBS}" ] && \
                [ "${next}" -lt "${#tasks[@]}" ]; do
            task="${tasks[$next]}"
            (trap - EXIT INT TERM; "${task}") &
            fetch_pids+=("$!")
            next=$((next + 1))
        done
        [ "${#fetch_pids[@]}" -eq 0 ] || sleep 0.05
    done
    trap - EXIT INT TERM
    [ "${monitor_enabled}" = 1 ] || set +m
}

prepare_toolchain_source_trees() {
    # Child shells cannot return variables; derive all paths before launching.
    CI_CLANG_PAYLOAD_DIR="${WORK_DIR}/cache/toolchains/aosp-clang-git-${AOSP_CLANG_COMMIT}/clang-${CI_CLANG_REVISION}"
    CI_RUST_PAYLOAD_DIR="${WORK_DIR}/cache/toolchains/aosp-rust-${AOSP_RUST_COMMIT}/${CI_RUST_SUBTREE}"
    CI_BUILD_TOOLS_PAYLOAD_DIR="${WORK_DIR}/cache/toolchains/aosp-build-tools-${AOSP_BUILD_TOOLS_COMMIT}/${CI_BUILD_TOOLS_SUBTREE}"
    run_init_tasks prepare_clang_source_tree prepare_rust_source_tree prepare_build_tools_source_tree
}

prepare_toolchain_assets() {
    local file expected actual blob
    mkdir -p "${DL_DIR}"
    for file in "$@"; do
        expected="${TC_SHA256[$file]:-}"
        blob="${TC_GIT_BLOB[$file]:-}"
        [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] || die "工具链资产缺少固定 SHA-256: ${file}"
        if [ ! -f "${DL_DIR}/${file}" ]; then
            log_step "下载固定工具链资产: ${file}"
            curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 30 \
                --speed-time 180 --speed-limit 1024 --retry 3 \
                -o "${DL_DIR}/${file}.part" "${TC_PKGS[$file]}" || die "下载失败: ${file}"
            if [ -n "${blob}" ]; then
                base64 --decode "${DL_DIR}/${file}.part" > "${DL_DIR}/${file}.decoded" || \
                    die "Gitiles 文件解码失败: ${file}"
                mv "${DL_DIR}/${file}.decoded" "${DL_DIR}/${file}.part"
            fi
            actual="$(sha256sum "${DL_DIR}/${file}.part" | awk '{ print $1 }')"
            [ "${actual}" = "${expected}" ] || die "工具链下载文件 SHA-256 不匹配: ${file} ${actual}"
            if [ -n "${blob}" ]; then
                [ "$(git hash-object --no-filters "${DL_DIR}/${file}.part")" = "${blob}" ] || \
                    die "工具链下载文件 Git blob 不匹配: ${file}"
            fi
            mv "${DL_DIR}/${file}.part" "${DL_DIR}/${file}"
        fi
        actual="$(sha256sum "${DL_DIR}/${file}" | awk '{ print $1 }')"
        [ "${actual}" = "${expected}" ] || die "工具链缓存 SHA-256 不匹配: ${file} ${actual}"
        if [ -n "${blob}" ]; then
            [ "$(git hash-object --no-filters "${DL_DIR}/${file}")" = "${blob}" ] || \
                die "工具链缓存 Git blob 不匹配: ${file}"
        fi
    done
}

setup_toolchain() {
    local actual marker="${CI_TOOLCHAIN_DIR}.project-tree-sha256" staging backup rust_bin compiler prepared
    mkdir -p "${DL_DIR}" "$(dirname "${CI_TOOLCHAIN_DIR}")"
    prepare_toolchain_source_trees
    prepare_toolchain_assets bindgen gavinhoward-bc
    if [ -e "${CI_TOOLCHAIN_DIR}" ]; then
        [ "$(tree_sha256 "${CI_TOOLCHAIN_DIR}")" = "${CI_TOOLCHAIN_TREE_SHA256}" ] || die "现有工具链内容不匹配，拒绝覆盖"
        verify_toolchain_identity
        return
    fi

    staging="$(mktemp -d "$(dirname "${CI_TOOLCHAIN_DIR}")/.ci-toolchain-install.XXXXXX")"
    if ! {
        cp -a "${CI_CLANG_PAYLOAD_DIR}/." "${staging}/" &&
        mkdir -p "${staging}/rust" "${staging}/build-tools" "${staging}/host-bin" &&
        cp -a "${CI_RUST_PAYLOAD_DIR}/." "${staging}/rust/" &&
        cp -a "${CI_BUILD_TOOLS_PAYLOAD_DIR}/." "${staging}/build-tools/" &&
        find "${staging}" -type d -exec chmod 0775 {} + &&
        find "${staging}" -type f -perm /111 -exec chmod 0775 {} + &&
        find "${staging}" -type f ! -perm /111 -exec chmod 0664 {} + &&
        cp -f "${DL_DIR}/bindgen" "${staging}/bin/bindgen" &&
        cp -f "${DL_DIR}/gavinhoward-bc" "${staging}/host-bin/bc" &&
        chmod 0755 "${staging}/bin/bindgen" "${staging}/host-bin/bc";
    }; then
        python3 -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "${staging}"
        die "固定工具链安装失败"
    fi
    { printf '#!/usr/bin/env sh\n'; printf 'for arg do\n'; printf '  case "$arg" in\n'; printf '    -m64) exec /usr/bin/x86_64-linux-gnu-gcc "$@" ;;\n'; printf '  esac\n'; printf 'done\n'; printf 'exec /usr/bin/cc "$@"\n'; } > "${staging}/host-bin/cc"
    chmod 0755 "${staging}/host-bin/cc"
    rust_bin="${staging}/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin"
    mkdir -p "${rust_bin}"
    for compiler in cc gcc; do
        { printf '#!/usr/bin/env sh\n'; printf 'exec /usr/bin/x86_64-linux-gnu-gcc "$@"\n'; } > "${rust_bin}/${compiler}"
        chmod 0755 "${rust_bin}/${compiler}"
    done
    actual="$(tree_sha256 "${staging}")"
    if [ "${actual}" != "${CI_TOOLCHAIN_TREE_SHA256}" ]; then
        python3 -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "${staging}"
        die "固定工具链安装树指纹不匹配: ${actual}"
    fi
    mv "${staging}" "${CI_TOOLCHAIN_DIR}"
    printf '%s\n' "${CI_TOOLCHAIN_TREE_SHA256}" > "${marker}"
    verify_toolchain_identity
    log_success "固定工具链准备完成: $("${CI_TOOLCHAIN_DIR}/bin/clang" --version | sed -n '1p')"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    . "$(dirname -- "${BASH_SOURCE[0]}")/context.sh"
    load_context "$@"
    declare -A TC_PKGS=( [bindgen]="${CI_BINDGEN_URL}" [gavinhoward-bc]="${CI_HOST_BC_URL}" )
    declare -A TC_SHA256=( [bindgen]="${CI_BINDGEN_SHA256}" [gavinhoward-bc]="${CI_HOST_BC_SHA256}" )
    declare -A TC_GIT_BLOB=( [bindgen]="${CI_BINDGEN_GIT_BLOB}" [gavinhoward-bc]="${CI_HOST_BC_GIT_BLOB}" )
    setup_toolchain
fi
