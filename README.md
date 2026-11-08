# Luna Kernel CI 固定依赖

本仓库制作和托管 Luna Kernel 的固定 CI 依赖、官方来源审计工具与来源元数据。归档由固定 AOSP/Linux 输入组装，日常构建通过主项目的 v1 内容协议校验和消费。

## 制作与审计

在 Linux 上准备 Bash、Git、Python 3.12+、curl、zstd 和常用 GNU 工具。主项目输入使用固定提交的 LF 检出；`.env`、回移清单和项目适配补丁必须匹配该提交。制作代码从该输入引用 `tools/ci_dependencies.py` 的 v1 协议、`tools/backport_manifest.sh` 的纯函数库与 `tools/tree_sha256.py`。

```bash
project=/path/to/android_kernel_xiaomi_sm8850
commit=$(git -C "$project" rev-parse HEAD)
bash tools/prepare_ci_dependencies.sh \
  --project "$project" --project-commit "$commit" \
  --work "$PWD/work" --output "$PWD/output/prepared-v2"
```

`--work` 默认为本仓库 `work/`，缓存官方 AOSP、stable、mainline、Kbuild 来源及 Clang/Rust/build-tools；`--output` 必须是新目录，省略时自动在 `output/prepared.*/` 创建。制作仅准备官方回移审计和工具链：来源证明检查固定仓库、提交关系、日期、patch-id、路径及项目适配，工具链保持既有安装树摘要。结果包含 `backports/manifest.json`、补丁与许可证、`backports.tar.gz`、`toolchain.tar.zst` 和三项真实摘要的 `pins.env`。新产物记录主项目提交、共享协议文件摘要和本仓库制作代码身份。

单独准备及复核来源：

```bash
bash tools/prepare_sources.sh --project "$project" --project-commit "$commit" --work "$PWD/work"
bash tools/audit_sources.sh --project "$project" --project-commit "$commit" --work "$PWD/work"
```

候选历史调查先给 `prepare_sources.sh` 加 `--audit-history`，再运行 `tools/backport_audit.sh`，传入相同三个参数。结果保存于 `work/audit/backport-<固定快照日期>/`，按主项目 `WORK_HISTORY_KEEP` 轮换本仓库的历史记录。

轻量检查：`bash tools/check.sh --project "$project"`。检查包含 shell/Python 语法、真实 Git fixture 的来源校验、拒绝错误来源/日期/祖先链、v1 导出打包消费往返及历史轮换边界。

## 固定版本

Release：`ci-deps-v1-3fc59ff`，制作代码来自主项目固定提交 [`3fc59ff33c4748298462b1db44c4e4ffd6cc4508`](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/tree/3fc59ff33c4748298462b1db44c4e4ffd6cc4508)。现有 Release 的 manifest、provenance 和摘要保留原始身份。使用精确版本 URL。

| 文件 | SHA-256 |
| --- | --- |
| `backports.tar.gz` | `8e0d882f36a730766861a274d15d7243a4609f6634f46d88a86c4a62b2e2515e` |
| `backports-manifest.json` | `cb9baf8d9e35b99f59fc9a8c7af5f150597f5b49f082d25e4cd2629b644b34f4` |
| `toolchain.tar.zst` | `65e911abbba148cac0d81f2678f1a4282da513f8f7004e8cc263bdaccc573fe6` |

工具链安装树 SHA-256：`9ac803933946fd3dff326f8da8853fc5b23ae7da613f6ceb611d8cc5587bf985`。归档与安装树分别校验。

补丁包保存实际补丁、逐文件摘要、许可证、官方来源、提交关系与制作身份。工具链包保存安装目录和 `provenance.json`。

主项目以受版本控制的摘要接受依赖，并执行内容、工具身份、补丁应用与构建检查。更新依赖时重新审计固定官方输入，在干净环境复核后发布新版本，保留既有版本。

## 上游声明与源码定位

本仓库制作与审计脚本采用 [GPL-2.0-only](LICENSE)，上游组件保留各自许可证。

`upstream-notices/` 与同名 Release 归档保存预编译仓库的固定源码 manifest，以及 bindgen、bc、e2fsprogs、dwarves、SWIG、musl 和 erofs-utils 的许可证与版权声明。`SOURCES.json` 记录固定 URL、SHA-256 和源码提交；Clang/Rust 原有声明保留在工具链包中。

源码 manifest 记录上游制作环境。bc 的 AOSP 源码提交在 v1 制作时返回 HTTP 404，其许可证取自另行固定提交的官方 `gavinhoward/bc` 仓库，具体来源记录在 `SOURCES.json`。
