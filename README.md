# VPSCheck

一个入口、统一排版的 VPS 检测脚本，覆盖三类检测：

- **网络信息**：BGP、上游与接入、NAT 类型
- **IP 质量**：基础信息、IP 类型、风险评分、风险因子、流媒体及 AI 解锁、邮局连通性、DNS 黑名单
- **TCP 回程**：三网回程、三网大包回程、教育网回程（线路类型 / 延迟 / 丢包）

脚本只在本机输出结果，**不上传任何检测结果、不做云端留档、不统计运行次数**，也不包含任何测速功能。

> 当前版本 v0.1.0：网络信息、NAT 与 IP 质量已在真实环境验证；TCP 回程尚未在真实 VPS 上完整验证。

## 快速开始

```bash
# 一行运行（交互菜单）
bash <(curl -fsSL https://raw.githubusercontent.com/moran1024a/VPSCheck/main/check.sh)

# 全部检测，缺依赖时自动安装
bash <(curl -fsSL https://raw.githubusercontent.com/moran1024a/VPSCheck/main/check.sh) -A -y
```

也可以下载后运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/moran1024a/VPSCheck/main/check.sh
bash check.sh
```

下文示例中的 `bash check.sh` 均可替换为一行运行的写法。

交互菜单：

```
  1. 全部检测
  2. 网络信息      BGP / 上游 / NAT
  3. IP 质量       基础信息 / 风险 / 解锁 / 邮局 / 黑名单
  4. 所有回程      三网 + 大包 + 教育网           (需 root)
  5. 三网回程      线路类型 / 丢包 / 延迟        (需 root)
  6. 大包回程      大包预检 / 丢包 / 线路         (需 root)
  7. 教育网回程    CERNET / CERNET2              (需 root)
  0. 退出
