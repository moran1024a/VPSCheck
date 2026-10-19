# bin/

VPSCheck 网络信息模块的 NAT 检测使用 [stuntman](https://github.com/jselbie/stunserver) 的 `stunclient`。主流发行版仓库中已没有该软件包，所以这里提供静态编译的二进制。`check.sh` 在本机没有 `stunclient` 时，会按 CPU 架构下载对应文件到临时目录，校验 sha256 后运行，检测结束随临时目录删除，不安装到系统。

| 文件 | 架构 | sha256 |
|---|---|---|
| `stunclient_linux_amd64` | x86_64 | `ab8b8d98840217eadb8f2cf02e2ef4f749c8e71bc90f0df6d66d6a2941715cb3` |
| `stunclient_linux_arm64` | aarch64 | `2867b077184b269691ba8114332baa400622419cabd623bdcc0a295098cfd10f` |

## 来源

- 源码：jselbie/stunserver，提交 [`1582042`](https://github.com/jselbie/stunserver/commit/1582042ca33f747f88101fbadec4944714aa8bbb)（master，2026-02-13，1.2.16 之后）。最后一个标签 `version1.2.13` 只支持 OpenSSL 1.0，无法编译。
- 编译：GitHub Actions 工作流 [`build-stunclient.yml`](../.github/workflows/build-stunclient.yml)，amd64 与 arm64 分别在原生 runner 上，于固定版本的 Alpine 3.22 容器中运行 [`build-stunclient.sh`](build-stunclient.sh)，musl + 静态链接 OpenSSL，`-static -s`。
- 本次产物来自工作流运行 [39266650289](https://github.com/moran1024a/VPSCheck/actions/runs/39266650289)。

## 重新编译

在仓库的 Actions 页面手动运行 `build-stunclient`，或在本地：

```bash
docker run --rm -v "$PWD:/work" -w /work alpine:3.22 sh bin/build-stunclient.sh
```

产物位于 `dist/`。更新二进制时，需同步修改 `check.sh` 中的 `NET_STUNCLIENT_SHA256` 与本文件的校验值。

## 许可

stuntman 以 Apache License 2.0 发布，许可全文见 [`LICENSE.stuntman`](LICENSE.stuntman)。本目录的二进制未修改其源码。
