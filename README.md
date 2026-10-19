# VPSCheck

一个入口、统一排版的 VPS 检测脚本：

- **网络信息**：BGP、上游与接入、NAT 类型
- **IP 质量**：基础信息、IP 类型、风险评分、风险因子、流媒体及 AI 解锁、邮局连通性、DNS 黑名单
- **TCP 回程**：三网回程、大包回程、教育网回程（线路类型 / 延迟 / 丢包）

只在本机输出结果：**不上传检测结果、不做云端留档、不统计运行次数**，也不含任何测速。

> v0.1.0：全部检测已在真实 VPS（Ubuntu 22.04，1 核 / 454MB，仅 IPv4）上验证；IPv6 回程与 CERNET2 尚未在真实环境验证。全部回程在该机器上约 16 分钟。

## 使用

交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moran1024a/VPSCheck/main/check.sh)
```

全部检测，缺依赖时自动安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moran1024a/VPSCheck/main/check.sh) -A -y
```

不带检测项目参数时显示菜单（可多选，如 `2 3 5`；双栈机器会再问测哪个协议）：

```
1. 全部检测   2. 网络信息   3. IP 质量   4. 所有回程
5. 三网回程   6. 大包回程   7. 教育网回程   0. 退出      （4-7 需 root）
```

| 参数 | 说明 |
|---|---|
| `-A` / `-N` / `-I` | 全部 / 网络信息 / IP 质量 |
| `-T` / `-R` / `-L` / `-E` | 所有回程 / 三网回程 / 大包回程（仅 IPv4）/ 教育网回程 |
| `-4` / `-6` | 只测 IPv4 / IPv6 |
| `-c NUM` | 回程每节点发包数（1-600，默认 25） |
| `--province CODE` | 回程只测指定省份，可重复（`bj`、`gd` 或 `北京`） |
| `-o FILE` | 报告另存为纯文本 |
| `-y` | 缺依赖时自动安装，不询问 |

检测项目参数可组合，如 `-N -I -4`、`-R --province bj --province sh`。

## 检测内容

### 网络信息

| 项目 | 内容 | 来源 |
|---|---|---|
| BGP | 前缀、ASN、组织、注册机构、国家、地址、注册 / 修改日期、RPKI | RIPEstat，字段缺失时用 bgp.he.net / bgp.tools 补并标注 |
| 上游与接入 | 上游 / 对等 / 下游数量、主要上游、IX 与机房数 | RIPEstat、PeeringDB |
| NAT（仅 IPv4） | NAT1–4 与名称（开放 / 防火墙 / 全锥 / 受限锥 / 端口受限锥 / 对称 / UDP 阻断）、映射与过滤行为、公网映射地址、端口保持 | stunclient（RFC 5780） |