```

可多选，空格分隔（如 `2 3 5`）。本机同时有 IPv4 和 IPv6 时，会再询问测双栈还是单栈。

## 参数

| 参数 | 说明 |
|---|---|
| `-A` | 全部检测 |
| `-N` | 网络信息 |
| `-I` | IP 质量 |
| `-T` | 所有回程（三网 + 大包 + 教育网） |
| `-R` | 三网回程 |
| `-L` | 大包回程（仅 IPv4） |
| `-E` | 教育网回程（CERNET / CERNET2） |
| `-4` / `-6` | 只测 IPv4 / IPv6 |
| `-c NUM` | 回程每节点发包数（1-600） |
| `--province CODE` | 回程只测指定省份，可重复，如 `--province bj --province gd` 或 `--province 北京` |
| `-o FILE` | 报告另存为纯文本（去掉颜色） |
| `-y` | 缺少依赖时自动安装，不询问 |
| `-h` | 帮助 |

检测项目参数可组合，例如 `bash check.sh -N -I -4`。不带任何检测项目参数时，先获取公网 IP，然后在终端中显示菜单；非终端环境打印帮助后退出。

示例：

```bash
bash check.sh -I                         # 只看 IP 质量
bash check.sh -T -c 50                   # 所有回程，每节点 50 个包
bash check.sh -R --province bj --province sh   # 只测北京、上海三网回程
bash check.sh -A -o report.txt           # 全部检测并保存报告
```

## 检测内容

### 网络信息

| 项目 | 内容 | 数据来源 |
|---|---|---|
| BGP 信息 | 前缀、ASN 与名称、组织、注册机构、国家/地区、地址、注册与修改日期、RPKI 状态 | RIPEstat（主），bgp.tools / bgp.he.net（兜底） |
| 上游与接入 | 上游 / 对等 / 下游数量、主要上游、IX 数量、机房数 | RIPEstat、PeeringDB，bgp.tools（兜底） |
| NAT 类型 | NAT1–4 编号与名称（开放 / 防火墙 / 全锥形 / 受限锥形 / 端口受限锥形 / 对称型 / UDP 阻断）、映射与过滤行为、公网映射地址、端口保持 | `stunclient`（RFC 5780），仅 IPv4 |

说明：

- RIPEstat 某项查询失败或为空时，才用 bgp.tools / bgp.he.net 补该项，报告中会标注兜底来源。RIPEstat 的 whois 对 RIPE / APNIC 地址常常只给组织句柄，所以组织名和地址经常由 he.net 补上；bgp.tools 目前对脚本请求返回人机验证页，遇到时会提示并跳过。
- 上游 / 对等 / 下游数量由 RIPE RIS 的 AS 路径相邻关系推断：只在左侧出现且路径数达到最强邻居 10% 记为上游，双向出现或仅 RIS 直连可见记为对等，只在右侧出现记为下游；公认 Tier-1 视为 Transit-Free。大型内容网络（如 Cloudflare、Google）的对等常被计为上游，数字仅供参考。
- NAT 依次尝试 STUN 服务器 `stun.voipgate.com`、`stun.easybell.de`（均支持 RFC 5780 行为测试）。`stunclient` 不测 hairpin，所以不显示该项。
- `stunclient` 来自 [stuntman](https://github.com/jselbie/stunserver)。主流发行版仓库中已没有该软件包，本机没有时自动从本仓库 [`bin/`](bin/) 下载静态编译版本（amd64 / arm64）到临时目录，校验 sha256 后运行，不安装到系统。

### IP 质量

移植自 [xykt/IPQuality](https://github.com/xykt/IPQuality)，保留其完整模式的全部检测：

| 项目 | 内容 |
|---|---|
| 基础信息 | ASN、组织、位置、坐标、时区、注册地、原生 / 广播 IP 判断（Maxmind + IPinfo） |
| IP 类型 | 使用类型与公司类型（IPinfo / ipregistry / ipapi / IP2Location / AbuseIPDB） |
| 风险评分 | IP2Location / Scamalytics / ipapi / AbuseIPDB / IPQS / DB-IP |
| 风险因子 | 8 个数据库的地区、代理、Tor、VPN、服务器、滥用、机器人判断 |
| 流媒体及 AI 解锁 | TikTok、Disney+、Netflix、YouTube Premium、Prime Video、Reddit、ChatGPT，含地区与原生 / DNS 解锁 |
| 邮局连通性 | 本机 25 端口，以及 Gmail、Outlook、Yahoo、Apple、QQ、Mail.ru、AOL、GMX、Mail.com、163、搜狐、新浪 |
| DNS 黑名单 | 400+ 个 DNSBL（仅 IPv4） |

### TCP 回程（需要 root）

移植自 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)：

| 项目 | 内容 |
|---|---|
| 三网回程 | 31 省 × 电信/联通/移动，nping 发 TCP SYN 测延迟与丢包，traceroute 识别回程线路（CN2GIA / CN2GT / CTGGIA / 163 / 4837 / 9929 / 10099 / CMIN2 / CMI 等），IPv4 与 IPv6 |
| 大包回程 | 先做大包预检（识别服务商防火墙限制），再用大包测延迟与丢包，nexttrace-tiny 识别大包回程线路，仅 IPv4 |
| 教育网回程 | 各省 CERNET（IPv4）/ CERNET2（IPv6）节点的延迟、丢包与进入教育网前的骨干网 |

执行顺序与原脚本一致：先识别回程线路（traceroute / nexttrace-tiny），再做大包预检，最后统一发包测延迟与丢包，避免探测流量干扰路由识别。选择「所有回程」时三项共用一次节点加载和一次进度显示。

说明：

- 默认每节点 25 个包，`-c` 可调；并行数按可用内存自动决定。
- 线路标签超过 10 列时，`->` 会缩写为 `>`（如 `10099>9929`）。
- 节点优先从 getNodes 实时获取；服务暂无 IP 的节点会跳过并提示。获取失败时使用脚本内置的节点快照（2026-10-19），CDN 节点 IP 会轮换，快照会逐渐过时。
- 教育网线路标签只依据 Team Cymru 的 ASN 归属。原脚本还会把路由跳点 IP 提交给作者服务器查询，本脚本已去掉这一步，个别标签可能与原脚本不同。
- 没有 traceroute 或 nexttrace-tiny 时仍会测延迟与丢包，线路显示「未识别」。

## 运行要求

- Linux，bash 4.0 及以上，curl
- 回程检测需要 root（nping 发裸 TCP SYN）；非 root 运行时回程项目会跳过，其余照常
- 依赖按所选项目检查，缺失时列出安装命令，同意（或加 `-y`）后用系统包管理器安装：

| 检测项目 | 依赖 |
|---|---|
| 网络信息 | curl、jq；NAT 检测自动下载 `stunclient`（需要 sha256sum） |
| IP 质量 | curl、jq、dig、nslookup、nc、timeout |
| TCP 回程 | curl、nping（nmap）、traceroute、timeout；大包回程线路识别需要 `nexttrace-tiny`（从 [NTrace-core](https://github.com/nxtrace/NTrace-core) 最新 Release 下载，按 Release 记录的 sha256 校验通过后安装到 `/usr/local/bin`） |

可选依赖缺失时只跳过对应小项（如没有 nexttrace-tiny 只是大包回程不识别线路）。安装提示只在终端中出现，直接回车或输入 y 才安装；非交互运行时不安装（除非加 `-y`）。

## 隐私与外部请求

脚本只做查询，不提交检测结果。运行时会访问：

- 公网 IP 获取：ipify / ip.sb / ifconfig.co / icanhazip.com / ipinfo.io
- 网络信息：stat.ripe.net（请求带 `sourceapp=vpscheck` 标识）、peeringdb.com、STUN 服务器、本仓库的 raw 地址（下载 stunclient）；兜底时 bgp.tools、bgp.he.net
- IP 质量：IPQuality 作者的数据代理 `ipinfo.check.place`（Maxmind 与多个风险库经它查询）、ipinfo.io、ipregistry.co、db-ip.com、各流媒体 / AI 平台、各邮局 MX；参考数据（ISO 3166、DNSBL 列表）从 IPQuality 的 GitHub 仓库下载
- TCP 回程：TcpQuality 作者的节点服务 `tcpquality.ibsgss.uk/getNodes`（失败时使用脚本内置的节点快照）、Team Cymru ASN 查询（whois.cymru.com）、各探测节点
- 依赖安装：系统包管理器源；nexttrace-tiny 来自 api.github.com 与 github.com

## 文件结构

```
check.sh                                  检测脚本（单文件）
bin/stunclient_linux_{amd64,arm64}        NAT 检测用的 stunclient 静态二进制
bin/build-stunclient.sh, bin/README.md    编译脚本与来源说明
.github/workflows/build-stunclient.yml    编译 stunclient 的工作流（手动触发）
```

`check.sh` 按区块组织：

```
公共层        颜色、排版（80 列，中文宽度自适应）、依赖管理、公网 IP 获取
网络信息模块  net_run 4|6
IP 质量模块   ip_run 4|6
TCP 回程模块  tcp_run
菜单与参数    show_menu / parse_args
主流程        run_checks / main
```

被 `source` 时只加载函数、不执行，便于单独调试某个模块：

```bash
source check.sh; setup_colors; WORKDIR=$(mktemp -d); detect_public_ips
ip_run 4
```

## 相对原项目的修改

本脚本包含移植自以下项目的代码，均有修改（2026-10）：

**[xykt/IPQuality](https://github.com/xykt/IPQuality)（IP 质量模块）**

- 删除：报告上传（upload.check.place）、运行次数统计、广告、JSON 输出、多语言（只保留中文）、IP 打码、代理 / 网卡参数、精简模式、交互菜单与依赖安装（由公共层统一处理）
- DB-IP、TikTok、ChatGPT 的请求按 IPv4 / IPv6 分别发出，避免 IPv6 报告显示 IPv4 的数据
- 邮局检测改用 `nc -4/-6`，不再用 `-s 公网IP` 绑定源地址（NAT 机器上会失败）；绑定本地 25 端口仅在 root 时进行；12 家邮局并行检测
- 本地 25 端口「占用」只看本地端口为 25 的连接，不再把刚结束的出站连接误判为占用
- DNS 黑名单查询超时单独统计，不再计入「已标记」
- 查询失败的评分显示为 `-`，不再按 0 分（低风险）处理
- 重新排版为统一的 80 列格式

**[ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)（TCP 回程模块）**

- 只保留三网回程、大包回程、教育网回程，探测与线路识别逻辑保持原样
- 删除：单线程测速、Apple CDN / TOS 测速、iPerf3、国际互联、bpftrace / TCP_INFO 重传统计、报告上传与排行榜、调试包上传、把路由跳点 IP 提交给作者服务器的 ASN 查询、rootfs / chroot 与 NixOS 运行环境、参数解析
- 节点按所选项目分组获取，失败时使用内置节点快照
- 缺少 traceroute / nexttrace-tiny 时仍测延迟与丢包，线路显示「未识别」
- nexttrace-tiny 下载后按 Release 记录的 sha256 校验
- 重新排版为统一的 80 列格式

**[xykt/NetQuality](https://github.com/xykt/NetQuality)（BGP 兜底解析）**

- 仅在 RIPEstat 查询失败或字段为空时按字段兜底使用
- 修正上游数量把 IRR 表也计入的问题
- 未移植网段活跃度（依赖 ImageMagick）

网络信息模块的 RIPEstat / PeeringDB 查询与 NAT 判定、公共层、菜单与主流程为本项目新写。

## 许可证

本项目以 [GNU Affero General Public License v3.0](LICENSE)（AGPL-3.0-only）发布。

- IP 质量模块与 BGP 兜底解析移植自 xykt/IPQuality、xykt/NetQuality（AGPL-3.0），版权归原作者所有
- TCP 回程模块移植自 ibsgss/TcpQuality（GPL-3.0-only），版权归原作者所有，依 GPL-3.0 第 13 条与本程序合并分发
- `bin/` 下的 stunclient 由 [stuntman](https://github.com/jselbie/stunserver) 源码编译，以 Apache-2.0 发布（见 [`bin/LICENSE.stuntman`](bin/LICENSE.stuntman)）
- 运行时从其他来源下载的程序（nexttrace-tiny）不随本项目分发，遵循其各自许可证

## 致谢

- [xykt/IPQuality](https://github.com/xykt/IPQuality)、[xykt/NetQuality](https://github.com/xykt/NetQuality)、[ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)
- 回程探测节点来自 [Zstatic CDN](https://www.zstaticcdn.com)，节点服务由 TcpQuality 提供
- BGP 数据：[RIPEstat](https://stat.ripe.net)、[PeeringDB](https://www.peeringdb.com)；ASN 查询：[Team Cymru](https://www.team-cymru.com)
- NAT 检测：[stuntman](https://github.com/jselbie/stunserver)
