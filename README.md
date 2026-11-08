# Luna Kernel CI 固定依赖

本仓库托管 Luna Kernel 的固定 CI 依赖与来源元数据。归档是项目从固定官方输入制作的重打包结果，不是 AOSP 或 Linux 官方发布的预编译资产。

制作与校验代码位于主项目固定提交 [`3fc59ff33c4748298462b1db44c4e4ffd6cc4508`](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/tree/3fc59ff33c4748298462b1db44c4e4ffd6cc4508)：

- [统一制作入口](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/blob/3fc59ff33c4748298462b1db44c4e4ffd6cc4508/tools/prepare_ci_dependencies.sh)
- [归档制作、清单与内容校验](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/blob/3fc59ff33c4748298462b1db44c4e4ffd6cc4508/tools/ci_dependencies.py)
- [构建与依赖更新说明](https://github.com/LunaKernel/android_kernel_xiaomi_sm8850/blob/3fc59ff33c4748298462b1db44c4e4ffd6cc4508/docs/BUILDING.md)

## 固定版本

Release：`ci-deps-v1-3fc59ff`。使用精确版本 URL，禁止通过 `latest` 选择依赖。

| 文件 | SHA-256 |
| --- | --- |
| `backports.tar.gz` | `8e0d882f36a730766861a274d15d7243a4609f6634f46d88a86c4a62b2e2515e` |
| `backports-manifest.json` | `cb9baf8d9e35b99f59fc9a8c7af5f150597f5b49f082d25e4cd2629b644b34f4` |
| `toolchain.tar.zst` | `65e911abbba148cac0d81f2678f1a4282da513f8f7004e8cc263bdaccc573fe6` |

工具链安装树 SHA-256：`9ac803933946fd3dff326f8da8853fc5b23ae7da613f6ceb611d8cc5587bf985`。归档身份与安装树身份分别验证，不可互相替代。

补丁包保存实际补丁、逐文件摘要、许可证、官方仓库及提交来源、父提交、日期、提交消息、修改路径和制作脚本身份。工具链包保存安装目录与 `provenance.json`，记录固定 AOSP 来源和制作脚本身份。

消费方必须以主项目受控提交接受的摘要为信任依据；本仓库的校验和便于核对，不能独立建立首次来源信任。每次构建仍须校验实际内容、工具身份、补丁应用及重放，并完成原有源码、配置、ABI/KMI、模块闭包和交付检查。

更新依赖时，从固定官方来源重新准备并完成来源审计，在干净环境复核后发布新的版本与摘要。已有版本不覆盖，不以缓存命中或审计通过标记替代内容验证。

## 上游声明与源码定位

`upstream-notices/` 与同名 Release 归档保留预编译仓库根目录的固定源码 manifest，以及 bindgen、bc、e2fsprogs、dwarves、SWIG、musl 和 erofs-utils 的上游许可证与版权声明。`SOURCES.json` 记录取得文件的固定 URL、SHA-256 和源码项目提交；Clang/Rust 原有声明仍保留在工具链 payload 中。各组件按各自的上游条款分发，本仓库不以统一许可证替代这些条款。

源码 manifest 记录的是上游制作环境，不能把每个条目都视为本包交付的组件。bc 的 AOSP 源码提交在本次发布时返回 HTTP 404；相应限制记录在 `SOURCES.json`，其许可证正文取自另行固定提交的官方 `gavinhoward/bc` 仓库，不把该提交冒称为 AOSP 二进制的源码身份。
