# Luna Kernel CI 固定依赖

本仓库制作和托管 Luna Kernel 的固定 CI 依赖、官方来源审计工具与来源元数据。归档由固定 AOSP/Linux 输入组装，日常构建通过主项目的 v1 内容协议校验和消费。

## 制作与审计

在 Linux 上准备 Bash、Git、Python 3.12+、curl、zstd 和常用 GNU 工具。主项目输入使用固定提交的 LF 检出；`.env`、回移清单和项目适配补丁必须匹配该提交。制作代码从该输入引用 `tools/ci_dependencies.py` 的 v1 协议、`patches/backport_manifest.sh` 的纯函数库与 `tools/tree_sha256.py`。

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

回移 Release：`ci-deps-v1-916353e`，制作输入为主项目固定提交 [`916353e9b3417be4a3315c67c9bf07d31bd9b023`](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/tree/916353e9b3417be4a3315c67c9bf07d31bd9b023)，制作代码为本仓库 `2dd1eecf3cd235893241cf3761af47af71283f71`。工具链继续使用 `ci-deps-v1-3fc59ff`。现有 Release 的 manifest、provenance 和摘要保留原始身份。使用精确版本 URL。

| 文件 | SHA-256 |
| --- | --- |
| `backports.tar.gz` | `08e25cfc25576525403c651d44b26ee56301b033b62efd08aed9a7a33725e7d0` |
| `backports-manifest.json` | `7939ffa626f49bb693f650cbab03314c562536d3aeefce05ac694e15fb4f5074` |
| `toolchain.tar.zst` | `65e911abbba148cac0d81f2678f1a4282da513f8f7004e8cc263bdaccc573fe6` |

工具链安装树 SHA-256：`9ac803933946fd3dff326f8da8853fc5b23ae7da613f6ceb611d8cc5587bf985`。归档与安装树分别校验。

补丁包保存实际补丁、逐文件摘要、许可证、官方来源、提交关系与制作身份。工具链包保存安装目录和 `provenance.json`。

主项目以受版本控制的摘要接受依赖，并执行内容、工具身份、补丁应用与构建检查。更新依赖时重新审计固定官方输入，在干净环境复核后发布新版本，保留既有版本。

## AK3 模板与固定 OTA 输入

`build-inputs-v1-d082477` 的迁移来源为主项目提交 [`d082477a5979db3d7504c4599df2851d21a1a453`](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/tree/d082477a5979db3d7504c4599df2851d21a1a453)。`ak3_template/` 的 9 个文件按该提交的 Git blob 原字节迁入，保留 `LICENSE`、`SOURCE.md` 与 `luna.patch`。AnyKernel3 脚本上游为 [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)，固定提交 `41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1`；arm64 工具来源另见模板的 `SOURCE.md`。

在 Linux 上从本仓库的 LF 源码检出重建模板包，仅需 Python 3 标准库，无需主仓、网络或预制刷机 ZIP：

```bash
mkdir -p output
mkdir output/build-inputs-v1-d082477
python3 -I tools/pack_ak3.py --output output/build-inputs-v1-d082477/ak3-template.tar.gz
```

归档仅含 `ak3_template/` 源码目录，文件权限固定为 `0644`、目录为 `0755`，tar 使用 USTAR、uid/gid/mtime 为 0、用户名和组名为空；gzip 文件名为空、mtime 为 0、压缩级别为 6。制作入口拒绝覆盖已有文件。BusyBox、MagiskBoot 和 Image 不包含在模板包内，仍由主项目校验并组装。

| 资产 | 字节数 | SHA-256 |
| --- | --- | --- |
| `ak3-template.tar.gz` | 20429 | `cd9eca87e005b67f73f8a6fb196baa29626fe314ffc719a35414eaa731692317` |
| `system_dlkm-os4.0.6.0.img` | 17281024 | `7775538c8ff97ebdcb6958d0ce9c9f8eca67ae8d7e8867b45ce5dd701bba5af0` |

完整 `ak3_template/` 树按主项目 `tools/tree_sha256.py` 格式、实际 Linux `0644` 文件计算的 SHA-256 为 `d5b9b8ae6d557a6ce7df7e614381a170d7179764b441c6993ca7decefc40c7be`。主项目继续独立固定并校验归档、目录与镜像摘要。

OTA 资产直接复制自上述主项目提交的 `ci/inputs/os4.0.6.0/system_dlkm.img`（Git blob `3c9ee19348b6819718f7ff6c8e6f493a2818909a`），大小与 SHA-256 匹配该提交的公开 `.env`。主项目将其记录为小米 17 `pudding` 的 `OS4.0.6.0.XPCCNXM` 同包分区镜像。镜像按原字节作为项目兼容性验证资产托管，版权与许可证归原权利人；文件置于忽略的 `output/` 目录作为 Release 资产，不进入依赖 Git 或刷机包。AnyKernel3 的许可原文保留在 `ak3_template/LICENSE`。既有工具链与回移 v1 资产及摘要保持不变。

## 上游声明与源码定位

本仓库制作与审计脚本采用 [GPL-2.0-only](LICENSE)，上游组件保留各自许可证。

`upstream-notices/` 与同名 Release 归档保存预编译仓库的固定源码 manifest，以及 bindgen、bc、e2fsprogs、dwarves、SWIG、musl 和 erofs-utils 的许可证与版权声明。`SOURCES.json` 记录固定 URL、SHA-256 和源码提交；Clang/Rust 原有声明保留在工具链包中。

源码 manifest 记录上游制作环境。bc 的 AOSP 源码提交在 v1 制作时返回 HTTP 404，其许可证取自另行固定提交的官方 `gavinhoward/bc` 仓库，具体来源记录在 `SOURCES.json`。
