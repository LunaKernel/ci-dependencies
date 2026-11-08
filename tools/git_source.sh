#!/usr/bin/env bash
# 官方来源准备与审计；迁自主项目固定实现。

die() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
log_info() { printf '[INFO] %s\n' "$1"; }
log_step() { printf '[STEP] %s\n' "$1"; }
log_success() { printf '[OK] %s\n' "$1"; }
normalize_git_url() { printf '%s' "$1" | sed -e 's#/$##' -e 's#\.git$##'; }

git_network() {
    env -u GIT_NO_LAZY_FETCH GIT_TERMINAL_PROMPT=0 git \
        -c core.hooksPath=/dev/null \
        -c credential.helper= \
        -c credential.interactive=false \
        -c http.proactiveAuth=none \
        -c http.version=HTTP/1.1 \
        "$@"
}

reject_git_object_overrides() {
    local label="$1" repo_dir="$2" git_dir replace_refs unexpected_config
    local hooks_path is_bare top_level
    git_dir="$(git -C "${repo_dir}" rev-parse --absolute-git-dir 2>/dev/null)" || \
        die "${label} 不是 Git 仓库"
    replace_refs="$(git -C "${repo_dir}" for-each-ref --format='%(refname)' refs/replace/)"
    [ -z "${replace_refs}" ] || die "${label} 存在 refs/replace 对象替换:\n${replace_refs}"
    [ ! -s "${git_dir}/info/grafts" ] || die "${label} 存在 info/grafts 对象替换"
    [ ! -s "${git_dir}/info/attributes" ] || die "${label} 存在 info/attributes 工作树过滤覆盖"
    unexpected_config="$(git -C "${repo_dir}" config --name-only --list | LC_ALL=C sort -u | awk '
        /^core\.(repositoryformatversion|filemode|bare|logallrefupdates|hookspath|sparsecheckout|sparsecheckoutcone|ignorecase|precomposeunicode)$/ { next }
        /^extensions\.worktreeconfig$/ { next }
        /^remote\.origin\.(url|fetch|promisor|partialclonefilter|tagopt)$/ { next }
        /^branch\..+\.(remote|merge)$/ { next }
        /^(fetch|transfer)\.fsckobjects$/ { next }
        /^backport\.[a-z0-9.]+$/ { next }
        { print }
    ')"
    [ -z "${unexpected_config}" ] || \
        die "${label} 存在非白名单 Git 配置:\n${unexpected_config}"
    hooks_path="$(git -C "${repo_dir}" config --path --get core.hooksPath 2>/dev/null || true)"
    [ -z "${hooks_path}" ] || [ "${hooks_path}" = "/dev/null" ] || \
        die "${label} 存在非隔离 Git hooks 路径: ${hooks_path}"
    is_bare="$(git -C "${repo_dir}" rev-parse --is-bare-repository)"
    if [ "${is_bare}" = "false" ]; then
        top_level="$(git -C "${repo_dir}" rev-parse --show-toplevel)"
        [ "$(realpath -e "${repo_dir}")" = "$(realpath -e "${top_level}")" ] || \
            die "${label} Git worktree 与预期目录不一致: ${top_level}"
    fi
}