- 上游 / 对等 / 下游由 RIPE RIS 的 AS 路径相邻关系推断，大型内容网络（如 Cloudflare）的对等常被计为上游，仅供参考。bgp.tools 目前对脚本返回人机验证页，兜底基本依赖 he.net。
- NAT 使用 [stuntman](https://github.com/jselbie/stunserver) 的 stunclient（发行版仓库中已没有）。本机没有时，从本仓库 [`bin/`](bin/) 下载静态编译版（amd64 / arm64）到临时目录，校验写死的 sha256 后运行，不安装到系统。STUN 服务器：`stun.voipgate.com`、`stun.easybell.de`。不测 hairpin。

### IP 质量

移植自 [xykt/IPQuality](https://github.com/xykt/IPQuality) 完整模式：

| 项目 | 内容 |
|---|---|
| 基础信息 | ASN、组织、位置、坐标、时区、注册地、原生 / 广播 IP（Maxmind + IPinfo） |
| IP 类型 | IPinfo / ipregistry / ipapi / IP2Location / AbuseIPDB |
| 风险评分 | IP2Location / Scamalytics / ipapi / AbuseIPDB / IPQS / DB-IP |
| 风险因子 | 8 个库的地区、代理、Tor、VPN、服务器、滥用、机器人 |
| 解锁 | TikTok、Disney+、Netflix、YouTube Premium、Prime Video、Reddit、ChatGPT（地区、原生 / DNS） |
| 邮局 | 本机 25 端口，及 Gmail、Outlook、Yahoo、Apple、QQ、Mail.ru、AOL、GMX、Mail.com、163、搜狐、新浪 |
| DNS 黑名单 | 400+ 个 DNSBL（仅 IPv4） |

### TCP 回程（需 root）

移植自 [ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)，每格给出线路类型、延迟、丢包：

| 项目 | 内容 |
|---|---|
| 三网回程 | 31 省 × 电信 / 联通 / 移动，IPv4 与 IPv6；nping 发 TCP SYN，traceroute 识别线路（CN2GIA / CN2GT / CTGGIA / 163 / 4837 / 9929 / 10099 / CMIN2 / CMI 等） |
| 大包回程 | 大包预检（识别服务商防火墙限制）后用大包探测，nexttrace-tiny 识别线路；仅 IPv4 |
| 教育网回程 | 各省 CERNET（IPv4）/ CERNET2（IPv6），及进入教育网前的骨干网 |

- 先识别线路、再统一发包，避免探测流量干扰路由识别；并行数按内存自动决定。
- 节点从 TcpQuality 的 getNodes 服务实时获取，失败时用内置快照（2026-10-19，会随节点轮换逐渐过时）。
- 缺 traceroute / nexttrace-tiny 时仍测延迟与丢包，线路显示「未识别」。超过 10 列的线路标签把 `->` 缩写为 `>`。

## 运行要求

Linux、bash 4+、curl。回程需要 root，非 root 时跳过回程、其余照常。

| 检测项目 | 依赖 |
|---|---|
| 网络信息 | curl、jq；NAT 另需 sha256sum（stunclient 自动下载） |
| IP 质量 | curl、jq、dig、nslookup、nc、timeout |
| TCP 回程 | curl、nping（nmap）、traceroute、timeout；可选 nexttrace-tiny（从 [NTrace-core](https://github.com/nxtrace/NTrace-core) Release 下载，sha256 校验后装到 `/usr/local/bin`） |

缺依赖时列出安装命令；终端中回车或输入 `y` 才安装，非交互运行只在加 `-y` 时安装。

## 外部请求

只做查询，不提交检测结果。会访问：

- 公网 IP：ipify、ip.sb、ifconfig.co、icanhazip.com、ipinfo.io
- 网络信息：stat.ripe.net（带 `sourceapp=vpscheck`）、peeringdb.com、STUN 服务器、本仓库 raw 地址；兜底时 bgp.tools、bgp.he.net
- IP 质量：IPQuality 作者的数据代理 `ipinfo.check.place`（Maxmind 与多个风险库）、ipinfo.io、ipregistry.co、db-ip.com、各流媒体 / AI 平台、各邮局 MX、IPQuality 的 GitHub 仓库（参考数据）
- TCP 回程：`tcpquality.ibsgss.uk/getNodes`、whois.cymru.com、各探测节点
- 依赖安装：系统软件源、api.github.com / github.com（nexttrace-tiny）

## 文件结构

```
check.sh                                单文件脚本：公共层 / 网络信息 net_run / IP 质量 ip_run / TCP 回程 tcp_run / 菜单与主流程
bin/                                    stunclient 静态二进制、编译脚本与来源说明（见 bin/README.md）
.github/workflows/build-stunclient.yml  编译 stunclient（手动触发，只产出构建产物）
```

`source check.sh` 只加载函数不执行，可单独调试模块：`source check.sh; setup_colors; WORKDIR=$(mktemp -d); detect_public_ips; ip_run 4`。

## 相对原项目的修改

以下代码移植自原项目并有修改（2026-10）：

- **[xykt/IPQuality](https://github.com/xykt/IPQuality)**（IP 质量）
  - 删除报告上传、运行统计、广告、JSON、多语言、IP 打码、代理 / 网卡参数、精简模式、菜单与依赖安装
  - DB-IP、TikTok、ChatGPT 请求区分 IPv4 / IPv6；邮局检测改用 `nc -4/-6` 并行检测，仅 root 时绑定本地 25 端口；25 端口「占用」不再误判出站连接
  - DNS 黑名单超时单独统计，不计入「已标记」；查询失败的评分显示 `-`，不按低风险处理
- **[ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)**（TCP 回程）
  - 只保留三网 / 大包 / 教育网回程，探测与线路识别逻辑不变
  - 删除测速（单线程、Apple CDN、TOS、iPerf3）、国际互联、bpftrace / TCP_INFO 重传统计、报告上传与排行榜、调试包上传、向作者服务器提交路由跳点 IP 的 ASN 查询、rootfs / NixOS 环境
  - 增加内置节点快照兜底、缺工具时降级运行、nexttrace-tiny 的 sha256 校验
- **[xykt/NetQuality](https://github.com/xykt/NetQuality)**（BGP 兜底解析）：仅按字段兜底使用；修正上游数量误计 IRR 表；未移植网段活跃度

以上部分均重新排版为统一的 80 列格式。RIPEstat / PeeringDB 查询、NAT 判定、公共层、菜单与主流程为本项目新写。

## 许可证

[AGPL-3.0-only](LICENSE)。

- IP 质量与 BGP 兜底解析来自 xykt/IPQuality、xykt/NetQuality（AGPL-3.0），TCP 回程来自 ibsgss/TcpQuality（GPL-3.0-only，依其第 13 条合并分发），版权归原作者所有
- `bin/` 下的 stunclient 由 stuntman 源码编译，Apache-2.0（[`bin/LICENSE.stuntman`](bin/LICENSE.stuntman)）
- nexttrace-tiny 运行时另行下载，不随本项目分发

## 致谢

[xykt/IPQuality](https://github.com/xykt/IPQuality)、[xykt/NetQuality](https://github.com/xykt/NetQuality)、[ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)、[Zstatic CDN](https://www.zstaticcdn.com)（回程节点）、[RIPEstat](https://stat.ripe.net)、[PeeringDB](https://www.peeringdb.com)、[Team Cymru](https://www.team-cymru.com)、[stuntman](https://github.com/jselbie/stunserver)
