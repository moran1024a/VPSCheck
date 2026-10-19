#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# VPSCheck - VPS 检测脚本
#   网络信息（BGP / 上游 / NAT）、IP 质量、TCP 回程（三网 / 大包 / 教育网）
#   只在本机输出结果，不上传任何检测数据。
#
# Copyright (C) 2026 moran1024a
#
# 本脚本包含移植自以下项目的代码（均有修改，修改内容见 README「相对原项目的修改」）：
#   - IP 质量模块：xykt/IPQuality  https://github.com/xykt/IPQuality  （AGPL-3.0）
#   - BGP 兜底解析：xykt/NetQuality https://github.com/xykt/NetQuality （AGPL-3.0）
#   - TCP 回程模块：ibsgss/TcpQuality https://github.com/ibsgss/TcpQuality （GPL-3.0-only）
#   上述部分的版权归原作者所有；TcpQuality 来源部分依 GPL-3.0 第 13 条与本程序合并分发。
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.
#

VERSION="0.1.0"

if [ -z "${BASH_VERSINFO[0]}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "VPSCheck 需要 bash 4.0 及以上版本" >&2
  exit 1
fi

# 统一使用 UTF-8 + 英文工具输出，保证中文宽度计算和命令输出解析一致
for _loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qx "$_loc"; then
    export LC_ALL="$_loc"
    break
  fi
done
unset _loc

# ==================== 全局状态 ====================

UI_W=80
WORKDIR=""
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
SUDO=""
[ "$IS_ROOT" -eq 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

PUB4=""
PUB6=""
HAS_V4=0
HAS_V6=0
RUN_V4=1
RUN_V6=1

# 检测项目开关
DO_NET=0
DO_IP=0
TCP_ROUTE=0
TCP_LARGE=0
TCP_EDU=0

# 参数
OPT_COUNT=""
OPT_PROVINCES=()
OPT_OUTPUT=""
OPT_YES=0
OPT_ONLY4=0
OPT_ONLY6=0

UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

# ==================== 颜色 ====================

setup_colors() {
  if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
    C_M=$'\033[35m'; C_C=$'\033[36m'; C_W=$'\033[97m'; C_D=$'\033[2m'
    C_BOLD=$'\033[1m'; C_I=$'\033[3m'; C_0=$'\033[0m'
    BG_R=$'\033[41m'; BG_G=$'\033[42m'; BG_Y=$'\033[43m'; BG_B=$'\033[44m'
  else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_C=""; C_W=""; C_D=""
    C_BOLD=""; C_I=""; C_0=""; BG_R=""; BG_G=""; BG_Y=""; BG_B=""
  fi
}

# ==================== 排版 ====================
# 报告内容一律写 stdout，进度提示写 stderr（不进入 -o 保存的报告）。

shopt -s extglob

# 去掉 ANSI 颜色序列
ui_strip() {
  printf '%s' "${1//$'\033'\[*([0-9;])m/}"
}

# 显示宽度：ASCII 与 2 字节字符（é 等）记 1，3/4 字节字符（中文等）记 2
ui_width() {
  local s="${1//$'\033'\[*([0-9;])m/}" chars i c w=0
  chars=${#s}
  if [ "$(LC_ALL=C; echo "${#s}")" -eq "$chars" ]; then
    echo "$chars"
    return
  fi
  for (( i = 0; i < chars; i++ )); do
    c="${s:i:1}"
    if [ "$(LC_ALL=C; echo "${#c}")" -ge 3 ]; then w=$((w + 2)); else w=$((w + 1)); fi
  done
  echo "$w"
}

# ui_pad 文本 宽度 [l|r|c]：按显示宽度补空格，超长不截断
ui_pad() {
  local text="$1" width="$2" align="${3:-l}" w pad left
  w=$(ui_width "$text")
  pad=$(( width - w ))
  [ "$pad" -lt 0 ] && pad=0
  case "$align" in
    r) printf '%*s%s' "$pad" '' "$text" ;;
    c) left=$(( pad / 2 )); printf '%*s%s%*s' "$left" '' "$text" $(( pad - left )) '' ;;
    *) printf '%s%*s' "$text" "$pad" '' ;;
  esac
}

ui_repeat() {
  local ch="$1" n="$2" out=""
  while [ "$n" -gt 0 ]; do out+="$ch"; n=$((n - 1)); done
  printf '%s' "$out"
}

ui_line() { printf '%s%s%s\n' "$C_D" "$(ui_repeat "${1:--}" "$UI_W")" "$C_0"; }

# 只用 ASCII 画线：━ ▸ · 等字符在「东亚宽度」终端里占两列，会撑破 80 列

# 一级标题：== 网络信息 - IPv4 ==========
ui_section() {
  local title="${1//·/-}" w fill
  w=$(ui_width "$title")
  fill=$(( UI_W - w - 4 ))
  [ "$fill" -lt 3 ] && fill=3
  printf '\n%s%s== %s %s%s\n' "$C_BOLD" "$C_W" "$title" "$(ui_repeat '=' "$fill")" "$C_0"
}

# 二级标题：> 基础信息（青色）。UI_SUB_GAP=0 时前面不空行（IP 质量部分同原版紧凑排列）
UI_SUB_GAP=1
ui_sub() {
  [ "$UI_SUB_GAP" -eq 1 ] && printf '\n'
  printf '%s%s> %s%s\n' "$C_BOLD" "$C_C" "${1//·/-}" "$C_0"
}

# 键值行：  键（青色，定宽）  值
UI_KEY_W=14
ui_kv() {
  printf '  %s%s%s%s\n' "$C_C" "$(ui_pad "$1" "$UI_KEY_W")" "$C_0" "$2"
}

# 无数据：绿色「无」（同 IPQuality 原版）
ui_na() { printf '%s%s无%s' "$C_G" "$C_BOLD" "$C_0"; }

ui_clear() { [ -t 2 ] && printf '\033[H\033[2J' >&2; return 0; }
ui_warn() { printf '  %s[!] %s%s\n' "$C_Y" "$1" "$C_0"; }
ui_err()  { printf '  %s[x] %s%s\n' "$C_R" "$1" "$C_0"; }

# 进度提示（stderr，仅终端）：ui_prog 文本 [已完成 总数]
# 状态写入 $WORKDIR/.prog，由后台进程每 0.2 秒重绘「旋转符号 + 进度条 + 文本」，
# 看得出脚本仍在运行。输出报告前必须 ui_prog_clear，结束后台进程，避免与报告抢同一行。
UI_MAIN_PID=$$

ui_spin_loop() {
  local file="$1" i=0 t chars='|/-\'
  while kill -0 "$UI_MAIN_PID" 2>/dev/null && [ -f "$file" ]; do
    t=$(<"$file")
    printf '\r\033[K  %s%s %s%s' "$C_W" "${chars:i++%4:1}" "$t" "$C_0" >&2
    sleep 0.2
  done
}

ui_prog() {
  [ -t 2 ] || return 0
  local t="$1" pid
  [ -n "${3:-}" ] && t="$(ui_bar "$2" "$3" 20)  $C_D$t"
  if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
    printf '\r\033[K  %s... %s%s' "$C_D" "$t" "$C_0" >&2
    return 0
  fi
  printf '%s' "$t" > "$WORKDIR/.prog"
  pid=$(cat "$WORKDIR/.prog.pid" 2>/dev/null)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    # 只往 stderr 画；断开 stdin/stdout，否则在 $(...) 里启动时会占住管道，外层一直等不到结束
    ui_spin_loop "$WORKDIR/.prog" </dev/null >/dev/null &
    echo $! > "$WORKDIR/.prog.pid"
  fi
}

ui_prog_clear() {
  [ -t 2 ] || return 0
  local pid
  if [ -n "$WORKDIR" ] && [ -f "$WORKDIR/.prog.pid" ]; then
    pid=$(cat "$WORKDIR/.prog.pid" 2>/dev/null)
    rm -f "$WORKDIR/.prog.pid"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      # 后台进程可能不是当前 shell 的子进程，wait 不到时轮询等它退出
      wait "$pid" 2>/dev/null || while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
    fi
  fi
  printf '\r\033[K' >&2
}

# 进度条文本：ui_bar 已完成 总数 [宽度]
ui_bar() {
  local done="$1" total="$2" width="${3:-30}" fill
  [ "$total" -gt 0 ] 2>/dev/null || total=1
  [ "$done" -gt "$total" ] && done="$total"
  fill=$(( done * width / total ))
  printf '[%s%s] %d/%d' "$(ui_repeat '#' "$fill")" "$(ui_repeat '-' $(( width - fill )))" "$done" "$total"
}

# ==================== 通用工具 ====================

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do [ "${BASH_REMATCH[$i]}" -le 255 ] || return 1; done
}

is_ipv6() {
  [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:*:* ]]
}

# 获取公网 IP，结果写入 PUB4/PUB6、HAS_V4/HAS_V6
detect_public_ips() {
  local api ip
  PUB4=""; PUB6=""
  for api in api.ipify.org ip.sb ifconfig.co icanhazip.com ipinfo.io/ip; do
    ip=$(curl -4 -fsL -m 5 -A curl "https://$api" 2>/dev/null | tr -d '[:space:]')
    if is_ipv4 "$ip"; then PUB4="$ip"; break; fi
  done
  for api in api6.ipify.org ip.sb ifconfig.co icanhazip.com; do
    ip=$(curl -6 -fsL -m 5 -A curl "https://$api" 2>/dev/null | tr -d '[:space:]')
    if is_ipv6 "$ip"; then PUB6="$ip"; break; fi
  done
  HAS_V4=0; HAS_V6=0
  [ -n "$PUB4" ] && HAS_V4=1
  [ -n "$PUB6" ] && HAS_V6=1
}

# run_to 秒数 命令…：带超时运行。--foreground 让命令留在本进程组，Ctrl-C 能一起结束
# （默认的 timeout 会另起进程组，中断后命令仍在后台运行）。
# 没有 timeout 或不支持 --foreground（如 BusyBox）时不加超时，依赖命令自身的超时
RUN_TO_FG=0
run_to() {
  local s="$1"
  shift
  if [ "$RUN_TO_FG" -eq 1 ]; then timeout --foreground "$s" "$@"; else "$@"; fi
}

# 秒数格式化为「X 分 Y 秒」
fmt_duration() {
  local s="$1"
  if [ "$s" -ge 60 ]; then printf '%d 分 %d 秒' $((s / 60)) $((s % 60)); else printf '%d 秒' "$s"; fi
}

# ==================== 依赖管理 ====================

# 各项检测所需命令；_OPT 为可选依赖，缺失时只跳过对应小项
DEPS_NET=(curl jq)
DEPS_IP=(curl jq dig nslookup nc)
DEPS_TCP=(curl nping traceroute)
DEPS_LARGE_OPT=(nexttrace-tiny)

pkg_manager() {
  local pm
  for pm in apt-get dnf yum apk pacman; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
}

# 命令 → 软件包名；输出为空表示该系统仓库没有
pkg_name() {
  local cmd="$1" pm="$2"
  case "$cmd" in
    curl|jq|traceroute) echo "$cmd" ;;
    nping)
      case "$pm" in apk) echo nmap-nping ;; *) echo nmap ;; esac ;;
    dig|nslookup)
      case "$pm" in apt-get) echo dnsutils ;; dnf|yum) echo bind-utils ;; apk) echo bind-tools ;; pacman) echo bind ;; esac ;;
    nc)
      case "$pm" in apt-get|apk) echo netcat-openbsd ;; dnf|yum) echo nmap-ncat ;; pacman) echo openbsd-netcat ;; esac ;;
  esac
}

pkg_install() {
  local pm="$1"; shift
  case "$pm" in
    apt-get) $SUDO apt-get update -qq >/dev/null 2>&1; $SUDO apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
    dnf)     $SUDO dnf install -y -q "$@" >/dev/null 2>&1 ;;
    yum)     $SUDO yum install -y -q "$@" >/dev/null 2>&1 ;;
    apk)     $SUDO apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman)  $SUDO pacman -Sy --noconfirm "$@" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# nexttrace-tiny 不在发行版仓库里，从 NTrace-core 官方 Release 下载，
# 校验 Release 中记录的 sha256 并能正常运行后才安装；失败原因写入 NT_ERR
NT_ERR=""
install_nexttrace_tiny() {
  local arch name meta url digest tmp rc
  NT_ERR="下载或校验失败"
  command -v sha256sum >/dev/null 2>&1 || return 1
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l|armv7) arch=armv7 ;;
    armv6l|armv6) arch=armv6 ;;
    *) return 1 ;;
  esac
  name="nexttrace-tiny_linux_${arch}"
  meta=$(curl -fsSL --connect-timeout 15 --max-time 60 \
    https://api.github.com/repos/nxtrace/NTrace-core/releases/latest 2>/dev/null |
    awk -v name="$name" '
      index($0, "\"name\": \"" name "\"") { found = 1 }
      found && index($0, "\"digest\":") { d = $0; sub(/^.*"digest": "sha256:/, "", d); sub(/".*$/, "", d) }
      found && index($0, "\"browser_download_url\":") {
        u = $0; sub(/^.*"browser_download_url": "/, "", u); sub(/".*$/, "", u)
        print d "|" u; exit
      }')
  digest=${meta%%|*}
  url=${meta#*|}
  [ -n "$digest" ] && [ -n "$url" ] || return 1
  tmp=$(mktemp "${WORKDIR:-/tmp}/nexttrace.XXXXXX") || return 1
  if curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$tmp" &&
     [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$digest" ] && chmod 0755 "$tmp"; then
    "$tmp" -V >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      $SUDO install -m 0755 "$tmp" /usr/local/bin/nexttrace-tiny && rm -f "$tmp" && return 0
      NT_ERR="安装到 /usr/local/bin 失败"
    elif [ "$rc" -eq 126 ]; then
      NT_ERR="临时目录不可执行（noexec）"
    else
      NT_ERR="无法运行"
    fi
  fi
  rm -f "$tmp"
  return 1
}

# 列出当前选择的检测项目缺少的命令（必需 + 可选）
missing_commands() {
  local -a need=() out=()
  local c
  [ "$DO_NET" -eq 1 ] && need+=("${DEPS_NET[@]}")
  [ "$DO_IP" -eq 1 ] && need+=("${DEPS_IP[@]}")
  if [ "$IS_ROOT" -eq 1 ] && [ $((TCP_ROUTE + TCP_LARGE + TCP_EDU)) -gt 0 ]; then
    need+=("${DEPS_TCP[@]}")
    [ "$TCP_LARGE" -eq 1 ] && [ "$RUN_V4" -eq 1 ] && need+=("${DEPS_LARGE_OPT[@]}")
  fi
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 && continue
    [[ " ${out[*]} " == *" $c "* ]] || out+=("$c")
  done
  echo "${out[*]}"
}

DEPS_FAILED=0
ensure_deps() {
  local missing pm c pkg answer inst
  local -a pkgs=() manual=()
  local want_nt=0
  missing=$(missing_commands)
  [ -z "$missing" ] && return 0

  pm=$(pkg_manager)
  for c in $missing; do
    if [ "$c" = "nexttrace-tiny" ]; then want_nt=1; continue; fi
    pkg=$(pkg_name "$c" "$pm")
    if [ -n "$pkg" ] && [ -n "$pm" ]; then
      [[ " ${pkgs[*]} " == *" $pkg "* ]] || pkgs+=("$pkg")
    else
      manual+=("$c")
    fi
  done

  case "$pm" in
    apk) inst="apk add" ;;
    pacman) inst="pacman -S" ;;
    *) inst="$pm install" ;;
  esac
  echo "${C_Y}缺少依赖：${missing}${C_0}" >&2
  [ "${#pkgs[@]}" -gt 0 ] && echo "  安装命令：$inst ${pkgs[*]}" >&2
  [ "$want_nt" -eq 1 ] && echo "  nexttrace-tiny：从 NTrace-core Release 下载到 /usr/local/bin" >&2
  [ "${#manual[@]}" -gt 0 ] && echo "  系统仓库中没有，需手动安装：${manual[*]}" >&2

  if [ "${#pkgs[@]}" -eq 0 ] && [ "$want_nt" -eq 0 ]; then
    echo "  缺失项目对应的检测会被跳过。" >&2
    return 0
  fi
  if [ "$IS_ROOT" -eq 0 ] && [ -z "$SUDO" ]; then
    echo "  当前不是 root 且没有 sudo，无法自动安装；缺失项目对应的检测会被跳过。" >&2
    return 0
  fi
  if [ "$OPT_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      # 读不到输入（EOF）按不安装处理，只有回车或 y 才安装
      if ! read -r -p "是否现在安装？[Y/n] " answer </dev/tty || [[ ! "$answer" =~ ^([yY]([eE][sS])?)?$ ]]; then
        echo "  已跳过安装，缺失项目对应的检测会被跳过。" >&2
        return 0
      fi
    else
      echo "  非交互运行，未安装（加 -y 可自动安装）。" >&2
      return 0
    fi
  fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    echo "  正在安装：${pkgs[*]} ..." >&2
    pkg_install "$pm" "${pkgs[@]}" || { echo "${C_Y}  部分软件包安装失败${C_0}" >&2; DEPS_FAILED=1; }
  fi
  if [ "$want_nt" -eq 1 ]; then
    echo "  正在下载并校验 nexttrace-tiny ..." >&2
    install_nexttrace_tiny || { echo "${C_Y}  nexttrace-tiny ${NT_ERR}，大包回程将不做线路识别${C_0}" >&2; DEPS_FAILED=1; }
  fi
  hash -r
}

# deps_ok 命令…：全部存在返回 0，否则打印跳过提示并返回 1
deps_ok() {
  local c miss=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss+=" $c"; done
  [ -z "$miss" ] && return 0
  ui_warn "缺少依赖:${miss}"
  return 1
}

# ==================== 模块：网络信息 ====================
# net_run 4|6：BGP / 上游（RIPEstat + PeeringDB，缺失字段由 bgp.tools / bgp.he.net 兜底）
# 与 NAT 类型（stunclient，仅 IPv4）

NET_RIPESTAT="https://stat.ripe.net/data"
NET_PEERINGDB="https://www.peeringdb.com/api"
NET_BGPTOOLS="https://bgp.tools"
NET_HENET="https://bgp.he.net"
# 需支持 RFC 5780（OTHER-ADDRESS + CHANGE-REQUEST）的服务器，按顺序尝试
NET_STUN_SERVERS=(stun.voipgate.com:3478 stun.easybell.de:3478)
# 公认的 Tier-1（无上游）网络
NET_TIER1=" 174 701 1299 2914 3257 3320 3356 3491 5511 6453 6461 6762 6830 7018 12956 "

declare -A NET_B=()    # BGP 字段
declare -A NET_S=()    # 字段来源（非 RIPEstat 时记录）
declare -A NET_W=()    # whois 解析结果
declare -A NET_NAT=()  # stunclient 解析结果
NET_STUNCLIENT=""
NET_STUNCLIENT_ERR=""

# 仓库 bin/ 下的静态编译 stunclient（编译方式见 bin/README.md），按架构写死 sha256
NET_STUNCLIENT_URL="https://raw.githubusercontent.com/moran1024a/VPSCheck/main/bin"
declare -A NET_STUNCLIENT_SHA256=(
  [amd64]=ab8b8d98840217eadb8f2cf02e2ef4f749c8e71bc90f0df6d66d6a2941715cb3
  [arm64]=2867b077184b269691ba8114332baa400622419cabd623bdcc0a295098cfd10f
)
NET_PIDS=()

# ---------- 通用 ----------

# 显示宽度：ASCII 与 2 字节字符记 1 列，3/4 字节字符（中文等）记 2 列
net_width() {
  local s="${1//$'\033'\[*([0-9;])m/}" rest c b i w
  w=${#s}
  rest="${s//[[:ascii:]]/}"
  for (( i = 0; i < ${#rest}; i++ )); do
    c="${rest:i:1}"
    b=$(LC_ALL=C; echo "${#c}")
    [ "$b" -ge 3 ] && w=$((w + 1))
  done
  echo "$w"
}

# net_wrap 文本 宽度：按空格折行，超宽单词按字符硬切
net_wrap() {
  local width="$2" line="" lw=0 word ww piece pw c cw
  local -a words
  read -ra words <<< "$1"
  for word in "${words[@]}"; do
    ww=$(net_width "$word")
    if [ -n "$line" ] && [ $((lw + 1 + ww)) -le "$width" ]; then
      line+=" $word"; lw=$((lw + 1 + ww)); continue
    fi
    [ -n "$line" ] && printf '%s\n' "$line"
    while [ "$ww" -gt "$width" ]; do
      piece=""; pw=0
      while [ -n "$word" ]; do
        c="${word:0:1}"; cw=$(net_width "$c")
        [ $((pw + cw)) -gt "$width" ] && break
        piece+="$c"; pw=$((pw + cw)); word="${word:1}"
      done
      printf '%s\n' "$piece"
      ww=$(net_width "$word")
    done
    line="$word"; lw=$ww
  done
  [ -n "$line" ] && printf '%s\n' "$line"
}

# net_kv 键 值 [颜色] [来源]：值超宽时折行续排；值为空显示暗色 "-"；来源以暗色后缀标注
net_kv() {
  local key="$1" text="$2" color="${3:-$C_G}" src="${4:-}" vw tag="" line
  local -a lines
  if [ -z "$text" ]; then ui_kv "$key" "$(ui_na)"; return; fi
  vw=$(( UI_W - UI_KEY_W - 2 ))
  [ -n "$src" ] && tag="($src)" && text+=" $tag"
  mapfile -t lines < <(net_wrap "$text" "$vw")
  local n=${#lines[@]} i
  for (( i = 0; i < n; i++ )); do
    line="${lines[i]}"
    if [ "$i" -eq $((n - 1)) ] && [ -n "$tag" ] && [[ "$line" == *"$tag" ]]; then
      line="${color}${line%"$tag"}${C_0}${C_D}${tag}${C_0}"
    else
      line="${color}${line}${C_0}"
    fi
    ui_kv "$([ "$i" -eq 0 ] && printf '%s' "$key")" "$line"
  done
}

# net_fetch URL 输出文件 [超时] [retry]：成功且非空返回 0；带 retry 时失败后再试一次
# （不用 curl --retry：它不重试 TLS 握手失败，且会按限流响应的 Retry-After 等上一分钟）
net_fetch() {
  local n=1
  [ -n "${4:-}" ] && n=2
  while :; do
    curl -fsSL --connect-timeout 8 -m "${3:-20}" -A "$UA_BROWSER" -o "$2" "$1" 2>/dev/null && [ -s "$2" ] && return 0
    n=$((n - 1))
    [ "$n" -gt 0 ] || return 1
    sleep 1
  done
}

# net_ripe 数据接口 查询参数 输出文件：RIPEstat Data API，status 为 ok 才算成功；
# 第一阶段全部失败后视为不可用，不再请求
net_ripe() {
  [ -n "${NET_B[ripe_down]:-}" ] && return 1
  net_fetch "$NET_RIPESTAT/$1/data.json?$2&sourceapp=vpscheck" "$3" 20 retry \
    && jq -e '.status == "ok"' "$3" >/dev/null 2>&1 || { rm -f "$3"; return 1; }
}

# 后台并行请求
net_bg() { "$@" & NET_PIDS+=("$!"); }
net_wait() {
  local p
  for p in "${NET_PIDS[@]}"; do wait "$p" 2>/dev/null; done
  NET_PIDS=()
}

# net_set 字段 值 [来源]：只填空字段
net_set() {
  [ -n "${NET_B[$1]:-}" ] && return 0
  [ -z "$2" ] || [ "$2" = "null" ] && return 0
  NET_B[$1]="$2"
  [ -n "${3:-}" ] && NET_S[$1]="$3"
  return 0
}

# 日期统一为 YYYY-MM-DD（移植自 NetQuality parse_date）
net_parse_date() {
  local s="${1%%,*}"
  if [[ "$s" =~ ^([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2}) ]]; then
    printf '%04d-%02d-%02d' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
  elif [[ "$s" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    printf '%s-%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$s" =~ ^[0-9]{1,2}\ [A-Za-z]{3}\ [0-9]{4} ]]; then
    date -d "$s" +%Y-%m-%d 2>/dev/null
  fi
}

# HTML 实体还原（移植自 NetQuality replace_html_entities）
net_html_unescape() {
  sed -E -e 's/&#45;/-/g' -e 's/&#38;/\&/g' -e "s/&#39;/'/g" -e 's/&#34;/"/g' \
    -e 's/&#60;|&lt;/</g' -e 's/&#62;|&gt;/>/g' -e 's/&#160;/ /g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g' <<< "$1"
}

# ---------- whois ----------

# net_whois_parse 文件：whois 文本（空行分隔对象）解析进 NET_W。
# 同一键连续出现的值以 ", " 拼接，只取第一次出现；跳过联系人 / 维护者等对象，
# 避免把 RIPE 占位联系人的地址当成组织地址；第一个 route 对象单独记为 rt:*。
net_whois_parse() {
  NET_W=()
  local k v
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && NET_W[$k]="$v"
  done < <(tr -d '\r' < "$1" | awk '
    /^[ \t]*$/ { if (blk ~ /^route6?$/) rtdone = 1; blk = ""; last = ""; next }
    /^[%#]/ { next }
    {
      if (!match($0, /^[A-Za-z][A-Za-z0-9_-]*:/)) next
      key = tolower(substr($0, 1, RLENGTH - 1)); val = substr($0, RLENGTH + 1)
      gsub(/\t/, " ", val); gsub(/^ +| +$/, "", val)
      if (blk == "") blk = key
      if (blk ~ /^route6?$/) {
        if (!rtdone && val != "" && !(("rt:" key) in w)) w["rt:" key] = val
        next
      }
      if (blk ~ /^(person|role|irt|mntner|aut-num|as-set|domain|(org|r)(abuse|tech|noc|routing)handle)$/) next
      if (val == "" || val ~ /^\*+$/) next
      if (key == last) w[key] = w[key] ", " val
      else if (!(key in w)) { w[key] = val; w[key ".1"] = val; last = key }
      else last = ""
    }
    END { for (k in w) print k "\t" w[k] }')
}

# net_whois_apply 来源 [full]：由 NET_W 填组织 / 地址 / 国家 / 日期 / RIR；
# full 时也填前缀与 ASN（仅兜底源使用，RIPEstat 的前缀与 ASN 取自路由数据）
net_whois_apply() {
  local src="$1" v a part
  v="${NET_W[org-name]:-${NET_W[orgname]:-${NET_W[organization]:-${NET_W[owner]:-${NET_W[descr.1]:-}}}}}"
  [[ "$v" =~ ^(.*[^ ])\ +\([A-Z0-9-]+\)$ ]] && v="${BASH_REMATCH[1]}"
  net_set org "$v" "$src"

  a=""
  for part in "${NET_W[address]:-}" "${NET_W[city]:-}" "${NET_W[stateprov]:-}" "${NET_W[postalcode]:-}"; do
    [ -n "$part" ] && a+="${a:+, }$part"
  done
  net_set address "$(sed -E 's/,+/,/g' <<< "$a")" "$src"

  v="${NET_W[country.1]:-}"; v="${v^^}"
  [[ "$v" =~ ^[A-Z]{2}$ ]] && net_set country "$v" "$src"
  net_set regdate "$(net_parse_date "${NET_W[created.1]:-${NET_W[regdate.1]:-}}")" "$src"
  net_set moddate "$(net_parse_date "${NET_W[last-modified.1]:-${NET_W[updated.1]:-${NET_W[changed.1]:-}}}")" "$src"

  v="${NET_W[source.1]:-}"; v="${v%% *}"
  if [[ ! "$v" =~ ^(RIPE|APNIC|ARIN|LACNIC|AFRINIC)$ ]]; then
    v=""
    [[ "${NET_W[mnt-by.1]:-}" =~ ^(RIPE|APNIC|ARIN|LACNIC|AFRINIC)- ]] && v="${BASH_REMATCH[1]}"
    [ -z "$v" ] && [ -n "${NET_W[ownerid]:-}" ] && v="LACNIC"
    [ -z "$v" ] && [ -n "${NET_W[orgtechhandle]:-}${NET_W[nethandle]:-}" ] && v="ARIN"
  fi
  [ "$v" = "RIPE" ] && v="RIPE NCC"
  net_set rir "$v" "$src"

  [ "${2:-}" = "full" ] || return 0
  v="${NET_W[rt:route]:-${NET_W[rt:route6]:-${NET_W[cidr.1]:-${NET_W[inetrev.1]:-}}}}"
  v="${v%%,*}"
  [[ "$v" == */* ]] && [ -z "${NET_B[unannounced]:-}" ] && net_set prefix "$v" "$src"
  v="${NET_W[rt:origin]:-${NET_W[originas.1]:-${NET_W[origin.1]:-}}}"
  [[ "$v" =~ ^(AS|as)?([0-9]+) ]] && net_set asn "${BASH_REMATCH[2]}" "$src"
}

# ---------- RIPEstat / PeeringDB ----------

# 第一阶段：前缀 + 起源 AS（prefix-overview）、whois、RIR 分配信息
net_ripe_stage1() {
  local ip="$1" d="$2" line a b c h
  net_bg net_ripe prefix-overview "resource=$ip" "$d/po.json"
  net_bg net_ripe whois "resource=$ip" "$d/whois.json"
  net_bg net_ripe rir "resource=$ip&lod=2" "$d/rir.json"
  net_wait
  [ -s "$d/po.json" ] || [ -s "$d/whois.json" ] || [ -s "$d/rir.json" ] || NET_B[ripe_down]=1

  [ -s "$d/po.json" ] && [ "$(jq -r '.data.announced' "$d/po.json")" = "false" ] && NET_B[unannounced]=1
  if [ -s "$d/po.json" ] && [ -z "${NET_B[unannounced]:-}" ]; then
    net_set prefix "$(jq -r '.data.resource // empty' "$d/po.json")"
    NET_B[asn_more]=""
    while IFS=$'\t' read -r a h; do
      [ -z "$a" ] && continue
      if [ -z "${NET_B[asn]:-}" ]; then
        NET_B[asn]="$a"; net_set asname "$h"
      else
        NET_B[asn_more]+="AS$a $h"$'\n'
      fi
    done < <(jq -r '.data.asns[]? | "\(.asn)\t\(.holder // "")"' "$d/po.json")
  fi

  if [ -s "$d/whois.json" ]; then
    jq -r '.data.records[]? | (map("\(.key): \(.value)") | .[]), ""' "$d/whois.json" > "$d/whois.txt"
    net_whois_parse "$d/whois.txt"
    net_whois_apply ""
  fi

  if [ -s "$d/rir.json" ]; then
    line=$(jq -r '.data.rirs[0]? // empty | "\(.rir // "")\t\(.country // "")\t\(.registration // "")"' "$d/rir.json")
    IFS=$'\t' read -r a b c <<< "$line"
    NET_B[rir]="${a:-${NET_B[rir]:-}}"; [ -n "$a" ] && NET_S[rir]=""
    net_set country "$b"
    net_set regdate "$(net_parse_date "$c")"
  fi
}

# 邻居分类（输出第一行 "上游 对等 下游"，其后为按路径数排序的上游 ASN）：
#   同一 ASN 的条目合并；仅出现在左侧(left)、且路径数 >= 最强左侧邻居 10% -> 上游；
#   仅出现在右侧(right) -> 下游；两侧都出现、仅 RIS 直连可见(uncertain)、或左侧但路径数很少 -> 对等。
#   被查询 AS 属于 Tier-1 时不存在上游，左侧邻居全部记为对等。
net_classify_neighbours() {
  jq -r --arg t1 "$2" '
    [.data.neighbours[]?] | group_by(.asn)
    | map({asn: .[0].asn,
           l: ([.[] | select(.type == "left") | .power] | add // 0),
           hl: any(.[]; .type == "left"), hu: any(.[]; .type == "uncertain"),
           r: any(.[]; .type == "right")})
    | (map(.l) | max // 0) as $m
    | map(.c = (if .hl and (.r | not) and ($t1 != "1") and ($m == 0 or .l * 10 >= $m) then "up"
                elif .r and (.hl | not) and (.hu | not) then "down" else "peer" end))
    | "\(map(select(.c == "up")) | length) \(map(select(.c == "peer")) | length) \(map(select(.c == "down")) | length)",
      (map(select(.c == "up")) | sort_by(-.l) | .[0:4][] | "\(.asn)")' "$1" 2>/dev/null
}

# 第二阶段：RPKI、邻居（上游 / 对等 / 下游）、PeeringDB IX / 机房数，再查主要上游的 AS 名称
net_ripe_stage2() {
  local d="$1" asn="${NET_B[asn]}" prefix="${NET_B[prefix]:-}" t1=0 counts a b c i
  local -a ups=()
  [ -n "$prefix" ] && net_bg net_ripe rpki-validation "resource=AS$asn&prefix=$prefix" "$d/rpki.json"
  net_bg net_ripe asn-neighbours "resource=AS$asn" "$d/nb.json"
  net_bg net_fetch "$NET_PEERINGDB/net?asn=$asn&fields=ix_count,fac_count" "$d/pdb.json" 20 retry
  net_wait

  [ -s "$d/rpki.json" ] && net_set rpki "$(jq -r '.data.status // empty' "$d/rpki.json")"

  if [ -s "$d/pdb.json" ] && jq -e '.data | type == "array"' "$d/pdb.json" >/dev/null 2>&1; then
    if [ "$(jq '.data | length' "$d/pdb.json")" -gt 0 ]; then
      net_set ix "$(jq -r '.data[0].ix_count // empty' "$d/pdb.json")"
      net_set fac "$(jq -r '.data[0].fac_count // empty' "$d/pdb.json")"
    else
      NET_B[pdb_none]=1
    fi
  fi

  if [ -s "$d/nb.json" ]; then
    [[ "$NET_TIER1" == *" $asn "* ]] && t1=1
    mapfile -t ups < <(net_classify_neighbours "$d/nb.json" "$t1")
    counts="${ups[0]:-}"; ups=("${ups[@]:1}")
    read -r a b c <<< "$counts"
    if [ -n "$a" ] && [ $((a + b + c)) -gt 0 ]; then
      NET_B[up]=$a; NET_B[peer]=$b; NET_B[down]=$c
      [ "$t1" -eq 1 ] || { [ "$a" -eq 0 ] && [ "$b" -gt 0 ]; } && NET_B[tf]=1
      for i in "${!ups[@]}"; do
        net_bg net_ripe as-overview "resource=AS${ups[i]}" "$d/up_$i.json"
      done
      net_wait
      NET_B[mainup]=""
      for i in "${!ups[@]}"; do
        a=""
        [ -s "$d/up_$i.json" ] && a=$(jq -r '.data.holder // empty' "$d/up_$i.json")
        a=${a#"AS${ups[i]} - "}
        NET_B[mainup]+="AS${ups[i]}${a:+ $a}"$'\n'
      done
    fi
  fi
}

# ---------- 兜底：bgp.tools（移植自 NetQuality db_bgptools / calc_upstream / calc_ix / calc_peers） ----------

# 第一个 id 为 $2 的表格的行数 - 1（表头）；表格不存在时输出空。
# 页面后部的 IRR 校验表也叫 upstreamTable，只能数第一个
net_bt_rows() {
  awk -v id="$2" 'index($0, "<table id=\"" id "\"") { on = 1 }
    on && /<tr>/ { n++ }
    on && /<\/table>/ { exit }
    END { if (n) print n - 1 }' "$1"
}

# 解析 AS 路径图 SVG（graphviz）：输出 "N<TAB>asn<TAB>名称<TAB>是否目标" 与 "E<TAB>边标题"；
# 名称优先取链接上的全称 xlink:title，没有再用节点里的 10pt 短名
net_bt_svg() {
  awk '
    /<g id="[^"]*" class="node"/ { mode = "n"; asn = ""; name = ""; full = ""; tg = 0; next }
    /<g id="[^"]*" class="edge"/ { mode = "e"; title = ""; next }
    mode == "n" {
      s = $0
      if (s ~ /<text.*font-weight="bold".*>/) { sub(/^.*font-weight="bold"[^>]*>/, "", s); sub(/<.*$/, "", s); asn = s }
      else if (s ~ /<text.*font-size="10.00".*>/) { sub(/^.*font-size="10.00"[^>]*>/, "", s); sub(/<.*$/, "", s); name = s }
      if ($0 ~ /xlink:title="/) { s = $0; sub(/^.*xlink:title="/, "", s); sub(/".*$/, "", s); full = s }
      if ($0 ~ /stroke="limegreen"/) tg = 1
      if ($0 ~ /<\/g>/) { print "N\t" asn "\t" (full != "" ? full : name) "\t" tg; mode = "" }
    }
    mode == "e" {
      if ($0 ~ /<title>/) { s = $0; sub(/^.*<title>/, "", s); sub(/<\/title>.*$/, "", s); title = s }
      if ($0 ~ /<\/g>/) { print "E\t" title; mode = "" }
    }' "$1"
}

net_fb_bgptools() {
  local ip="$1" d="$2" f="$d/bt.html" p v src target t a n tg
  local -a nodes=() edges=() ups=()
  NET_B[bt_done]=1
  net_fetch "$NET_BGPTOOLS/prefix/$ip" "$f" 15 || return 1
  if grep -q "Overlapping Prefixes Detected" "$f"; then
    p=$(grep -o 'href="/prefix/[^"]*' "$f" | head -1 | cut -d/ -f3-)
    [ -n "$p" ] && net_fetch "$NET_BGPTOOLS/prefix/$p" "$f" 15
  fi
  # 被人机验证页拦截时没有 network-name
  grep -q 'id="network-name"' "$f" || return 1
  NET_B[bt_ok]=1

  p=$(sed -n 's/.*<p id="network-name" class="heading-xlarge">\([^<]*\)<\/p>.*/\1/p' "$f" | head -1)
  [[ "$p" == */* ]] && net_set prefix "$p" bgp.tools
  v=$(awk -v RS='<strong>' '/Originated by/ {getline; print $0}' "$f" | sed 's/<[^>]*>//g' | head -1)
  [[ "${v%%,*}" =~ ([0-9]+) ]] && net_set asn "${BASH_REMATCH[1]}" bgp.tools
  v=$(sed -n 's/.*AS Name: <strong>\([^<]*\)<\/strong>.*/\1/p' "$f" | head -1)
  net_set asname "$(net_html_unescape "$v")" bgp.tools

  # 页面内嵌的 whois，留给 whois 兜底使用
  sed -n '/<div style="display: none" id="whois-page">/,/<\/div>/p' "$f" \
    | sed -n '/<pre style="white-space: pre-wrap;">/,/<\/pre>/p' \
    | sed -e 's/<pre style="white-space: pre-wrap;">//' -e 's/<[^>]*>//g' > "$d/bt_whois.txt"

  # calc_peers
  if [ -z "${NET_B[up]:-}" ]; then
    if grep -q "This network is transit-free." "$f"; then
      NET_B[up]=0; NET_B[tf]=1
    else
      NET_B[up]=$(net_bt_rows "$f" upstreamTable)
    fi
    NET_B[peer]=$(net_bt_rows "$f" peersTable)
    NET_B[down]=""
    NET_S[nb]=bgp.tools
  fi

  # calc_upstream：图中由目标 AS 直接指向的节点即直接上游
  src=$(sed -n 's|.*src="\(/pathimg/[^"]*\)".*|\1|p' "$f" | head -1)
  if [ -z "${NET_B[mainup]:-}" ] && [ -z "${NET_B[tf]:-}" ] && [ -n "$src" ] \
    && net_fetch "$NET_BGPTOOLS$src?$(cat /proc/sys/kernel/random/uuid 2>/dev/null)&loggedin" "$d/bt.svg" 15; then
    target=""
    while IFS=$'\t' read -r t a n tg; do
      if [ "$t" = N ]; then
        a="${a#AS}"
        [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -gt 0 ] || continue
        [ "$tg" = 1 ] && target="$a" || nodes+=("$a"$'\t'"$(net_html_unescape "$n")")
      else
        edges+=("$(net_html_unescape "$a")")
      fi
    done < <(net_bt_svg "$d/bt.svg")
    for v in "${nodes[@]}"; do
      a="${v%%$'\t'*}"
      for t in "${edges[@]}"; do
        if [[ "$t" =~ (^|[^0-9])AS$target([^0-9].*)AS$a([^0-9]|$) ]]; then
          ups+=("AS$a ${v#*$'\t'}"); break
        fi
      done
    done
    if [ "${#ups[@]}" -gt 0 ]; then
      NET_B[mainup]=$(printf '%s\n' "${ups[@]:0:4}")$'\n'
      NET_S[mainup]=bgp.tools
    fi
  fi

  return 0
}

# calc_ix：IX 路由服务器上可见的数量（PeeringDB 查不到时才用）
net_fb_bt_ix() {
  local d="$1"
  [ -n "${NET_B[bt_ok]:-}" ] && [ -z "${NET_B[ix]:-}" ] && [ -n "${NET_B[prefix]:-}" ] || return 0
  net_fetch "$NET_BGPTOOLS/ixp-rs-route/${NET_B[prefix]}" "$d/bt_ix.html" 15 \
    && net_set ix "$(net_bt_rows "$d/bt_ix.html" upstreamTable)" bgp.tools
}

# ---------- 兜底：bgp.he.net whois（移植自 NetQuality db_henet） ----------

net_fb_henet() {
  local ip="$1" d="$2" i
  NET_B[he_done]=1
  for i in 1 2; do
    if net_fetch "$NET_HENET/whois/ip/$ip" "$d/he.json" 15 \
      && jq -r '.data // empty' "$d/he.json" 2>/dev/null | sed -e 's/\\n/\n/g' -e 's/\\t/\t/g' > "$d/he.txt" \
      && [ -s "$d/he.txt" ]; then
      net_whois_parse "$d/he.txt"
      net_whois_apply he.net full
      return 0
    fi
    [ "$i" -eq 1 ] && sleep 2
  done
  return 1
}

net_need_route() {
  [ -z "${NET_B[unannounced]:-}" ] || return 1
  [ -z "${NET_B[prefix]:-}" ] || [ -z "${NET_B[asn]:-}" ] || [ -z "${NET_B[asname]:-}" ] \
    || [ -z "${NET_B[up]:-}" ] || [ -z "${NET_B[ix]:-}" ]
}
net_need_whois() {
  [ -z "${NET_B[org]:-}" ] || [ -z "${NET_B[address]:-}" ] || [ -z "${NET_B[country]:-}" ] \
    || [ -z "${NET_B[regdate]:-}" ] || [ -z "${NET_B[moddate]:-}" ] || [ -z "${NET_B[rir]:-}" ]
}

# 收集 BGP 信息：RIPEstat 优先，缺失字段再走兜底
net_bgp_collect() {
  local ip="$1" d="$2"
  NET_B=(); NET_S=()
  ui_prog "BGP 信息：查询 RIPEstat"
  net_ripe_stage1 "$ip" "$d"

  # 拿不到 ASN 时先兜底，后续的 RPKI / 邻居 / PeeringDB 都依赖 ASN
  if [ -z "${NET_B[asn]:-}" ]; then
    ui_prog "BGP 信息：RIPEstat 无结果，尝试 bgp.tools / bgp.he.net"
    net_need_route && net_fb_bgptools "$ip" "$d"
    net_fb_henet "$ip" "$d"
  fi
  if [ -n "${NET_B[asn]:-}" ]; then
    ui_prog "上游与接入：查询 RIPEstat / PeeringDB"
    net_ripe_stage2 "$d"
  fi
  if net_need_route && [ -z "${NET_B[bt_done]:-}" ]; then
    ui_prog "BGP 信息：补充查询 bgp.tools"
    net_fb_bgptools "$ip" "$d"
  fi
  if net_need_whois && [ -z "${NET_B[he_done]:-}" ]; then
    ui_prog "BGP 信息：补充查询 bgp.he.net"
    net_fb_henet "$ip" "$d"
  fi
  # bgp.tools 页面内嵌的 whois 作为最后一道
  if net_need_whois && [ -s "$d/bt_whois.txt" ]; then
    net_whois_parse "$d/bt_whois.txt"
    net_whois_apply bgp.tools full
  fi
  net_fb_bt_ix "$d"
  if [ -n "${NET_B[asn]:-}" ] && [ -z "${NET_B[asname]:-}" ] && net_ripe as-overview "resource=AS${NET_B[asn]}" "$d/asov.json"; then
    net_set asname "$(jq -r '.data.holder // empty' "$d/asov.json")"
  fi
  ui_prog_clear
}

# ---------- BGP 展示 ----------

net_show_bgp() {
  local v line
  ui_sub "BGP 信息"

  if [ -z "${NET_B[prefix]:-}" ] && [ -z "${NET_B[asn]:-}" ] && [ -z "${NET_B[org]:-}" ]; then
    ui_warn "未查到 BGP 信息"
    return 1
  fi

  if [ -n "${NET_B[unannounced]:-}" ]; then
    net_kv "前缀" "未宣告" "$C_Y"
  else
    net_kv "前缀" "${NET_B[prefix]:-}" "" "${NET_S[prefix]:-}"
  fi
  v=""; [ -n "${NET_B[asn]:-}" ] && v="AS${NET_B[asn]}${NET_B[asname]:+ ${NET_B[asname]}}"
  net_kv "ASN" "$v" "" "${NET_S[asn]:-${NET_S[asname]:-}}"
  while IFS= read -r line; do
    [ -n "$line" ] && net_kv "" "$line"
  done <<< "${NET_B[asn_more]:-}"
  net_kv "组织" "${NET_B[org]:-}" "" "${NET_S[org]:-}"
  net_kv "注册机构" "${NET_B[rir]:-}" "" "${NET_S[rir]:-}"
  net_kv "国家/地区" "${NET_B[country]:-}" "" "${NET_S[country]:-}"
  net_kv "地址" "${NET_B[address]:-}" "" "${NET_S[address]:-}"
  net_kv "注册日期" "${NET_B[regdate]:-}" "" "${NET_S[regdate]:-}"
  net_kv "修改日期" "${NET_B[moddate]:-}" "" "${NET_S[moddate]:-}"
  case "${NET_B[rpki]:-}" in
    valid)          net_kv "RPKI 状态" "有效（valid）" "$C_G" ;;
    invalid_asn)    net_kv "RPKI 状态" "无效（起源 AS 不符）" "$C_R" ;;
    invalid_length) net_kv "RPKI 状态" "无效（前缀长度超出）" "$C_R" ;;
    invalid*)       net_kv "RPKI 状态" "无效（${NET_B[rpki]}）" "$C_R" ;;
    unknown)        net_kv "RPKI 状态" "未签 ROA（unknown）" "$C_Y" ;;
    *)              net_kv "RPKI 状态" "" ;;
  esac
}

net_show_conn() {
  local up v src line first=1
  ui_sub "上游与接入"

  src="${NET_S[nb]:-}"
  if [ -n "${NET_B[up]:-}${NET_B[peer]:-}" ]; then
    if [ -n "${NET_B[tf]:-}" ]; then
      up="${C_G}Transit-Free${C_0}"
    else
      up="$C_G${NET_B[up]:-无}$C_0"
    fi
    v="${C_G}上游 $up$C_G / 对等 ${NET_B[peer]:-无} / 下游 ${NET_B[down]:-无}$C_0"
    [ -n "$src" ] && v+=" ${C_D}($src)${C_0}"
    ui_kv "邻居数量" "$v"
  else
    net_kv "邻居数量" ""
  fi

  if [ -n "${NET_B[tf]:-}" ]; then
    net_kv "主要上游" "无（Transit-Free）" "$C_G"
  elif [ -n "${NET_B[mainup]:-}" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      net_kv "$([ "$first" -eq 1 ] && echo 主要上游)" "$line" "" "$([ "$first" -eq 1 ] && echo "${NET_S[mainup]:-}")"
      first=0
    done <<< "${NET_B[mainup]}"
  else
    net_kv "主要上游" ""
  fi

  if [ -n "${NET_B[ix]:-}" ]; then
    net_kv "IX 数量" "${NET_B[ix]}" "" "${NET_S[ix]:-}"
  elif [ -n "${NET_B[pdb_none]:-}" ]; then
    ui_kv "IX 数量" "$(ui_na)"
  else
    net_kv "IX 数量" ""
  fi
  if [ -n "${NET_B[fac]:-}" ]; then
    net_kv "机房数量" "${NET_B[fac]}"
  elif [ -n "${NET_B[pdb_none]:-}" ]; then
    ui_kv "机房数量" "$(ui_na)"
  else
    net_kv "机房数量" ""
  fi
  return 0
}

# ---------- NAT（stunclient / stuntman，RFC 5780） ----------

# 解析 stunclient 输出到 NET_NAT（格式见 stuntman client/clientmain.cpp DumpResults）
net_nat_parse() {
  NET_NAT=()
  local line
  while IFS= read -r line; do
    case "$line" in
      "Binding test: "*)   NET_NAT[bind]="${line#*: }" ;;
      "Local address: "*)  NET_NAT[local]="${line#*: }" ;;
      "Mapped address: "*) NET_NAT[mapped]="${line#*: }" ;;
      "Behavior test: "*)  NET_NAT[btest]="${line#*: }" ;;
      "Nat behavior: "*)   NET_NAT[beh]="${line#*: }" ;;
      "Filtering test: "*) NET_NAT[ftest]="${line#*: }" ;;
      "Nat filtering: "*)  NET_NAT[filt]="${line#*: }" ;;
    esac
  done <<< "$1"
}

# 映射 / 过滤行为简写：EIM ADM APDM DIRECT / EIF ADF APDF
net_nat_code() {
  case "$1" in
    "Direct Mapping"*)               echo DIRECT ;;
    "Endpoint Independent"*)         echo "EI${2}" ;;
    "Address and Port Dependent"*)   echo "APD${2}" ;;
    "Address Dependent"*)            echo "AD${2}" ;;
  esac
}

# 分类结果写入 NET_NAT[type] / NET_NAT[color] / NET_NAT[m] / NET_NAT[f]
net_nat_classify() {
  local m f direct=0
  m=$(net_nat_code "${NET_NAT[beh]:-}" M)
  f=$(net_nat_code "${NET_NAT[filt]:-}" F)
  [ "$f" = DIRECT ] && f=""
  NET_NAT[m]="$m"; NET_NAT[f]="$f"
  if [ "${NET_NAT[bind]:-}" != "success" ]; then
    NET_NAT[type]="UDP 被阻断"; NET_NAT[color]="$C_R"; return
  fi
  [ "$m" = DIRECT ] && direct=1
  [ -n "${NET_NAT[local]:-}" ] && [ "${NET_NAT[local]}" = "${NET_NAT[mapped]:-}" ] && direct=1
  if [ "$direct" -eq 1 ]; then
    NET_NAT[m]=DIRECT
    case "$f" in
      EIF)      NET_NAT[type]="开放（公网直连）";       NET_NAT[color]="$C_G" ;;
      ADF|APDF) NET_NAT[type]="防火墙";                 NET_NAT[color]="$C_Y" ;;
      *)        NET_NAT[type]="公网直连（过滤行为未知）"; NET_NAT[color]="$C_Y" ;;
    esac
    return
  fi
  case "$m" in
    ADM|APDM) NET_NAT[type]="NAT4 对称型（Symmetric）"; NET_NAT[color]="$C_R" ;;
    EIM)
      case "$f" in
        EIF)  NET_NAT[type]="NAT1 全锥形（Full Cone）";                   NET_NAT[color]="$C_G" ;;
        ADF)  NET_NAT[type]="NAT2 受限锥形（Restricted Cone）";           NET_NAT[color]="$C_G" ;;
        APDF) NET_NAT[type]="NAT3 端口受限锥形（Port Restricted Cone）";  NET_NAT[color]="$C_Y" ;;
        *)    NET_NAT[type]="未知（过滤行为未测出）";                     NET_NAT[color]="$C_Y" ;;
      esac ;;
    *) NET_NAT[type]="未知（服务器不支持 RFC 5780 测试）"; NET_NAT[color]="$C_Y" ;;
  esac
}

# 依次尝试 STUN 服务器，结果留在 NET_NAT，服务器写入 NET_NAT[server]
# 优先用系统中的 stunclient；没有则下载到临时目录并校验。
# 成功时写入 NET_STUNCLIENT，失败时把原因写入 NET_STUNCLIENT_ERR
net_stunclient_get() {
  local arch file sum
  NET_STUNCLIENT_ERR=""
  NET_STUNCLIENT=$(command -v stunclient 2>/dev/null)
  [ -n "$NET_STUNCLIENT" ] && return 0
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) NET_STUNCLIENT_ERR="暂无 $(uname -m) 架构的 stunclient"; return 1 ;;
  esac
  command -v sha256sum >/dev/null 2>&1 || { NET_STUNCLIENT_ERR="缺少依赖: sha256sum"; return 1; }
  file="$WORKDIR/stunclient"
  ui_prog "NAT 类型：下载 stunclient（$arch）"
  if ! curl -fsSL --connect-timeout 10 --max-time 120 "$NET_STUNCLIENT_URL/stunclient_linux_$arch" -o "$file"; then
    NET_STUNCLIENT_ERR="stunclient 下载失败"
  else
    sum=$(sha256sum "$file" | awk '{print $1}')
    [ "$sum" = "${NET_STUNCLIENT_SHA256[$arch]}" ] || NET_STUNCLIENT_ERR="stunclient 校验失败（sha256 不符）"
  fi
  ui_prog_clear
  if [ -n "$NET_STUNCLIENT_ERR" ]; then
    rm -f "$file"
    return 1
  fi
  chmod 0755 "$file"
  # --help 正常时以非 0 退出，只有 126（无法执行）说明临时目录挂载了 noexec
  "$file" --help >/dev/null 2>&1
  if [ $? -eq 126 ]; then
    NET_STUNCLIENT_ERR="临时目录不可执行（noexec），无法运行 stunclient"
    return 1
  fi
  NET_STUNCLIENT="$file"
}

net_nat_probe() {
  local srv out best="" best_srv="" rank best_rank=0
  for srv in "${NET_STUN_SERVERS[@]}"; do
    ui_prog "NAT 类型：stunclient -> $srv"
    out=$(run_to 45 "$NET_STUNCLIENT" --mode full --family 4 "${srv%:*}" "${srv##*:}" 2>&1)
    net_nat_parse "$out"
    # 3=行为与过滤测试都成功，2=绑定成功，1=绑定明确失败，0=无结果（域名解析失败等）
    rank=0
    [ -n "${NET_NAT[bind]:-}" ] && rank=1
    [ "${NET_NAT[bind]:-}" = success ] && [ "${NET_NAT[btest]:-}" = success ] \
      && [ "${NET_NAT[ftest]:-}" = success ] && rank=3
    [ "${NET_NAT[bind]:-}" = success ] && [ "$rank" -lt 3 ] && rank=2
    if [ "$rank" -gt "$best_rank" ]; then best="$out"; best_srv="$srv"; best_rank=$rank; fi
    [ "$rank" -eq 3 ] && break
  done
  ui_prog_clear
  net_nat_parse "$best"
  NET_NAT[server]="${best_srv:-${NET_STUN_SERVERS[0]}}"
  NET_NAT[rank]=$best_rank
}

net_nat_show() {
  local lp mp
  ui_sub "NAT 类型"
  if [ "${NET_NAT[rank]:-0}" -eq 0 ]; then
    ui_warn "STUN 服务器无法连接"
    return
  fi
  net_nat_classify
  net_kv "NAT 类型" "${NET_NAT[type]}" "${NET_NAT[color]}"
  [ "${NET_NAT[bind]}" = success ] || return
  case "${NET_NAT[m]}" in
    DIRECT) net_kv "映射行为" "无 NAT（本地地址即公网地址）" ;;
    EIM)    net_kv "映射行为" "端点无关（EIM）" ;;
    ADM)    net_kv "映射行为" "地址相关（ADM）" ;;
    APDM)   net_kv "映射行为" "地址和端口相关（APDM）" ;;
    *)      net_kv "映射行为" "" ;;
  esac
  case "${NET_NAT[f]}" in
    EIF)  net_kv "过滤行为" "端点无关（EIF）" ;;
    ADF)  net_kv "过滤行为" "地址相关（ADF）" ;;
    APDF) net_kv "过滤行为" "地址和端口相关（APDF）" ;;
    *)    net_kv "过滤行为" "" ;;
  esac
  net_kv "公网映射地址" "${NET_NAT[mapped]:-}"
  lp="${NET_NAT[local]##*:}"; mp="${NET_NAT[mapped]##*:}"
  if [ -n "$lp" ] && [ -n "$mp" ]; then
    if [ "$lp" = "$mp" ]; then
      net_kv "端口保持" "是（本地端口 $lp）" "$C_G"
    else
      net_kv "端口保持" "否（本地 $lp -> 公网 $mp）" "$C_Y"
    fi
  else
    net_kv "端口保持" ""
  fi
}

# ---------- 入口 ----------

net_run() {
  local fam="$1" ip d
  [ "$fam" = 6 ] && ip="$PUB6" || ip="$PUB4"
  ui_section "网络信息 · IPv$fam"
  if [ -z "$ip" ]; then
    ui_warn "没有 IPv$fam 公网地址"
    return 0
  fi
  deps_ok curl jq || return 0
  d="$WORKDIR/net$fam"
  mkdir -p "$d" || return 0

  net_bgp_collect "$ip" "$d"
  net_show_bgp && net_show_conn

  # NAT 只测 IPv4
  [ "$fam" = 4 ] || return 0
  if ! net_stunclient_get; then
    ui_sub "NAT 类型"
    ui_warn "$NET_STUNCLIENT_ERR"
    return 0
  fi
  net_nat_probe
  net_nat_show
}

# ==================== 模块：IP 质量 ====================
# ip_run 4|6
# 移植自 xykt/IPQuality 完整模式：只做查询，不上传任何结果。

declare -gA IP_MM=() IP_INFO=() IP_SCAM=() IP_REG=() IP_API=() IP_ABUSE=() IP_I2L=() IP_DBIP=() IP_DATA=() IP_QS=()
declare -gA IP_MEDIA=() IP_MAIL=()
IP_ADDR=""
IP_FAM=""
IP_STEP=0
IP_STEPS=0
IP_RAW=""
IP_COOKIE=""
IP_MAIL_SVCS=(Gmail Outlook Yahoo Apple QQ MailRU AOL GMX MailCOM 163 Sohu Sina)
declare -gA IP_MAIL_DOMAIN=(
  [Gmail]=gmail.com [Outlook]=outlook.com [Yahoo]=yahoo.com [Apple]=me.com
  [QQ]=qq.com [MailRU]=mail.ru [AOL]=aol.com [GMX]=gmx.com
  [MailCOM]=mail.com [163]=163.com [Sohu]=sohu.com [Sina]=sina.com
)
IP_EDGE_UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Edg/119.0.0.0'
IP_EDGE_SEC='sec-ch-ua: "Microsoft Edge";v="119", "Chromium";v="119", "Not?A_Brand";v="24"'
IP_DISNEY_AUTH='ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84'

# ==================== 通用 ====================


# 超长文本按显示宽度截断
ip_fit() {
  local s="$1" max="$2"
  [ "$(ui_width "$s")" -le "$max" ] && { printf '%s' "$s"; return; }
  while [ -n "$s" ] && [ "$(ui_width "$s")" -gt $((max - 3)) ]; do s="${s%?}"; done
  printf '%s...' "$s"
}

ip_is_json() { [ -n "$1" ] && jq -e . >/dev/null 2>&1 <<<"$1"; }

# ip_json_read 数组名 JSON 键=jq路径…：一次 jq 取出多个字段写入关联数组（null 记为空）
ip_json_read() {
  local arr="$1" json="$2" kv filter=""
  shift 2
  local -a names=()
  for kv in "$@"; do
    names+=("$arr[${kv%%=*}]")
    filter+="${filter:+,}(${kv#*=})"
  done
  IFS=$'\x1f' read -r "${names[@]}" < <(jq -r "[$filter] | map(if . == null then \"\" else tostring end) | join(\"\u001f\")" <<<"$json" 2>/dev/null)
}

# 任一为 true 记 true，全部为 false 记 false，否则未知
ip_any_true() {
  local v all_false=1
  for v in "$@"; do
    [ "$v" = true ] && { echo true; return; }
    [ "$v" = false ] || all_false=0
  done
  [ "$all_false" -eq 1 ] && echo false
}

ip_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# 作者仓库的参考文件（iso3166.json / cookies.txt / dnsbl.list）：GitHub 不通时走 jsDelivr
ip_ref_url() {
  if [ -z "$IP_RAW" ]; then
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 https://www.google.com/generate_204 2>/dev/null)" = 204 ]; then
      IP_RAW="https://github.com/xykt/IPQuality/raw/"
    else
      IP_RAW="https://testingcf.jsdelivr.net/gh/xykt/IPQuality@"
    fi
  fi
  printf '%smain/ref/%s' "$IP_RAW" "$1"
}

# 经纬度 → 度分秒（ASCII）
ip_dms() {
  awk -v lat="$1" -v lon="$2" '
    function f(v, p, n,   h, d, m, s) {
      h = (v < 0) ? n : p; if (v < 0) v = -v
      d = int(v); m = int((v - d) * 60); s = sprintf("%.0f", ((v - d) * 60 - m) * 60)
      return d "d" m "\x27" s "\"" h
    }
    BEGIN { print f(lon, "E", "W") ", " f(lat, "N", "S") }'
}

ip_map_url() {
  local lat="$1" lon="$2" rad="$3" zoom=15
  if [ "$rad" -gt 1000 ]; then zoom=12
  elif [ "$rad" -gt 500 ]; then zoom=13
  elif [ "$rad" -gt 250 ]; then zoom=14
  fi
  printf 'https://check.place/%s,%s,%s,cn' "$lat" "$lon" "$zoom"
}

# ==================== 类型 / 风险映射 ====================

ip_type_generic() {
  local v="${1,,}"
  case "$v" in
    "") ;;
    business|isp|hosting|education|government|banking) printf '%s' "$v" ;;
    *) printf other ;;
  esac
}

ip_type_abuseipdb() {
  case "${1,,}" in
    "") ;;
    commercial) printf business ;;
    "data center/web hosting/transit") printf hosting ;;
    "university/college/school") printf education ;;
    government) printf government ;;
    banking) printf banking ;;
    organization) printf organization ;;
    military) printf military ;;
    library) printf library ;;
    "content delivery network") printf cdn ;;
    "fixed line isp") printf lineisp ;;
    "mobile isp") printf mobile ;;
    "search engine spider") printf spider ;;
    reserved) printf reserved ;;
    *) printf other ;;
  esac
}

ip_type_ip2location() {
  local c="${1%%/*}"
  case "${c^^}" in
    "") ;;
    COM) printf business ;;
    DCH) printf hosting ;;
    EDU) printf education ;;
    GOV) printf government ;;
    ORG) printf organization ;;
    MIL) printf military ;;
    LIB) printf library ;;
    CDN) printf cdn ;;
    ISP) printf lineisp ;;
    MOB) printf mobile ;;
    SES) printf spider ;;
    RSV) printf reserved ;;
    *) printf other ;;
  esac
}

ip_type_tag() {
  local bg="$BG_Y" txt
  case "$1" in
    isp|lineisp) bg="$BG_G"; txt=家宽 ;;
    mobile)      bg="$BG_G"; txt=手机 ;;
    hosting)     bg="$BG_R"; txt=机房 ;;
    cdn)         bg="$BG_R"; txt=CDN ;;
    spider)      bg="$BG_R"; txt=蜘蛛 ;;
    business)     txt=商业 ;;
    education)    txt=教育 ;;
    government)   txt=政府 ;;
    banking)      txt=银行 ;;
    organization) txt=组织 ;;
    military)     txt=军队 ;;
    library)      txt=图书馆 ;;
    reserved)     txt=保留 ;;
    other)        txt=其他 ;;
    *) ui_na; return ;;
  esac
  printf '%s%s%s %s %s' "$bg" "$C_W" "$C_BOLD" "$txt" "$C_0"
}

ip_risk_tag() {
  local c txt
  case "$1" in
    verylow)    c="$C_G"; txt=极低风险 ;;
    low)        c="$C_G"; txt=低风险 ;;
    medium)     c="$C_Y"; txt=中风险 ;;
    elevated)   c="$C_Y"; txt=较高风险 ;;
    suspicious) c="$C_Y"; txt=可疑IP ;;
    high)       c="$C_R"; txt=高风险 ;;
    veryhigh)   c="$C_R"; txt=极高风险 ;;
    risky)      c="$C_R"; txt=存在风险 ;;
    highrisk)   c="$C_R"; txt=高风险 ;;
    dos)        c="$C_R"; txt=建议封禁 ;;
    *) ui_na; return ;;
  esac
  printf '%s%s%s%s' "$c" "$C_BOLD" "$txt" "$C_0"
}

# ==================== 数据库查询 ====================

ip_db_maxmind() {
  local resp f
  local -A en=()
  local -a fields=(asn=.ASN.AutonomousSystemNumber org=.ASN.AutonomousSystemOrganization
    city=.City.Name post=.City.PostalCode lat=.City.Latitude lon=.City.Longitude rad=.City.AccuracyRadius
    continentcode=.City.Continent.Code continent=.City.Continent.Name timezone=.City.Location.TimeZone
    sub='.City.Subdivisions[0].Name' countrycode=.Country.IsoCode country=.Country.Name
    regcountrycode=.Country.RegisteredCountry.IsoCode regcountry=.Country.RegisteredCountry.Name)
  IP_MM=()
  resp=$(curl -Ls "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?lang=cn")
  ip_is_json "$resp" || return 1
  ip_json_read IP_MM "$resp" "${fields[@]}"
  IP_MM[ok]=1
  # 中文缺失的字段用英文结果补齐
  for f in "${fields[@]}"; do
    [ -n "${IP_MM[${f%%=*}]}" ] && continue
    resp=$(curl -Ls "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?lang=en")
    ip_is_json "$resp" || break
    ip_json_read en "$resp" "${fields[@]}"
    for f in "${!en[@]}"; do [ -z "${IP_MM[$f]}" ] && IP_MM[$f]="${en[$f]}"; done
    break
  done
}

ip_db_ipinfo() {
  local resp
  IP_INFO=()
  resp=$(curl -Ls -m 10 "https://ipinfo.io/widget/demo/$IP_ADDR")
  ip_is_json "$resp" || return 1
  ip_json_read IP_INFO "$resp" use=.data.asn.type com=.data.company.type countrycode=.data.country \
    proxy=.data.privacy.proxy tor=.data.privacy.tor vpn=.data.privacy.vpn server=.data.privacy.hosting \
    asn=.data.asn.asn org=.data.asn.name city=.data.city post=.data.postal timezone=.data.timezone \
    loc=.data.loc regcountrycode=.data.abuse.country
  IP_INFO[asn]="${IP_INFO[asn]#AS}"
  if [[ "${IP_INFO[loc]}" == *,* ]]; then
    IP_INFO[lat]="${IP_INFO[loc]%%,*}"
    IP_INFO[lon]="${IP_INFO[loc]#*,}"
  fi
  IP_INFO[use]=$(ip_type_generic "${IP_INFO[use]}")
  IP_INFO[com]=$(ip_type_generic "${IP_INFO[com]}")
}

ip_db_scamalytics() {
  local resp s
  IP_SCAM=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=scamalytics")
  ip_is_json "$resp" || return 1
  ip_json_read IP_SCAM "$resp" countrycode=.external_datasources.maxmind_geolite2.ip_country_code \
    proxy=.external_datasources.firehol.is_proxy tor=.external_datasources.x4bnet.is_tor \
    vpn=.scamalytics.scamalytics_proxy.is_vpn server=.scamalytics.scamalytics_proxy.is_datacenter \
    abuser=.scamalytics.is_blacklisted_external r1=.external_datasources.x4bnet.is_blacklisted_spambot \
    r2=.external_datasources.x4bnet.is_bot_operamini r3=.external_datasources.x4bnet.is_bot_semrush \
    score=.scamalytics.scamalytics_score
  IP_SCAM[robot]=$(ip_any_true "${IP_SCAM[r1]}" "${IP_SCAM[r2]}" "${IP_SCAM[r3]}")
  s="${IP_SCAM[score]}"
  ip_is_int "$s" || return
  if [ "$s" -lt 20 ]; then IP_SCAM[risk]=low
  elif [ "$s" -lt 60 ]; then IP_SCAM[risk]=medium
  elif [ "$s" -lt 90 ]; then IP_SCAM[risk]=high
  else IP_SCAM[risk]=veryhigh
  fi
}

ip_db_ipregistry() {
  local html resp key="sb69ksjcajfs4c"
  IP_REG=()
  html=$(curl -sL "-$IP_FAM" -m 10 -H "User-Agent: $UA_BROWSER" "https://ipregistry.co")
  [[ "$html" =~ apiKey=\"([a-zA-Z0-9]+)\" ]] && key="${BASH_REMATCH[1]}"
  resp=$(curl -sS "-$IP_FAM" --compressed -m 10 \
    -H "authority: api.ipregistry.co" -H "origin: https://ipregistry.co" -H "referer: https://ipregistry.co/" \
    -H "User-Agent: $UA_BROWSER" "https://api.ipregistry.co/$IP_ADDR?hostname=true&key=$key" 2>/dev/null)
  ip_is_json "$resp" || return 1
  ip_json_read IP_REG "$resp" use=.connection.type com=.company.type countrycode=.location.country.code \
    proxy=.security.is_proxy tor1=.security.is_tor tor2=.security.is_tor_exit vpn=.security.is_vpn \
    server=.security.is_cloud_provider abuser=.security.is_abuser
  IP_REG[tor]=$(ip_any_true "${IP_REG[tor1]}" "${IP_REG[tor2]}")
  IP_REG[use]=$(ip_type_generic "${IP_REG[use]}")
  IP_REG[com]=$(ip_type_generic "${IP_REG[com]}")
}

ip_db_ipapi() {
  local resp num
  IP_API=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=ipapi")
  ip_is_json "$resp" || return 1
  ip_json_read IP_API "$resp" use=.asn.type com=.company.type scoretext=.company.abuser_score \
    countrycode=.location.country_code proxy=.is_proxy tor=.is_tor vpn=.is_vpn \
    server=.is_datacenter abuser=.is_abuser robot=.is_crawler
  IP_API[use]=$(ip_type_generic "${IP_API[use]}")
  IP_API[com]=$(ip_type_generic "${IP_API[com]}")
  # abuser_score 形如 "0.0078 (Low)"
  num="${IP_API[scoretext]%% *}"
  [[ "$num" =~ ^[0-9]*\.?[0-9]+$ ]] || return
  IP_API[score]=$(awk -v n="$num" 'BEGIN { printf "%.2f%%", n * 100 }')
  IP_API[bar]=$(awk -v n="$num" 'BEGIN { printf "%d", n * 10000 + 1e-6 }')
  case "${IP_API[scoretext],,}" in
    *"(very low)"*)  IP_API[risk]=verylow ;;
    *"(low)"*)       IP_API[risk]=low ;;
    *"(elevated)"*)  IP_API[risk]=elevated ;;
    *"(high)"*)      IP_API[risk]=high ;;
    *"(very high)"*) IP_API[risk]=veryhigh ;;
  esac
}

ip_db_abuseipdb() {
  local resp s
  IP_ABUSE=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=abuseipdb")
  ip_is_json "$resp" || return 1
  ip_json_read IP_ABUSE "$resp" use=.data.usageType score=.data.abuseConfidenceScore
  IP_ABUSE[use]=$(ip_type_abuseipdb "${IP_ABUSE[use]}")
  s="${IP_ABUSE[score]}"
  ip_is_int "$s" || return
  if [ "$s" -lt 25 ]; then IP_ABUSE[risk]=low
  elif [ "$s" -lt 75 ]; then IP_ABUSE[risk]=high
  else IP_ABUSE[risk]=dos
  fi
}

ip_db_ip2location() {
  local resp s
  IP_I2L=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=ip2location")
  ip_is_json "$resp" || return 1
  ip_json_read IP_I2L "$resp" use=.usage_type com=.as_info.as_usage_type countrycode=.country_code \
    p0=.is_proxy p1=.proxy.is_public_proxy p2=.proxy.is_web_proxy tor=.proxy.is_tor vpn=.proxy.is_vpn \
    server=.proxy.is_data_center abuser=.proxy.is_spammer r1=.proxy.is_web_crawler \
    r2=.proxy.is_scanner r3=.proxy.is_botnet score=.fraud_score
  IP_I2L[proxy]=$(ip_any_true "${IP_I2L[p0]}" "${IP_I2L[p1]}" "${IP_I2L[p2]}")
  IP_I2L[robot]=$(ip_any_true "${IP_I2L[r1]}" "${IP_I2L[r2]}" "${IP_I2L[r3]}")
  IP_I2L[use]=$(ip_type_ip2location "${IP_I2L[use]}")
  IP_I2L[com]=$(ip_type_ip2location "${IP_I2L[com]}")
  s="${IP_I2L[score]}"
  ip_is_int "$s" || return
  if [ "$s" -lt 33 ]; then IP_I2L[risk]=low
  elif [ "$s" -lt 66 ]; then IP_I2L[risk]=medium
  else IP_I2L[risk]=high
  fi
}

# DB-IP 只能查询请求方自身（/self），因此按协议族发起请求
ip_db_dbip() {
  local resp key ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
  IP_DBIP=()
  resp=$(curl -sL "-$IP_FAM" -m 10 -H 'accept: */*' -H 'accept-language: en-US,en;q=0.9' \
    -H 'content-type: text/html;charset=UTF-8' -H 'dnt: 1' -H "user-agent: $ua" "https://db-ip.com/api/core/")
  key=$(sed -n 's/.*data-api-key="\([^"]*\)".*/\1/p' <<<"$resp" | head -n 1)
  resp=$(curl -sL "-$IP_FAM" -m 10 -H 'accept: */*' -H 'accept-language: en-US,en;q=0.9' \
    -H 'content-type: text/plain;charset=UTF-8' -H 'dnt: 1' -H 'origin: https://db-ip.com' \
    -H 'priority: u=1, i' -H 'referer: https://db-ip.com/' \
    -H 'sec-ch-ua: "Not=A?Brand";v="99", "Google Chrome";v="151", "Chromium";v="151"' \
    -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' -H 'sec-fetch-dest: empty' \
    -H 'sec-fetch-mode: cors' -H 'sec-fetch-site: same-site' -H "user-agent: $ua" \
    --data-raw '[["11.49","EUR"],["139.90","EUR"],["699.90","EUR"]]' \
    "https://api.db-ip.com/v2/$key/self?convertCurrencies")
  ip_is_json "$resp" || return 1
  ip_json_read IP_DBIP "$resp" robot=.isCrawler proxy=.isProxy risktext=.threatLevel countrycode=.countryCode
  case "${IP_DBIP[risktext],,}" in
    low)    IP_DBIP[risk]=low;    IP_DBIP[score]=0 ;;
    medium) IP_DBIP[risk]=medium; IP_DBIP[score]=50 ;;
    high)   IP_DBIP[risk]=high;   IP_DBIP[score]=100 ;;
  esac
}

ip_db_ipdata() {
  local resp
  IP_DATA=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=ipdata")
  ip_is_json "$resp" || return 1
  ip_json_read IP_DATA "$resp" countrycode=.country_code proxy=.threat.is_proxy tor=.threat.is_tor \
    server=.threat.is_datacenter a1=.threat.is_threat a2=.threat.is_known_abuser a3=.threat.is_known_attacker
  IP_DATA[abuser]=$(ip_any_true "${IP_DATA[a1]}" "${IP_DATA[a2]}" "${IP_DATA[a3]}")
}

ip_db_ipqs() {
  local resp s
  IP_QS=()
  resp=$(curl -sL "-$IP_FAM" -m 10 "https://ipinfo.check.place/$IP_ADDR?db=ipqualityscore")
  ip_is_json "$resp" || return 1
  ip_json_read IP_QS "$resp" score=.fraud_score countrycode=.country_code proxy=.proxy tor=.tor \
    vpn=.vpn abuser=.recent_abuse robot=.bot_status
  s="${IP_QS[score]}"
  ip_is_int "$s" || return
  if [ "$s" -lt 75 ]; then IP_QS[risk]=low
  elif [ "$s" -lt 85 ]; then IP_QS[risk]=suspicious
  elif [ "$s" -lt 90 ]; then IP_QS[risk]=risky
  else IP_QS[risk]=highrisk
  fi
}

# 整体进度：10 个数据库 + 7 项解锁 + 邮局 + 黑名单（仅 IPv4）
ip_step() {
  IP_STEP=$((IP_STEP + 1))
  ui_prog "IPv$IP_FAM $1" "$IP_STEP" "$IP_STEPS"
}

ip_query_dbs() {
  local item
  for item in Maxmind:maxmind IPinfo:ipinfo Scamalytics:scamalytics ipregistry:ipregistry ipapi:ipapi \
              AbuseIPDB:abuseipdb IP2Location:ip2location DB-IP:dbip ipdata:ipdata IPQS:ipqs; do
    ip_step "正在查询 IP 数据库：${item%%:*}"
    "ip_db_${item#*:}"
  done
}

# ==================== 流媒体及 AI 解锁 ====================

# 以下 ip_dns_* 输出 0 表示疑似 DNS 解锁，1 表示原生
ip_dns_check_ip() {
  local ip="$1" srv="$2"
  if is_ipv4 "$ip"; then
    case "$ip" in 10.*|192.168.*|169.254.*) echo 0; return ;; esac
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && { echo 0; return; }
    is_ipv4 "$srv" && [ "${ip%.*}" = "${srv%.*}" ] && { echo 0; return; }
    echo 1
  elif [[ "$ip" == *[0-9a-fA-F]:* ]]; then
    case "${ip,,}" in fe8*|fc*|fd*|ff*) echo 0 ;; *) echo 1 ;; esac
  else
    echo 1
  fi
}

# 解析结果是否为内网地址或与 DNS 服务器同网段
ip_dns_1() {
  local -a w
  local i ip=""
  read -r -a w <<<"$(nslookup "$1" 2>/dev/null | tr '\n' ' ')"
  for i in "${!w[@]}"; do
    [ "${w[i]}" = "Name:" ] && { ip="${w[i+3]}"; break; }
  done
  ip_dns_check_ip "$ip" "${w[1]}"
}

# 应答记录过少
ip_dns_2() {
  local n
  n=$(dig "$1" 2>/dev/null | grep -o 'ANSWER: [0-9]*')
  case "${n#ANSWER: }" in 0|1|2) echo 0 ;; *) echo 1 ;; esac
}

# 随机子域名也能解析（泛解析劫持）
ip_dns_3() {
  local n
  n=$(dig "test$RANDOM$RANDOM.$1" 2>/dev/null | grep -o 'ANSWER: [0-9]*')
  n="${n#ANSWER: }"
  if [ -z "$n" ] || [ "$n" = 0 ]; then echo 1; else echo 0; fi
}

ip_unlock_type() {
  local r
  for r in "$@"; do [ "$r" = 0 ] && { echo dns; return; }; done
  echo native
}

# ip_media_set 服务 状态 [地区] [方式]
ip_media_set() {
  IP_MEDIA[$1.s]="$2"
  IP_MEDIA[$1.r]="${3:-}"
  IP_MEDIA[$1.t]="${4:-}"
}

ip_media_tiktok() {
  local f="$IP_FAM" type html url=https://www.tiktok.com region st=yes
  type=$(ip_unlock_type "$(ip_dns_1 tiktok.com)" "$(ip_dns_3 tiktok.com)")
  html=$(curl "-$f" -A "$UA_BROWSER" -sL -m 10 "https://www.tiktok.com/")
  if [[ "$html" == *"Please wait..."* ]]; then
    url+=/explore
    html=$(curl "-$f" -A "$UA_BROWSER" -sL -m 10 "$url")
  fi
  region=$(tr '\n' ' ' <<<"$html" | grep '"region":' | sed 's/.*"region"//' | cut -f2 -d'"')
  if [ -z "$region" ]; then
    st=idc
    html=$(curl "-$f" -A "$UA_BROWSER" -sL -m 10 \
      -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9" \
      -H "Accept-Encoding: gzip" -H "Accept-Language: en" "$url" | gunzip 2>/dev/null)
    region=$(tr '\n' ' ' <<<"$html" | grep '"region":' | sed 's/.*"region"//' | cut -f2 -d'"')
  fi
  if [ -n "$region" ]; then ip_media_set tiktok "$st" "$region" "$type"; else ip_media_set tiktok bad; fi
}

ip_media_disney() {
  local f="$IP_FAM" type pre assertion body token refresh gql preview region supported
  type=$(ip_unlock_type "$(ip_dns_1 disneyplus.com)" "$(ip_dns_3 disneyplus.com)")
  [ -n "$IP_COOKIE" ] || IP_COOKIE=$(curl -fsL --retry 3 -m 10 "$(ip_ref_url cookies.txt)")
  pre=$(curl "-$f" -A "$UA_BROWSER" -s -m 10 -X POST "https://disney.api.edge.bamgrid.com/devices" \
    -H "authorization: Bearer $IP_DISNEY_AUTH" -H "content-type: application/json; charset=UTF-8" \
    -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>&1)
  ip_is_json "$pre" || { ip_media_set disney bad; return; }
  assertion=$(jq -r '.assertion' <<<"$pre")
  body=$(sed -n 1p <<<"$IP_COOKIE")
  body="${body//DISNEYASSERTION/"$assertion"}"
  token=$(curl "-$f" -A "$UA_BROWSER" -s -m 10 -X POST "https://disney.api.edge.bamgrid.com/token" \
    -H "authorization: Bearer $IP_DISNEY_AUTH" -d "$body" 2>&1)
  if [ -n "$(jq -r 'select(.error_description == "forbidden-location") | .error_description' <<<"$token" 2>/dev/null)" ] \
    || [[ "$token" == *"403 ERROR"* ]]; then
    ip_media_set disney no
    return
  fi
  refresh=$(jq -r '.refresh_token' <<<"$token" 2>/dev/null)
  body=$(sed -n 8p <<<"$IP_COOKIE")
  body="${body//ILOVEDISNEY/"$refresh"}"
  gql=$(curl "-$f" -A "$UA_BROWSER" -X POST -sSL -m 10 "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
    -H "authorization: $IP_DISNEY_AUTH" -d "$body" 2>&1)
  ip_is_json "$gql" || { ip_media_set disney bad; return; }
  preview=$(curl "-$f" -s -o /dev/null -L -m 10 -w '%{url_effective}\n' "https://disneyplus.com" | grep preview)
  region=$(jq -r '.extensions.sdk.session.location.countryCode' <<<"$gql")
  supported=$(jq -r '.extensions.sdk.session.inSupportedLocation' <<<"$gql")
  if [ "$region" = JP ]; then
    ip_media_set disney yes JP "$type"
  elif [ -n "$region" ] && [ "$supported" = false ] && [[ "$preview" != *unavailable* ]]; then
    ip_media_set disney pending "$region" "$type"
  elif [ -n "$region" ] && [[ "$preview" == *unavailable* ]]; then
    ip_media_set disney no
  elif [ -n "$region" ] && [ "$supported" = true ]; then
    ip_media_set disney yes "$region" "$type"
  elif [ -z "$region" ]; then
    ip_media_set disney no
  else
    ip_media_set disney bad
  fi
}

ip_media_netflix() {
  local f="$IP_FAM" type r1 r2 region pat='s/.*"id":"\([^"]*\)".*"countryName":"[^"]*".*/\1/p'
  type=$(ip_unlock_type "$(ip_dns_1 netflix.com)" "$(ip_dns_2 netflix.com)" "$(ip_dns_3 netflix.com)")
  r1=$(curl "-$f" -A "$UA_BROWSER" -fsL -X GET -m 10 --tlsv1.3 "https://www.netflix.com/title/81280792" 2>&1)
  r2=$(curl "-$f" -A "$UA_BROWSER" -fsL -X GET -m 10 --tlsv1.3 "https://www.netflix.com/title/70143836" 2>&1)
  if [ -z "$r1" ] || [ -z "$r2" ]; then ip_media_set netflix bad; return; fi
  region=$(sed -n "$pat" <<<"$r1" | head -n 1)
  [ -n "$region" ] && region=$(sed -n "$pat" <<<"$r2" | head -n 1)
  # 两部非自制剧都不可看 → 仅自制剧
  if [[ "$r1" == *"Oh no!"* && "$r2" == *"Oh no!"* ]]; then
    ip_media_set netflix org "$region" "$type"
  else
    ip_media_set netflix yes "$region" "$type"
  fi
}

ip_media_youtube() {
  local f="$IP_FAM" type html region
  type=$(ip_unlock_type "$(ip_dns_1 www.youtube.com)" "$(ip_dns_3 www.youtube.com)")
  html=$(curl "-$f" -m 10 -sSL -H "Accept-Language: en" \
    -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; GPS=1; VISITOR_INFO1_LIVE=4VwPMkB7W5A; PREF=tz=Asia.Shanghai; _gcl_au=1.1.1809531354.1646633279" \
    "https://www.youtube.com/premium" 2>&1)
  if [[ "$html" == curl* ]]; then ip_media_set youtube bad; return; fi
  if [[ "$html" == *www.google.cn* ]]; then ip_media_set youtube cn CN; return; fi
  region=$(tr '\n' ' ' <<<"$html" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p')
  if [[ "$html" == *"Premium is not available in your country"* ]]; then
    ip_media_set youtube noprem
  elif [[ "$html" == *ad-free* ]]; then
    ip_media_set youtube yes "$region" "$type"
  else
    ip_media_set youtube bad
  fi
}

ip_media_prime() {
  local f="$IP_FAM" type html region
  type=$(ip_unlock_type "$(ip_dns_1 www.primevideo.com)" "$(ip_dns_3 www.primevideo.com)")
  html=$(curl "-$f" -A "$UA_BROWSER" -sL -m 10 "https://www.primevideo.com" 2>&1)
  if [ -z "$html" ] || [[ "$html" == curl* ]]; then ip_media_set prime bad; return; fi
  region=$(grep -oE '"currentTerritory":\s*"[A-Z]{2}"' <<<"$html" | head -n 1 | cut -d'"' -f4)
  if [ -n "$region" ]; then ip_media_set prime yes "$region" "$type"; else ip_media_set prime no; fi
}

ip_media_reddit() {
  local f="$IP_FAM" type resp code region="" v6
  local -a resolve=()
  type=$(ip_unlock_type "$(ip_dns_1 reddit.com)" "$(ip_dns_2 reddit.com)")
  if [ "$f" = 6 ]; then
    v6=$(dig AAAA reddit.com +short 2>/dev/null | head -n 1)
    [ -n "$v6" ] || v6=$(dig AAAA dualstack.reddit.map.fastly.net +short 2>/dev/null | head -n 1)
    [ -n "$v6" ] || { ip_media_set reddit bad; return; }
    resolve=(--resolve "www.reddit.com:443:[$v6]")
  fi
  resp=$(curl "-$f" -fsL -A "$UA_BROWSER" -m 10 "${resolve[@]}" --write-out '\n%{http_code}' \
    "https://www.reddit.com/svc/shreddit/reddit-chat")
  code=$(tail -n 1 <<<"$resp" | tr -d '\r')
  [ "$code" = 200 ] && region=$(sed '$d' <<<"$resp" | grep -oE 'country="[^"]+"' | sed -n 's/^country="\([^"]*\)"$/\1/p' | grep -m1 .)
  case "$code" in
    200) ip_media_set reddit yes "$region" "$type" ;;
    403) ip_media_set reddit no ;;
    *)   ip_media_set reddit bad ;;
  esac
}

ip_media_chatgpt() {
  local f="$IP_FAM" type t1 t2 r1="" r2="" code cc d
  local -a dns=()
  for d in chat.openai.com ios.chat.openai.com; do
    dns+=("$(ip_dns_1 "$d")" "$(ip_dns_2 "$d")" "$(ip_dns_3 "$d")")
  done
  dns+=("$(ip_dns_1 api.openai.com)" "$(ip_dns_3 api.openai.com)")
  type=$(ip_unlock_type "${dns[@]}")
  t1=$(curl "-$f" -sS -m 10 'https://api.openai.com/compliance/cookie_requirements' \
    -H 'authority: api.openai.com' -H 'accept: */*' -H 'accept-language: zh-CN,zh;q=0.9' \
    -H 'authorization: Bearer null' -H 'content-type: application/json' \
    -H 'origin: https://platform.openai.com' -H 'referer: https://platform.openai.com/' \
    -H "$IP_EDGE_SEC" -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' \
    -H 'sec-fetch-dest: empty' -H 'sec-fetch-mode: cors' -H 'sec-fetch-site: same-site' \
    -H "user-agent: $IP_EDGE_UA" 2>&1)
  t2=$(curl "-$f" -sS -m 10 'https://ios.chat.openai.com/' \
    -H 'authority: ios.chat.openai.com' \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
    -H 'accept-language: zh-CN,zh;q=0.9' -H "$IP_EDGE_SEC" -H 'sec-ch-ua-mobile: ?0' \
    -H 'sec-ch-ua-platform: "Windows"' -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' \
    -H 'sec-fetch-site: none' -H 'sec-fetch-user: ?1' -H 'upgrade-insecure-requests: 1' \
    -H "user-agent: $IP_EDGE_UA" 2>&1)
  [[ "$t1" == *unsupported_country* ]] && r1=1
  [[ "$t2" == *VPN* ]] && r2=1
  if [ -n "$r1" ]; then
    code=$(curl "-$f" -o /dev/null -sS -m 10 'https://chatgpt.com/favicon.ico' \
      -H 'accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8' \
      -H 'authority: chatgpt.com' -H 'accept: */*' -H 'accept-language: zh-CN,zh;q=0.9' \
      -H 'authorization: Bearer null' -H 'content-type: application/json' \
      -H 'origin: https://chatgpt.com' -H 'referer: https://chatgpt.com/' \
      -H "$IP_EDGE_SEC" -H 'sec-ch-ua-mobile: ?0' -H 'sec-ch-ua-platform: "Windows"' \
      -H 'sec-fetch-dest: empty' -H 'sec-fetch-mode: cors' -H 'sec-fetch-site: same-site' \
      -H "user-agent: $IP_EDGE_UA" -w '%{http_code}' 2>&1)
    [ "$code" != 403 ] && r1=""
  fi
  cc=$(curl "-$f" -m 10 -sS "https://chat.openai.com/cdn-cgi/trace" 2>&1 | grep '^loc=' | cut -d= -f2)
  if [ -z "$r1" ] && [ -z "$r2" ] && [[ "$t1" != curl* ]] && [[ "$t2" != curl* ]]; then
    ip_media_set chatgpt yes "$cc" "$type"
  elif [ -n "$r1" ] && [ -n "$r2" ]; then
    ip_media_set chatgpt no
  elif [ -z "$r1" ] && [ -n "$r2" ] && [[ "$t1" != curl* ]]; then
    ip_media_set chatgpt web "$cc" "$type"
  elif [ -n "$r1" ] && [ -z "$r2" ]; then
    ip_media_set chatgpt app "$cc" "$type"
  elif [[ "$t1" == curl* ]] && [ -n "$r2" ]; then
    ip_media_set chatgpt no
  elif [ "$f" = 6 ] && [ -z "$r2" ] && [[ "$t2" != curl* ]]; then
    ip_media_set chatgpt yes "$cc" "$type"
  else
    ip_media_set chatgpt bad
  fi
}

ip_query_media() {
  local item
  IP_MEDIA=()
  for item in TikTok:tiktok Disney+:disney Netflix:netflix YouTube:youtube "Prime Video:prime" Reddit:reddit ChatGPT:chatgpt; do
    ip_step "正在检测解锁：${item%%:*}"
    "ip_media_${item#*:}"
  done
}

# ==================== 邮局 / 黑名单 ====================

ip_check_mail() {
  local f="$IP_FAM" out="$WORKDIR/ip_mail_$IP_FAM" svc resp
  local -a src=() pids=()
  IP_MAIL=()
  ip_step "正在检测邮局连通性"
  # 只看本地端口为 25 的连接，避免把刚结束的出站 25 连接（TIME-WAIT）误判为占用
  if command -v ss >/dev/null 2>&1 && ss -tan 'sport = :25' 2>/dev/null | tail -n +2 | grep -q .; then
    IP_MAIL[local]=occupied
  else
    # 绑定源端口 25 需要 root
    [ "$IS_ROOT" -eq 1 ] && src=(-p 25)
    resp=$(printf 'QUIT\r\n' | run_to 10 nc "-$f" "${src[@]}" -w 9 smtp.mailgun.org 25 2>&1)
    [[ "$resp" == *220* ]] && IP_MAIL[local]=yes || IP_MAIL[local]=no
  fi
  : >"$out"
  for svc in "${IP_MAIL_SVCS[@]}"; do
    (
      host=$(dig +short MX "${IP_MAIL_DOMAIN[$svc]}" 2>/dev/null | sort -n | head -n 1 | awk '{print $2}')
      [ -n "$host" ] || exit 0
      resp=$(printf 'QUIT\r\n' | run_to 5 nc "-$f" -w 4 "$host" 25 2>&1)
      [[ "$resp" == *220* ]] && echo "$svc" >>"$out"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  IP_MAIL[remote]=0
  for svc in "${IP_MAIL_SVCS[@]}"; do
    if grep -qx "$svc" "$out"; then IP_MAIL[$svc]=1; IP_MAIL[remote]=1; else IP_MAIL[$svc]=0; fi
  done
}

# ip_dnsbl_query 并发数 反转IP < 库列表：每行输出「结果 库名」，结果 C 正常 / M 已标记 / B 黑名单 / T 超时
ip_dnsbl_query() {
  xargs -P "$1" -I {} bash -c '
    r=$(dig +short "$1.$2" A 2>/dev/null)
    if [[ "$r" == *";;"* ]]; then echo "T $2"
    elif [ -z "$r" ] || [[ "$r" =~ ^127\.255\.255\. ]]; then echo "C $2"
    elif [ "$r" = 127.0.0.2 ]; then echo "B $2"
    else echo "M $2"; fi' _ "$2" {}
}

# 输出：总数 正常 已标记 黑名单 超时（dig 报错不计入已标记）
# 第一遍 50 并发（同原版）；超时的库多因解析器一时处理不过来或缓存未热，第一遍结束后以 10 并发重查一次
ip_check_dnsbl() {
  local list="$WORKDIR/ip_dnsbl.list" res="$WORKDIR/ip_dnsbl.res" rev
  ip_step "正在检测 DNS 黑名单（400+ 个库）"
  [ -s "$list" ] || curl -fsL -m 20 "$(ip_ref_url dnsbl.list)" | tr -d '\r' | grep -v '^[[:space:]]*$' | sort -u >"$list"
  rev=$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$IP_ADDR")
  ip_dnsbl_query 50 "$rev" <"$list" >"$res"
  if grep -q '^T ' "$res"; then
    { grep -v '^T ' "$res"; awk '$1 == "T" { print $2 }' "$res" | ip_dnsbl_query 10 "$rev"; } >"$res.2"
    mv "$res.2" "$res"
  fi
  awk '{ n[$1]++ } END { printf "%d %d %d %d %d\n", NR, n["C"], n["M"], n["B"], n["T"] }' "$res"
}

# ==================== 输出 ====================

# 表格行：  键（青色）+ 若干定宽居中列
ip_row() {
  local key="$1" kw="$2" line
  shift 2
  line="  $C_C$(ui_pad "$key" "$kw")$C_0"
  while [ $# -ge 2 ]; do
    line+=$(ui_pad "$2" "$1" c)
    shift 2
  done
  printf '%s\n' "${line%"${line##*[! ]}"}"
}

ip_show_basic() {
  local -A b=()
  local k v note="Maxmind 数据库" iso city
  if [ "${IP_MM[ok]}" = 1 ]; then
    for k in "${!IP_MM[@]}"; do b[$k]="${IP_MM[$k]}"; done
    [ -n "${b[continentcode]}" ] && b[continent]="[${b[continentcode]}]${b[continent]}"
  elif [ -n "${IP_INFO[countrycode]}${IP_INFO[asn]}" ]; then
    # Maxmind 不可用时退回 IPinfo（国家名、洲际取自作者仓库的 iso3166.json）
    note="IPinfo 数据库"
    for k in "${!IP_INFO[@]}"; do b[$k]="${IP_INFO[$k]}"; done
    iso=$(curl -sL -m 10 "$(ip_ref_url iso3166.json)")
    if ip_is_json "$iso"; then
      b[country]=$(jq -r --arg c "${b[countrycode]}" '.[] | select(.["alpha-2"] == $c) | .name' <<<"$iso")
      b[continent]=$(jq -r --arg c "${b[countrycode]}" '.[] | select(.["alpha-2"] == $c) | .region' <<<"$iso")
      b[regcountry]=$(jq -r --arg c "${b[regcountrycode]}" '.[] | select(.["alpha-2"] == $c) | .name' <<<"$iso")
    fi
    b[rad]=1001
  else
    ui_sub "基础信息"
    ui_kv "IP 地址" "$IP_ADDR"
    ui_warn "Maxmind 与 IPinfo 均查询失败"
    return
  fi

  ui_sub "基础信息（$C_I$note$C_0$C_BOLD$C_C）"
  ui_kv "IP 地址" "$C_G$IP_ADDR$C_0"
  if [ -n "${b[asn]}" ]; then
    ui_kv "自治系统" "${C_G}AS${b[asn]}$C_0"
    ui_kv "组织" "$C_G$(ip_fit "${b[org]:--}" 64)$C_0"
  else
    ui_kv "自治系统" "未分配"
  fi
  if [ -n "${b[lat]}" ] && [ -n "${b[lon]}" ]; then
    ui_kv "坐标" "$C_G$(ip_dms "${b[lat]}" "${b[lon]}")$C_0"
    ip_is_int "${b[rad]}" && ui_kv "地图" "$C_G$(ip_map_url "${b[lat]}" "${b[lon]}" "${b[rad]}")$C_0"
  fi
  city=""
  for k in sub city post; do
    [ -n "${b[$k]}" ] && city+="${city:+, }${b[$k]}"
  done
  [ -n "$city" ] && ui_kv "城市" "$C_G$(ip_fit "$city" 64)$C_0"
  if [ -n "${b[countrycode]}" ]; then
    v="[${b[countrycode]}]${b[country]}"
    [ -n "${b[continent]}" ] && v+=", ${b[continent]}"
    ui_kv "使用地" "$C_G$(ip_fit "$v" 64)$C_0"
  elif [ -n "${b[continent]}" ]; then
    ui_kv "洲际" "$C_G${b[continent]}$C_0"
  fi
  [ -n "${b[regcountrycode]}" ] && ui_kv "注册地" "$C_G$(ip_fit "[${b[regcountrycode]}]${b[regcountry]}" 64)$C_0"
  [ -n "${b[timezone]}" ] && ui_kv "时区" "$C_G${b[timezone]}$C_0"
  if [ -n "${b[countrycode]}" ]; then
    if [ "${b[countrycode]}" = "${b[regcountrycode]}" ]; then
      ui_kv "IP 属性" "$BG_G$C_W$C_BOLD 原生IP $C_0"
    else
      ui_kv "IP 属性" "$BG_R$C_W$C_BOLD 广播IP $C_0"
    fi
  fi
}

ip_show_type() {
  local w=12
  ui_sub "IP 类型"
  ip_row "数据库" "$UI_KEY_W" $w "$C_C${C_I}IPinfo$C_0" $w "$C_C${C_I}ipregistry$C_0" $w "$C_C${C_I}ipapi$C_0" \
    $w "$C_C${C_I}IP2Location$C_0" $w "$C_C${C_I}AbuseIPDB$C_0"
  ip_row "使用类型" "$UI_KEY_W" $w "$(ip_type_tag "${IP_INFO[use]}")" $w "$(ip_type_tag "${IP_REG[use]}")" \
    $w "$(ip_type_tag "${IP_API[use]}")" $w "$(ip_type_tag "${IP_I2L[use]}")" $w "$(ip_type_tag "${IP_ABUSE[use]}")"
  ip_row "公司类型" "$UI_KEY_W" $w "$(ip_type_tag "${IP_INFO[com]}")" $w "$(ip_type_tag "${IP_REG[com]}")" \
    $w "$(ip_type_tag "${IP_API[com]}")" $w "$(ip_type_tag "${IP_I2L[com]}")" $w "$(ui_na)"
}

# ip_score_row 名称 显示文本 分值 低/中分界 中/高分界 满分 风险
# 刻度 48 列：绿 / 黄 / 红各 16 列。同原版：彩色只铺到分值所在位置（含末端的「|」），
# 分值落在分界点时进入下一段（如 AbuseIPDB 25 分已到红段）；「分值|」比彩色部分长时，
# 「|」仍在彩色末端，数字向左伸进键名后的空白；风险文字紧跟在彩条后面
ip_score_row() {
  local name="$1" text="$2" v="$3" p3="$4" p4="$5" p5="$6" risk="$7"
  local fill mark over room g y r left col
  if ! ip_is_int "$v"; then
    ui_kv "$name" "$(ui_na)"
    return
  fi
  if [ "$v" -ge "$p4" ]; then fill=$(( 33 + 15 * (v - p4) / (p5 - p4) ))
  elif [ "$v" -ge "$p3" ]; then fill=$(( 17 + 16 * (v - p3) / (p4 - p3) ))
  else fill=$(( 1 + 16 * v / p3 ))
  fi
  [ "$fill" -gt 48 ] && fill=48
  mark="$text|"
  over=$(( ${#mark} > fill ? ${#mark} - fill : 0 ))
  room=$(( UI_KEY_W - $(ui_width "$name") - 1 ))
  [ "$over" -gt "$room" ] && { mark="${mark:over-room}"; over=$room; }
  printf -v col '%*s' "$fill" "${mark:over}"
  left="${mark:0:over}"
  g=$(( fill < 16 ? fill : 16 ))
  y=$(( fill > 16 ? (fill < 32 ? fill - 16 : 16) : 0 ))
  r=$(( fill > 32 ? fill - 32 : 0 ))
  printf '  %s%s%s%*s%s%s%s%s%s%s%s%s%s%s\n' "$C_C" "$name" "$C_0" $(( UI_KEY_W - $(ui_width "$name") - over )) '' \
    "$C_W$C_BOLD" "$left" "$BG_G" "${col:0:g}" "$BG_Y" "${col:g:y}" "$BG_R" "${col:g+y:r}" "$C_0" "$(ip_risk_tag "$risk")"
}

ip_show_score() {
  ui_sub "风险评分"
  ui_kv "风险等级" "$C_I$C_W$BG_G极低         低 $BG_Y$(ui_pad 中等 16 c)$BG_R 高         极高$C_0"
  ip_score_row IP2Location "${IP_I2L[score]}" "${IP_I2L[score]}" 33 66 99 "${IP_I2L[risk]}"
  ip_score_row Scamalytics "${IP_SCAM[score]}" "${IP_SCAM[score]}" 20 60 100 "${IP_SCAM[risk]}"
  ip_score_row ipapi "${IP_API[score]}" "${IP_API[bar]}" 85 300 10000 "${IP_API[risk]}"
  ip_score_row AbuseIPDB "${IP_ABUSE[score]}" "${IP_ABUSE[score]}" 25 25 100 "${IP_ABUSE[risk]}"
  ip_score_row IPQS "${IP_QS[score]}" "${IP_QS[score]}" 75 85 100 "${IP_QS[risk]}"
  ip_score_row DB-IP "" "${IP_DBIP[score]}" 33 66 100 "${IP_DBIP[risk]}"
}

ip_factor_cell() {
  case "$1" in
    true)  printf '%s%s是%s' "$C_R" "$C_BOLD" "$C_0" ;;
    false) printf '%s%s否%s' "$C_G" "$C_BOLD" "$C_0" ;;
    *)
      if [[ "$1" =~ ^[A-Za-z]{2}$ ]]; then printf '%s[%s]%s' "$C_G" "$1" "$C_0"; else ui_na; fi ;;
  esac
}

ip_show_factor() {
  local -a names=(IP2Location ipapi ipregistry IPQS Scamalytics ipdata IPinfo DB-IP)
  local -a arrs=(IP_I2L IP_API IP_REG IP_QS IP_SCAM IP_DATA IP_INFO IP_DBIP)
  local -a keys=(countrycode proxy tor vpn server abuser robot) labels=(地区 代理 Tor VPN 服务器 滥用 机器人)
  local -a cols
  local i j w ref
  ui_sub "风险因子"
  cols=()
  for i in "${!names[@]}"; do
    w=$(( ${#names[i]} > 4 ? ${#names[i]} + 1 : 5 ))
    cols+=("$w" "$C_C$C_I${names[i]}$C_0")
  done
  ip_row "库" 8 "${cols[@]}"
  for j in "${!keys[@]}"; do
    cols=()
    for i in "${!names[@]}"; do
      w=$(( ${#names[i]} > 4 ? ${#names[i]} + 1 : 5 ))
      ref="${arrs[i]}[${keys[j]}]"
      cols+=("$w" "$(ip_factor_cell "${!ref}")")
    done
    ip_row "${labels[j]}" 8 "${cols[@]}"
  done
}

ip_media_tag() {
  local bg="$BG_Y" txt
  case "$1" in
    yes)     bg="$BG_G"; txt=解锁 ;;
    native)  bg="$BG_G"; txt=原生 ;;
    no)      bg="$BG_R"; txt=屏蔽 ;;
    bad)     bg="$BG_R"; txt=失败 ;;
    cn)      bg="$BG_R"; txt=中国 ;;
    noprem)  bg="$BG_R"; txt=禁会员 ;;
    pending) txt=待支持 ;;
    org)     txt=仅自制 ;;
    web)     txt=仅网页 ;;
    app)     txt=仅APP ;;
    idc)     txt=机房 ;;
    dns)     txt=DNS ;;
    *) ui_na; return ;;
  esac
  printf '%s%s %s %s' "$bg" "$C_W" "$txt" "$C_0"
}

ip_show_media() {
  local -a names=(TikTok Disney+ Netflix Youtube AmazonPV Reddit ChatGPT)
  local -a svcs=(tiktok disney netflix youtube prime reddit chatgpt)
  local -a head=() st=() rg=() ty=()
  local i w r c
  ui_sub "流媒体及 AI 解锁"
  for i in "${!svcs[@]}"; do
    w=$(( ${#names[i]} > 8 ? ${#names[i]} + 1 : 9 ))
    r="${IP_MEDIA[${svcs[i]}.r]}"
    c="$C_G"
    [ "$r" = CN ] && c="$C_R"
    head+=("$w" "$C_C$C_I${names[i]}$C_0")
    st+=("$w" "$(ip_media_tag "${IP_MEDIA[${svcs[i]}.s]}")")
    if [ -n "$r" ]; then rg+=("$w" "$c[$r]$C_0"); else rg+=("$w" "$(ui_na)"); fi
    ty+=("$w" "$(ip_media_tag "${IP_MEDIA[${svcs[i]}.t]}")")
  done
  ip_row "服务" 8 "${head[@]}"
  ip_row "状态" 8 "${st[@]}"
  ip_row "地区" 8 "${rg[@]}"
  ip_row "方式" 8 "${ty[@]}"
}

ip_show_mail() {
  local svc line="" n=0 key="邮局通信" v
  ui_sub "邮局连通性及黑名单检测"
  deps_ok dig nc || return
  ip_check_mail
  ui_prog_clear
  case "${IP_MAIL[local]}" in
    yes)      v="${C_G}可用$C_0" ;;
    occupied) v="${C_Y}占用$C_0" ;;
    *)        v="${C_R}阻断$C_0" ;;
  esac
  ui_kv "本地 25 端口" "$v"
  if [ "${IP_MAIL[remote]}" != 1 ]; then
    ui_kv "$key" "${C_R}远端 25 端口不可达$C_0"
    return
  fi
  # 每行 6 家，每格 9 列（符号 + 最长 7 字符的名称 + 空格）
  for svc in "${IP_MAIL_SVCS[@]}"; do
    if [ "${IP_MAIL[$svc]}" = 1 ]; then
      line+="$C_D+$C_0$BG_G$C_W$C_BOLD$svc$C_0"
    else
      line+="$C_D-$C_0$BG_R$C_W$C_BOLD$svc$C_0"
    fi
    line+=$(printf '%*s' $(( 8 - ${#svc} )) '')
    n=$((n + 1))
    if [ $((n % 6)) -eq 0 ]; then
      ui_kv "$key" "${line%"${line##*[! ]}"}"
      line=""
      key=""
    fi
  done
  [ -n "$line" ] && ui_kv "$key" "${line%"${line##*[! ]}"}"
}

ip_show_dnsbl() {
  local -a r
  local v
  # 只查 IPv4（同原版），与邮局同属一节
  [ "$IP_FAM" = 4 ] || return
  deps_ok dig || return
  read -r -a r <<<"$(ip_check_dnsbl)"
  ui_prog_clear
  if [ "${r[0]:-0}" -eq 0 ]; then
    ui_warn "黑名单列表下载失败"
    return
  fi
  v="${C_C}有效 ${C_BOLD}${r[0]}$C_0   ${C_G}正常 ${C_BOLD}${r[1]}$C_0   ${C_Y}已标记 ${C_BOLD}${r[2]}$C_0   ${C_R}黑名单 ${C_BOLD}${r[3]}$C_0"
  [ "${r[4]:-0}" -gt 0 ] && v+="   ${C_D}超时 ${r[4]}$C_0"
  ui_kv "黑名单库" "$v"
}

ip_run() {
  local UI_SUB_GAP=0
  IP_FAM="$1"
  if [ "$IP_FAM" = 6 ]; then IP_ADDR="$PUB6"; else IP_ADDR="$PUB4"; fi
  ui_section "IP 质量 · IPv$IP_FAM"
  if [ -z "$IP_ADDR" ]; then
    ui_warn "没有 IPv$IP_FAM 公网地址"
    return
  fi
  deps_ok curl jq || return

  IP_STEP=0
  IP_STEPS=18
  [ "$IP_FAM" = 4 ] && IP_STEPS=19
  ip_query_dbs
  ui_prog_clear
  ip_show_basic
  ip_show_type
  ip_show_score
  ip_show_factor

  ip_query_media
  ui_prog_clear
  ip_show_media

  ip_show_mail
  ip_show_dnsbl
}

# ==================== 模块：TCP 回程 ====================
# 移植自 ibsgss/TcpQuality（GPL-3.0）runTcpQuality-core.sh：
#   三网回程（nping SYN 测延迟/丢包 + traceroute 识别回程线路）、大包回程、教育网回程。
# 入口 tcp_run；读取 TCP_ROUTE / TCP_LARGE / TCP_EDU、RUN_V4 / RUN_V6、OPT_COUNT、OPT_PROVINCES。
# 只做本地探测，不上传任何结果；临时文件全部放在 $WORKDIR/tcp。

TCP_NODES_URL="${TCP_NODES_URL:-https://tcpquality.ibsgss.uk/getNodes}"
TCP_SNAPSHOT_DATE="2026-10-19"
TCP_PACKETS_DEFAULT=25
TCP_PACKETS=25
TCP_PARALLEL=16
TCP_DIR=""
TCP_PROVS=""          # 已选省份，格式 |北京||上海|；空表示全国
TCP_TRACE_TIMEOUT=240 # 单次路由追踪的保险超时（正常最坏约 180 秒：30 跳 x 3 探测 x 2 秒）
TCP_IDX=0             # 延迟/丢包任务序号（各组共用，结果文件 组名_序号）
TCP_PROBE_TOTAL=0
TCP_ROUTE_TOTAL=0
TCP_ROUTE_PID=""
TCP_STEP_ROUTE=""
TCP_STEP_PROBE=""

# 节点条目统一格式：省份|运营商|域名|IP|端口|备用域名|备用IP|备用端口（教育网运营商记为“教育网”）
TCP_CDN4=()
TCP_CDN6=()
TCP_CERNET=()
TCP_CERNET2=()

# 各子项开关（tcp_run 内计算）：P=延迟丢包探测，R=线路识别
TCP_DO_P4=0; TCP_DO_P6=0; TCP_DO_L=0; TCP_DO_E4=0; TCP_DO_E6=0
TCP_DO_R4=0; TCP_DO_R6=0; TCP_DO_LR=0; TCP_DO_ER4=0; TCP_DO_ER6=0

# 大包：小包 120-480B 与大包 900-1200B 混发，大包约占 3/4
TCP_LARGE_SMALL_SIZES=(120 240 480)
TCP_LARGE_BIG_SIZES=(900 950 1000 1050 1100 1150 1200 1200 900)
TCP_LARGE_PRE_DOMAIN="www.cloudflare.com"
TCP_LARGE_PRE_PACKETS=20
TCP_LARGE_PRE_SIZE=1200
TCP_LARGE_FW_LIMITED=0
TCP_LARGE_MODE=0
TCP_PSIZE=""          # 非空时固定包长（仅大包预检使用）
TCP_V6_PRE_PACKETS=3
TCP_V6_FORCE_L2=0
TCP_NOLABEL="未识别"  # 缺少 traceroute / nexttrace-tiny 时的线路占位

# ==================== 省份筛选 ====================

tcp_province_from_code() {
  local code="${1,,}"
  code=${code#-}
  case "$code" in
    he|河北) echo "河北" ;;
    sx|山西) echo "山西" ;;
    ln|辽宁) echo "辽宁" ;;
    jl|吉林) echo "吉林" ;;
    hl|黑龙江) echo "黑龙江" ;;
    js|江苏) echo "江苏" ;;
    zj|浙江) echo "浙江" ;;
    ah|安徽) echo "安徽" ;;
    fj|福建) echo "福建" ;;
    jx|江西) echo "江西" ;;
    sd|山东) echo "山东" ;;
    ha|河南) echo "河南" ;;
    hb|湖北) echo "湖北" ;;
    hn|湖南) echo "湖南" ;;
    gd|广东) echo "广东" ;;
    hi|海南) echo "海南" ;;
    sc|四川) echo "四川" ;;
    gz|贵州) echo "贵州" ;;
    yn|云南) echo "云南" ;;
    sn|陕西) echo "陕西" ;;
    gs|甘肃) echo "甘肃" ;;
    qh|青海) echo "青海" ;;
    nm|内蒙古) echo "内蒙古" ;;
    gx|广西) echo "广西" ;;
    xz|西藏) echo "西藏" ;;
    nx|宁夏) echo "宁夏" ;;
    xj|新疆) echo "新疆" ;;
    bj|北京) echo "北京" ;;
    tj|天津) echo "天津" ;;
    sh|上海) echo "上海" ;;
    cq|重庆) echo "重庆" ;;
    *) return 1 ;;
  esac
}

tcp_set_provinces() {
  local p name
  TCP_PROVS=""
  for p in "${OPT_PROVINCES[@]}"; do
    if name=$(tcp_province_from_code "$p"); then
      [[ "$TCP_PROVS" == *"|$name|"* ]] || TCP_PROVS+="|$name|"
    else
      ui_warn "不支持的省份代码: $p，已忽略"
    fi
  done
  if [ "${#OPT_PROVINCES[@]}" -gt 0 ] && [ -z "$TCP_PROVS" ]; then
    ui_warn "没有有效的省份代码，改为检测全国"
  fi
}

tcp_prov_selected() {
  [ -z "$TCP_PROVS" ] || [[ "$TCP_PROVS" == *"|$1|"* ]]
}

# ==================== 节点 ====================

tcp_parse_nodes() {
  local line type family prov isp host ip port target bhost bip bport
  TCP_CDN4=(); TCP_CDN6=(); TCP_CERNET=(); TCP_CERNET2=()
  while IFS= read -r line; do
    line=${line//$'\t'/|}
    IFS='|' read -r type family prov isp host ip port target bhost bip bport _ <<< "$line"
    [ "$type" = "type" ] && continue
    [ -z "$ip" ] && continue
    port=${port:-80}
    case "$type:$family" in
      cdn:4) TCP_CDN4+=("$prov|$isp|$host|$ip|$port|$bhost|$bip|${bport:-80}") ;;
      cdn:6) TCP_CDN6+=("$prov|$isp|$host|$ip|$port|$bhost|$bip|${bport:-80}") ;;
      cernet:4) TCP_CERNET+=("$prov|教育网|$host|$ip|$port|$bhost|$bip|${bport:-443}") ;;
      cernet2:6) TCP_CERNET2+=("$prov|教育网|$host|$ip|$port|$bhost|$bip|${bport:-443}") ;;
    esac
  done < "$1"
}

# 本次需要的节点组是否都已拿到
tcp_nodes_ready() {
  { [ $((TCP_DO_P4 + TCP_DO_L)) -eq 0 ] || [ "${#TCP_CDN4[@]}" -gt 0 ]; } &&
    { [ "$TCP_DO_P6" -eq 0 ] || [ "${#TCP_CDN6[@]}" -gt 0 ]; } &&
    { [ "$TCP_DO_E4" -eq 0 ] || [ "${#TCP_CERNET[@]}" -gt 0 ]; } &&
    { [ "$TCP_DO_E6" -eq 0 ] || [ "${#TCP_CERNET2[@]}" -gt 0 ]; }
}

# getNodes 的 scope：只取本次需要的节点组（三网与教育网分开取，比 scope=all 小且快）
tcp_nodes_scopes() {
  local c4=$((TCP_DO_P4 + TCP_DO_L)) c6=$TCP_DO_P6
  if [ "$c4" -gt 0 ] && [ "$c6" -gt 0 ]; then echo cdn
  elif [ "$c4" -gt 0 ]; then echo v4
  elif [ "$c6" -gt 0 ]; then echo v6
  fi
  [ $((TCP_DO_E4 + TCP_DO_E6)) -gt 0 ] && echo cernet
  return 0
}

# 实时获取节点，失败时改用内置快照
tcp_load_nodes() {
  local scope f="$TCP_DIR/nodes.tsv" url sep="?" ok=0
  [[ "$TCP_NODES_URL" == *"?"* ]] && sep="&"
  : > "$f"
  if command -v curl >/dev/null 2>&1; then
    ok=1
    for scope in $(tcp_nodes_scopes); do
      url="${TCP_NODES_URL}${sep}format=tsv&scope=${scope}"
      if curl -4 -fsSL --connect-timeout 5 --max-time 30 "$url" > "$f.part" 2>/dev/null ||
         curl -fsSL --connect-timeout 5 --max-time 30 "$url" > "$f.part" 2>/dev/null; then
        cat "$f.part" >> "$f"
      else
        ok=0
        break
      fi
    done
    rm -f "$f.part"
  fi
  ui_prog_clear
  if [ "$ok" -eq 1 ]; then
    tcp_parse_nodes "$f"
    if tcp_nodes_ready; then
      return 0
    fi
  fi
  tcp_nodes_snapshot > "$f"
  tcp_parse_nodes "$f"
  ui_warn "节点获取失败，使用内置快照（$TCP_SNAPSHOT_DATE）"
}

# 输出某组中已选省份的节点：cdn4 | cdn6 | cernet | cernet2
tcp_selected() {
  local -a list=()
  local e
  case "$1" in
    cdn4) list=("${TCP_CDN4[@]}") ;;
    cdn6) list=("${TCP_CDN6[@]}") ;;
    cernet) list=("${TCP_CERNET[@]}") ;;
    cernet2) list=("${TCP_CERNET2[@]}") ;;
  esac
  for e in "${list[@]}"; do
    tcp_prov_selected "${e%%|*}" && printf '%s\n' "$e"
  done
  return 0
}

tcp_count() {
  local n
  n=$(tcp_selected "$1" | wc -l)
  echo $((n))
}

# ==================== 通用工具 ====================

# 并行数按内存自动设定：每 48MB 一个，1-93
tcp_auto_parallel() {
  local mem_kb="" mem_mb=512 p
  [ -r /proc/meminfo ] && mem_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]] && [ "$mem_kb" -gt 0 ]; then
    mem_mb=$((mem_kb / 1024))
  elif command -v free >/dev/null 2>&1; then
    mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2; exit}')
    [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=512
  fi
  p=$(((mem_mb + 47) / 48))
  [ "$p" -lt 1 ] && p=1
  [ "$p" -gt 93 ] && p=93
  echo "$p"
}

tcp_is_public_v4() {
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      if ($1 == 0 || $1 == 10 || $1 == 127 || $1 >= 224) exit 1
      if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
      if ($1 == 169 && $2 == 254) exit 1
      if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
      if ($1 == 192 && $2 == 168) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 0) exit 1
      if ($1 == 192 && $2 == 0 && $3 == 2) exit 1
      if ($1 == 198 && ($2 == 18 || $2 == 19)) exit 1
      if ($1 == 198 && $2 == 51 && $3 == 100) exit 1
      if ($1 == 203 && $2 == 0 && $3 == 113) exit 1
      exit 0
    }
  ' <<< "$1"
}

tcp_is_public_v6() {
  [[ "$1" =~ : ]] || return 1
  [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  case "$1" in
    ""|::1|fe80:*|fc00:*|fd00:*|2001:db8:*|::ffff:*|2002:*) return 1 ;;
  esac
  return 0
}

# 解析域名，输出第一个公网 IPv4 / IPv6
tcp_resolve4() {
  local answers ip
  for answers in \
    "$(command -v getent >/dev/null 2>&1 && getent ahostsv4 "$1" 2>/dev/null | awk '!seen[$1]++ {print $1}')" \
    "$(command -v dig >/dev/null 2>&1 && dig +time=3 +tries=1 +short A "$1" 2>/dev/null)" \
    "$(command -v host >/dev/null 2>&1 && host -t A "$1" 2>/dev/null | awk '/has address/ {print $NF}')"; do
    while read -r ip; do
      [ -n "$ip" ] && tcp_is_public_v4 "$ip" && { printf '%s' "$ip"; return 0; }
    done <<< "$answers"
  done
  return 1
}

tcp_resolve6() {
  local answers ip
  for answers in \
    "$(command -v getent >/dev/null 2>&1 && getent ahostsv6 "$1" 2>/dev/null | awk '!seen[$1]++ {print $1}')" \
    "$(command -v dig >/dev/null 2>&1 && dig +time=3 +tries=1 +short AAAA "$1" 2>/dev/null)" \
    "$(command -v host >/dev/null 2>&1 && host -t AAAA "$1" 2>/dev/null | awk '/has IPv6 address/ {print $NF}')"; do
    while read -r ip; do
      tcp_is_public_v6 "$ip" && { printf '%s' "$ip"; return 0; }
    done <<< "$answers"
  done
  return 1
}

# IPv6 二层发包参数：输出“网卡|源IPv6|源MAC|下一跳MAC”
tcp_v6_route() {
  local target="$1" info iface src via smac dmac
  command -v ip >/dev/null 2>&1 || return 1
  info=$(ip -6 route get "$target" 2>/dev/null | head -1)
  iface=$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$info")
  src=$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$info")
  via=$(awk '{for (i = 1; i <= NF; i++) if ($i == "via") {print $(i+1); exit}}' <<< "$info")
  if [ -n "$iface" ] && [ -z "$src" ]; then
    src=$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6 / {sub(/\/.*/, "", $2); print $2; exit}')
  fi
  via=${via:-$target}
  smac=$(ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $2; exit}')
  dmac=$(ip -6 neigh show "$via" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i = 1; i <= NF; i++) if ($i == "lladdr") {print $(i+1); exit}}')
  if [ -z "$dmac" ] && command -v ping >/dev/null 2>&1; then
    ping -6 -c 1 -W 1 -I "$iface" "$via" >/dev/null 2>&1
    dmac=$(ip -6 neigh show "$via" dev "$iface" 2>/dev/null | awk '/lladdr/ {for (i = 1; i <= NF; i++) if ($i == "lladdr") {print $(i+1); exit}}')
  fi
  src=${src%%\%*}
  case "$src" in
    [23]*:*)
      if [ -n "$iface" ] &&
         [[ "$smac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] &&
         [[ "$dmac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        printf '%s|%s|%s|%s\n' "$iface" "$src" "$smac" "$dmac"
        return 0
      fi
      ;;
  esac
  return 1
}

# ==================== 回程线路识别 ====================
# 以下 awk 识别逻辑与原脚本逐字一致（仅函数改名）。

tcp_trace_ips() {
  local trace_file="$1"
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function public_v6(ip) {
      if (ip !~ /:/ || ip !~ /^[0-9A-Fa-f:]+$/) return 0
      if (ip ~ /^::1$/ || ip ~ /^fe80:/ || ip ~ /^fc/ || ip ~ /^fd/) return 0
      return 1
    }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      for (i = 1; i <= NF; i++) {
        field = $i
        gsub(/[^0-9A-Fa-f:.%]/, " ", field)
        count = split(field, tokens, /[[:space:]]+/)
        for (j = 1; j <= count; j++) {
          token = tokens[j]
          sub(/%.*/, "", token)
          gsub(/^:+|:+$/, "", token)
          if (public_v4(token)) print token
          else if (public_v6(token)) print token
        }
      }
    }
  ' "$trace_file"
}

tcp_need_10099_retry() {
  local trace_file="$1"
  awk '
    function public_v4(ip, parts, k) {
      if (split(ip, parts, ".") != 4) return 0
      for (k = 1; k <= 4; k++) if (parts[k] !~ /^[0-9]+$/ || parts[k] < 0 || parts[k] > 255) return 0
      if (parts[1] == 0 || parts[1] == 10 || parts[1] == 127 || parts[1] >= 224) return 0
      if (parts[1] == 100 && parts[2] >= 64 && parts[2] <= 127) return 0
      if (parts[1] == 169 && parts[2] == 254) return 0
      if (parts[1] == 172 && parts[2] >= 16 && parts[2] <= 31) return 0
      if (parts[1] == 192 && parts[2] == 168) return 0
      if (parts[1] == 198 && (parts[2] == 18 || parts[2] == 19)) return 0
      return 1
    }
    function is_10099(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./
    }
    function is_4837(ip) {
      return ip ~ /^219\.158\./
    }
    function is_9929(ip) {
      return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./
    }
    function is_163(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./
    }
    /^#/ || /^target[[:space:]]/ || /^traceroute[[:space:]]/ { next }
    {
      line = $0
      has_ip = 0
      while (match(line, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (!public_v4(ip)) continue
        has_ip = 1
        if (is_10099(ip)) {
          seen_10099 = 1
          after_10099 = 1
          continue
        }
        if (!after_10099) continue
        if (is_4837(ip) || is_9929(ip)) seen_unicom_domestic = 1
        if (is_163(ip)) seen_163 = 1
      }
      if (after_10099 && !seen_163 && !has_ip && $0 ~ /\*/) hidden_after_10099++
    }
    END {
      exit !(seen_10099 && seen_163 && !seen_unicom_domestic && hidden_after_10099 >= 2)
    }
  ' "$trace_file"
}

# Team Cymru 批量 whois 查询 ASN
tcp_cymru_query() {
  local ip_file="$1" out_file="$2" req_file="$2.req"
  {
    echo "begin"
    echo "verbose"
    sort -u "$ip_file"
    echo "end"
  } > "$req_file"
  run_to 35 bash -c 'exec 3<>/dev/tcp/whois.cymru.com/43; cat "$1" >&3; cat <&3' _ "$req_file" > "$out_file" 2>/dev/null
  rm -f "$req_file"
}

tcp_build_asn_map() {
  local cymru_file="$1" map_file="$2"
  awk -F'|' '
    NR == 1 { next }
    {
      asn = $1
      ip = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", asn)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)
      owner = $7
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
      count = split(asn, values, /[[:space:]]+/)
      asn = values[count]
      if (asn ~ /^[0-9]+$/ && ip ~ /^[0-9A-Fa-f:.]+$/) print tolower(ip) "|" asn "|" owner
    }
  ' "$cymru_file" > "$map_file"
}

tcp_route_label() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3"
  local target_isp="${4:-}"
  awk -F'|' -v target_isp="$target_isp" '
    function infer_asn_from_ip(ip) {
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./) return "23764"
      if (ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./) return "4134"
      if (ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./) return "4837"
      if (ip ~ /^2408:/) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./) return "10099"
      if (ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./) return "9929"
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      if (ip ~ /^159\.226\./) return "7497"
      return ""
    }
    function has_asn(v) { return index(all_asn, "AS" v " ") > 0 }
    function add_asn(asn) {
      if (asn != "" && index(all_asn, "AS" asn " ") == 0) all_asn = all_asn "AS" asn " "
    }
    function is_ctgnet_ip(ip) {
      return ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.178\./ || ip ~ /^203\.22\.179\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/
    }
    function is_ctgnet_transit_ip(ip) {
      return is_ctgnet_ip(ip)
    }
    function is_163_ip(ip) {
      return ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/
    }
    function is_telecom_access_asn(asn) {
      return asn == "4134" || asn == "4811" || asn == "4812" || asn == "4847" || asn == "23724" || asn == "134756" || asn == "133776" || asn == "139201" || asn == "139203" || asn == "148969" || asn == "38283" || asn == "58540" || asn == "58563"
    }
    function is_telecom_access_ip(ip) {
      return ip ~ /^1\.202\./ || ip ~ /^27\.129\./ || ip ~ /^36\.110\./ || ip ~ /^36\.112\./ || ip ~ /^58\.213\./ || ip ~ /^101\.95\./ || ip ~ /^101\.226\./ || ip ~ /^106\.227\./ || ip ~ /^111\.74\./ || ip ~ /^117\.21\./ || ip ~ /^117\.68\./ || ip ~ /^124\.127\./ || ip ~ /^140\.249\./ || ip ~ /^180\.102\./ || ip ~ /^183\.47\./ || ip ~ /^219\.148\./ || ip ~ /^220\.181\./
    }
    function is_mobile_access_asn(asn) {
      return asn == "24547" || asn == "132510"
    }
    function is_mobile_access_ip(ip) {
      return ip ~ /^111\.63\./ || ip ~ /^183\.201\./ || ip ~ /^183\.203\./
    }
    function is_cmin2_asn(asn) {
      return asn == "58807"
    }
    function is_cmi_asn(asn) {
      return asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/
    }
    function compact_combo_label(label,   parts, n) {
      n = split(label, parts, "->")
      if (n > 2) return parts[1] "->" parts[n]
      return label
    }
    function mobile_label_before(last,   h, has_cmin2, has_cmi) {
      if (last <= 1) return ""
      for (h = 1; h < last; h++) {
        if (is_cmin2_asn(asns[h])) has_cmin2 = 1
        if (is_cmi_asn(asns[h]) || (target_isp == "移动" && (is_mobile_access_asn(asns[h]) || is_mobile_access_ip(ips[h])))) has_cmi = 1
      }
      if (has_cmin2 && has_cmi) return "CMIN2->CMI"
      if (has_cmin2) return "CMIN2"
      if (has_cmi) return "CMI"
      return ""
    }
    function is_oversea_163_ip(ip) {
      return ip ~ /^218\.30\./ || ip ~ /^145\.14\./ || ip ~ /^5\.154\./
    }
    function is_oversea_10099_ip(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.3[2-9]\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/
    }
    function is_10099_entry_ip(ip) {
      return ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/
    }
    function is_10099_hop(asn, ip) {
      # ASN 查询结果是权威判断；前缀只在 ASN 缺失时作为兜底。
      return asn == "10099" || (asn == "" && is_10099_entry_ip(ip))
    }
    function is_oversea_cn2_ip(ip) {
      return ip ~ /^2605:9d80:/
    }
    function is_unicom_backbone_ip(ip) {
      return ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^219\.158\./ || ip ~ /^2408:/
    }
    function is_unicom_backbone_asn(asn) {
      return asn == "9929" || asn == "4837" || asn == "4808"
    }
    function is_unicom_access_asn(asn) {
      return asn == "17816" || asn == "135061" || asn == "136958" || asn == "140979"
    }
    function is_unicom_route_hop(h) {
      return is_unicom_backbone_asn(asns[h]) || is_unicom_backbone_ip(ips[h]) || is_unicom_access_asn(asns[h])
    }
    function has_163_before(last,   h) {
      if (last <= 1) return 0
      for (h = 1; h < last; h++) {
        if (asns[h] == "4134" || asns[h] == "4847" || is_163_ip(ips[h])) return 1
      }
      return 0
    }
    function unicom_domestic_label_from_hop(first,   h, has_4837) {
      for (h = first + 1; h <= max_hop; h++) {
        if (asns[h] == "9929" || ips[h] ~ /^210\.14\./ || ips[h] ~ /^210\.51\./ || ips[h] ~ /^210\.78\./ || ips[h] ~ /^218\.105\./) return "9929"
        if (asns[h] == "4837" || asns[h] == "4808" || is_unicom_access_asn(asns[h]) || ips[h] ~ /^219\.158\./ || ips[h] ~ /^2408:/) has_4837 = 1
      }
      if (has_4837) return "4837"
      return ""
    }
    function unicom_route_combo_label(   h, first_unicom, domestic, mobile_transit) {
      for (h = 1; h <= max_hop; h++) {
        if (is_10099_hop(asns[h], ips[h])) {
          first_unicom = h
          domestic = unicom_domestic_label_from_hop(h)
          if (domestic != "") return "10099->" domestic
          return "10099"
        }
        if (is_unicom_route_hop(h)) {
          first_unicom = h
          break
        }
      }
      domestic = unicom_domestic_label_from_hop(first_unicom - 1)
      mobile_transit = mobile_label_before(first_unicom)
      if (target_isp == "联通" && domestic != "" && mobile_transit != "") return compact_combo_label(mobile_transit "->" domestic)
      if (target_isp == "联通" && domestic != "" && has_163_before(first_unicom)) return "163->" domestic
      return domestic
    }
    function has_unicom_downstream(first,   h) {
      if (first <= 0) return 0
      for (h = first + 1; h <= max_hop; h++) {
        if (is_unicom_route_hop(h)) return 1
      }
      return 0
    }
    function has_10099_entry_to_unicom(   h) {
      for (h = 1; h <= max_hop; h++) {
        if (is_10099_hop(asns[h], ips[h]) && has_unicom_downstream(h)) return 1
      }
      return 0
    }
    function has_163_after(first,   h) {
      if (first <= 0) return 0
      for (h = first + 1; h <= max_hop; h++) {
        if (asns[h] == "4134" || is_163_ip(ips[h])) return 1
      }
      return 0
    }
    function has_cn2_to_163(first,   h, n) {
      if (first <= 0) return 0
      for (h = first; h <= max_hop; h++) {
        if (ips[h] !~ /^59\.43\.245\./) continue
        for (n = h + 1; n <= max_hop; n++) {
          if (ips[n] ~ /^59\.43\./) continue
          return asns[n] == "4134" || asns[n] == "4847" || is_163_ip(ips[n]) || (target_isp == "电信" && (is_telecom_access_asn(asns[n]) || is_telecom_access_ip(ips[n])))
        }
      }
      return 0
    }
    function is_mainland_backbone_hop(asn, ip) {
      if (is_10099_hop(asn, ip)) return 1
      if (asn == "9929" || asn == "4837" || asn == "4808") return 1
      if (asn == "4809") return !is_oversea_cn2_ip(ip)
      if (asn == "4134" || asn == "4847") return 1
      if (is_163_ip(ip)) return 1
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return 1
      if (asn == "23764" || is_ctgnet_ip(ip)) return !is_ctgnet_transit_ip(ip)
      if (asn == "58807" || asn == "58453" || asn == "9808") return 1
      if (asn ~ /^5604[0-8]$/) return 1
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return 1
      if (asn == "23911" || asn == "23910" || asn == "4538" || asn == "7497") return 1
      if (is_163_ip(ip)) return 1
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return 1
      return 0
    }
    function label_from_mainland_hop(hop, asn, ip,   h) {
      if (is_10099_hop(asn, ip)) return "10099"
      if (asn == "9929") return "9929"
      if (asn == "4837" || asn == "4808") return "4837"
      if (asn == "4134" || asn == "4847" || is_163_ip(ip)) return "163"
      if (target_isp == "电信" && (is_telecom_access_asn(asn) || is_telecom_access_ip(ip))) return "163"
      if (asn == "23764" || is_ctgnet_ip(ip)) return ""
      if (asn == "4809") {
        if (has_cn2_to_163(hop)) return "CN2GT"
        for (h = hop; h <= max_hop; h++) {
          if (asns[h] == "23764" || is_ctgnet_ip(ips[h])) return "CTGGIA"
        }
        return "CN2GIA"
      }
      if (asn == "58807") return "CMIN2"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (target_isp == "移动" && (is_mobile_access_asn(asn) || is_mobile_access_ip(ip))) return "CMI"
      if (asn == "23911" || asn == "23910") return "CERNET2"
      if (asn == "4538") return "CERNET"
      if (asn == "7497") return "CSTNET"
      return ""
    }
    function is_local_probe_asn(asn) {
      return asn == "" || asn == "749"
    }
    function is_target_isp_hop(asn, ip) {
      if (target_isp == "电信") return is_163_ip(ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(ip)
      if (target_isp == "联通") return is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(ip) || is_unicom_access_asn(asn)
      if (target_isp == "移动") return asn == "58807" || asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(ip)
      return 0
    }
    function visible_hops_match_target_isp(   h) {
      if (max_hop <= 0) return 0
      for (h = 1; h <= max_hop; h++) {
        if (is_local_probe_asn(asns[h])) continue
        if (is_target_isp_hop(asns[h], ips[h])) continue
        return 0
      }
      return 1
    }
    function label_from_target_ip(   asn) {
      if (dest_ip == "" || !visible_hops_match_target_isp()) return ""
      asn = asn_by_ip[dest_ip]
      if (asn == "") asn = infer_asn_from_ip(dest_ip)
      if (target_isp == "电信" && (is_163_ip(dest_ip) || is_telecom_access_asn(asn) || is_telecom_access_ip(dest_ip))) return "163"
      if (target_isp == "联通" && (is_unicom_backbone_asn(asn) || is_unicom_backbone_ip(dest_ip) || is_unicom_access_asn(asn))) return unicom_route_combo_label()
      if (target_isp == "移动" && asn == "58807") return "CMIN2"
      if (target_isp == "移动" && (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/ || is_mobile_access_asn(asn) || is_mobile_access_ip(dest_ip))) return "CMI"
      return ""
    }
    function classify(   hop, label, first_cn2, has_ctgnet, has_cn2, has_v6) {
      for (hop = 1; hop <= max_hop; hop++) {
        if (ips[hop] ~ /:/) has_v6 = 1
        if (asns[hop] == "23764" || is_ctgnet_ip(ips[hop])) has_ctgnet = 1
        if (ips[hop] ~ /^59\.43\./) {
          has_cn2 = 1
          if (first_cn2 == 0) first_cn2 = hop
        }
      }
      if (has_cn2) {
        if (has_cn2_to_163(first_cn2)) return "CN2GT"
        if (has_ctgnet) return "CTGGIA"
        return "CN2GIA"
      }
      label = unicom_route_combo_label()
      if (label != "") return label
      if (has_asn("58807")) return "CMIN2"
      for (hop = 1; hop <= max_hop; hop++) {
        if (!is_mainland_backbone_hop(asns[hop], ips[hop])) continue
        label = label_from_mainland_hop(hop, asns[hop], ips[hop])
        if (label != "") return label
      }
      if (has_asn("23911")) return "CERNET2"
      if (has_asn("9929")) return "9929"
      if (has_asn("4837") || has_asn("4808")) return "4837"
      if (has_asn("4847")) return "163"
      if (has_asn("58453") || has_asn("9808") || has_asn("56040") || has_asn("56041") || has_asn("56042") || has_asn("56044") || has_asn("56045") || has_asn("56046") || has_asn("56047") || has_asn("56048")) return "CMI"
      if (has_ctgnet || has_asn("23764")) return "CTGGIA"
      if (has_asn("23910")) return "CERNET2"
      if (has_asn("4538")) return "CERNET"
      if (has_asn("7497")) return "CSTNET"
      label = label_from_target_ip()
      if (label != "") return label
      return "Hidden"
    }
    FILENAME == ARGV[1] {
      asn_by_ip[$1] = $2
      next
    }
    FILENAME == ARGV[2] {
      ip = $0
      if (seen_ip[ip]++) next
      asn = asn_by_ip[ip]
      if (asn == "") asn = infer_asn_from_ip(ip)
      max_hop++
      ips[max_hop] = ip
      asns[max_hop] = asn
      add_asn(asn)
      next
    }
    /^#/ {
      if (NF >= 6) dest_ip = $6
      next
    }
    /^target[[:space:]]/ {
      if (split($0, target_fields, /[[:space:]]+/) >= 2) dest_ip = target_fields[2]
      next
    }
    /bad integer value|unknown arguments/ { in_usage = 1; next }
    /^usage:/ { in_usage = 1; next }
    in_usage { next }
    /^traceroute[[:space:]]/ || / -> .*hops max/ || /^NextTrace[[:space:]]/ || /^IP Geo Data Provider:/ { next }
    {
      while (match($0, /[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/)) {
        ip = substr($0, RSTART, RLENGTH)
        $0 = substr($0, RSTART + RLENGTH)
        if (seen_ip[ip]++) continue
        asn = asn_by_ip[ip]
        if (asn == "") asn = infer_asn_from_ip(ip)
        max_hop++
        ips[max_hop] = ip
        asns[max_hop] = asn
        add_asn(asn)
      }
    }
    END { print classify() }
  ' "$asn_map_file" "$trace_ip_file" "$trace_file"
}

tcp_edu_route_label() {
  local trace_file="$1" asn_map_file="$2" trace_ip_file="$3" family="$4"
  local fallback label
  fallback=$(tcp_route_label "$trace_file" "$asn_map_file" "$trace_ip_file" "教育网")
  label=$(awk -F'|' -v family="$family" '
    function infer_education_asn(ip) {
      if (ip ~ /^59\.64\./ || ip ~ /^101\.4\./ || ip ~ /^101\.6\./ || ip ~ /^101\.76\./ || ip ~ /^111\.114\./ || ip ~ /^113\.54\./ || ip ~ /^115\.24\./ || ip ~ /^115\.156\./ || ip ~ /^183\.172\./ || ip ~ /^202\.38\.19/ || ip ~ /^202\.112\./ || ip ~ /^202\.113\./ || ip ~ /^202\.114\./ || ip ~ /^202\.115\./ || ip ~ /^202\.116\./ || ip ~ /^202\.117\./ || ip ~ /^202\.118\./ || ip ~ /^202\.119\./ || ip ~ /^202\.120\./ || ip ~ /^202\.194\./ || ip ~ /^202\.196\./ || ip ~ /^202\.197\./ || ip ~ /^202\.198\./ || ip ~ /^202\.200\./ || ip ~ /^202\.201\./ || ip ~ /^202\.202\./ || ip ~ /^202\.207\./ || ip ~ /^210\.2[6-9]\./ || ip ~ /^210\.3[0-9]\./ || ip ~ /^210\.4[0-7]\./ || ip ~ /^219\.22[4-9]\./ || ip ~ /^222\.(1[6-9]|2[0-3])\./ || ip ~ /^222\.19[2-9]\./ || ip ~ /^222\.20[0-7]\./) return "4538"
      if (ip ~ /^2001:252:/) return "23911"
      if (ip ~ /^2001:da8:/ || ip ~ /^2001:250:/ || ip ~ /^2402:f000:/) return "23910"
      return ""
    }
    function infer_route_asn(ip,   asn) {
      asn = infer_education_asn(ip)
      if (asn != "") return asn
      if (ip ~ /^59\.43\./) return "4809"
      if (ip ~ /^203\.22\.182\./ || ip ~ /^203\.22\.(178|179)\./ || ip ~ /^203\.128\.224\./ || ip ~ /^69\.194\./ || ip ~ /^2400:9380:/) return "23764"
      if (ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/) return "4134"
      if (ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/)) return "4837"
      if (ip ~ /^223\.120\./ || ip ~ /^223\.119\./) return "58453"
      if (ip ~ /^221\.183\./ || ip ~ /^111\.24\./ || ip ~ /^111\.13\./ || ip ~ /^2409:8080:/) return "9808"
      if (ip ~ /^2402:4f00:f000:/) return "58807"
      if (ip ~ /^2401:3cc0:/) return "7578"
      if (ip ~ /^103\.214\./ || ip ~ /^103\.228\.68\./ || ip ~ /^103\.239\.176\./ || ip ~ /^118\.26\.151\./ || ip ~ /^162\.219\.(3[2-9]|85)\./ || ip ~ /^162\.245\.124\./ || ip ~ /^202\.77\.23\./ || ip ~ /^203\.160\.(66|75)\./ || ip ~ /^2401:8a00:/) return "10099"
      if (ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/) return "9929"
      return ""
    }
    function is_education_asn(asn, owner, lower_owner) {
      lower_owner = tolower(owner)
      return asn == "4538" || asn == "23910" || asn == "23911" || asn == "24350" || lower_owner ~ /cernet/
    }
    function is_education_hop(asn, owner, ip) {
      return is_education_asn(asn, owner) || infer_education_asn(ip) != ""
    }
    function is_hkix_ip(ip) {
      return ip ~ /^123\.255\.(8[8-9]|9[0-5])\./ || ip ~ /^2001:7fa:/
    }
    function is_he_exchange_ip(ip) {
      return ip == "2001:504:13::210:122"
    }
    function is_ctggia_ip(ip) {
      return ip ~ /^59\.43\./
    }
    function is_ctggia_hop(asn, owner, ip, lower_owner) {
      lower_owner = tolower(owner)
      return asn == "23764" || is_ctggia_ip(ip) || lower_owner ~ /china telecom global|ctgnet|ctg[- ]/
    }
    function compact_owner(owner,   value, words, count, i, result, candidate) {
      value = owner
      sub(/[[:space:]]+-[[:space:]].*$/, "", value)
      gsub(/,/, "", value)
      gsub(/[[:space:]]+(Limited|Ltd\.?|Inc\.?|LLC|Corporation|Corp\.?|Company|Co\.?)$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (length(value) <= 9) return value
      count = split(value, words, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        candidate = result (result == "" ? "" : " ") words[i]
        if (length(candidate) > 9) break
        result = candidate
      }
      return result != "" ? result : substr(value, 1, 9)
    }
    function is_generic_owner_label(label, lower_label) {
      lower_label = tolower(label)
      return lower_label == "global" || lower_label == "network" || lower_label == "networks" || lower_label == "internet" || lower_label == "communications" || lower_label == "telecom"
    }
    function transit_label(asn, owner, ip,   lower_owner, label) {
      if (is_hkix_ip(ip)) return "HKIX"
      if (is_he_exchange_ip(ip)) return "HE"
      if (is_ctggia_hop(asn, owner, ip)) return "CTGGIA"
      if (asn == "4134") return "163"
      if (asn == "4837") return "4837"
      if (asn == "58807") return "CMIN2"
      if (asn == "10099") return "10099"
      if (asn == "9929") return "9929"
      if (asn == "58453" || asn == "9808" || asn ~ /^5604[0-8]$/) return "CMI"
      if (asn == "7578" || asn == "137409") return "GSL"
      lower_owner = tolower(owner)
      if (lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (lower_owner ~ /china169[- ]backbone/) return "4837"
      if (lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (lower_owner ~ /china mobile international|cmi-int/) return "CMI"
      if (lower_owner ~ /global secure layer/) return "GSL"
      if (asn == "6939" || lower_owner ~ /hurricane electric/) return "HE"
      if (lower_owner ~ /ntt/) return "NTT"
      if (lower_owner ~ /arelion|twelve99|telia carrier/) return "Arelion"
      if (lower_owner ~ /cogent/) return "Cogent"
      if (lower_owner ~ /tata communications/) return "Tata"
      label = compact_owner(owner)
      if (is_generic_owner_label(label)) return asn != "" ? "AS" asn : ""
      return label != "" ? label : (asn != "" ? "AS" asn : "")
    }
    function domestic_label(asn, owner, ip,   lower_owner) {
      lower_owner = tolower(owner)
      if (asn == "4134" || ip ~ /^202\.97\./ || ip ~ /^202\.96\./ || ip ~ /^219\.141\./ || ip ~ /^219\.142\./ || ip ~ /^106\.37\./ || ip ~ /^240e:/ || lower_owner ~ /chinanet[- ]backbone/) return "163"
      if (asn == "9929" || ip ~ /^210\.14\./ || ip ~ /^210\.51\./ || ip ~ /^210\.78\./ || ip ~ /^218\.105\./ || ip ~ /^2408:8120:/ || lower_owner ~ /china unicom industrial internet|cuii/) return "9929"
      if (asn == "4837" || ip ~ /^219\.158\./ || (ip ~ /^2408:/ && ip !~ /^2408:8120:/) || lower_owner ~ /china169[- ]backbone/) return "4837"
      return ""
    }
    function is_international_label(label) {
      return label == "CTGGIA" || label == "10099" || label == "CMI" || label == "CMIN2" || label == "HE" || label == "GSL" || label == "NTT" || label == "Arelion" || label == "Cogent" || label == "Tata"
    }
    FILENAME == ARGV[1] {
      asn_by_ip[tolower($1)] = $2
      owner_by_ip[tolower($1)] = $3
      next
    }
    FILENAME == ARGV[2] {
      ip = tolower($0)
      if (seen[ip]++) next
      hop++
      ips[hop] = ip
      asns[hop] = asn_by_ip[ip]
      owners[hop] = owner_by_ip[ip]
      if (asns[hop] == "") asns[hop] = infer_route_asn(ip)
      next
    }
    END {
      first_education = 0
      for (h = 1; h <= hop; h++) {
        if (is_education_hop(asns[h], owners[h], ips[h])) {
          first_education = h
          break
        }
      }
      if (first_education == 0) exit
      for (h = 1; h < first_education; h++) {
        if (is_hkix_ip(ips[h]) && first_hkix == 0) first_hkix = h
        candidate = transit_label(asns[h], owners[h], ips[h])
        if (is_international_label(candidate)) {
          if (first_international == "") first_international = candidate
          if (candidate == "CMIN2") {
            seen_cmin2 = 1
            international = candidate
          } else if (candidate == "CMI" && seen_cmin2) {
            international = "CMIN2->CMI"
          } else {
            international = candidate
          }
          last_international = h
        }
      }
      if (first_hkix > 0) {
        for (h = first_hkix - 1; h >= 1; h--) {
          candidate = transit_label(asns[h], owners[h], ips[h])
          if (candidate == "" || candidate == "HKIX" || candidate == "163" || candidate == "4837" || candidate == "9929") continue
          if (is_international_label(candidate)) {
            upstream = candidate
            break
          }
          if (fallback_upstream == "") fallback_upstream = candidate
        }
        if (upstream == "") upstream = fallback_upstream
        print (upstream != "" ? upstream "->HKIX" : "HKIX")
        exit
      }
      if (last_international > 0) {
        for (h = last_international + 1; h < first_education; h++) {
          domestic = domestic_label(asns[h], owners[h], ips[h])
          if (domestic != "") {
            first_domestic = domestic
            break
          }
        }
        if (first_domestic != "") {
          print (international !~ /->/ ? international "->" first_domestic : international)
        } else if (international ~ /->/) {
          print international
        } else if (first_international != "" && first_international != international) {
          print first_international "->" international
        } else {
          print international
        }
        exit
      }
      for (h = first_education - 1; h >= 1; h--) {
        if (is_education_hop(asns[h], owners[h], ips[h])) continue
        transit = transit_label(asns[h], owners[h], ips[h])
        if (transit != "") break
      }
      if (transit == "") transit = "Hidden"
      print transit
    }
  ' "$asn_map_file" "$trace_ip_file")
  printf '%s' "${label:-$fallback}"
}

# 对一个节点做路由追踪：protocol 为 tcp（traceroute）或 nexttrace（大包，nexttrace-tiny）
tcp_trace_one() {
  local family="$1" protocol="$2" prov="$3" isp="$4" host="$5" idx="$6" port="${7:-80}" target_ip="${8:-}" prefix="$9"
  local packet_length="${10:-44}"
  local outfile="$TCP_DIR/${prefix}_${idx}" trace_file="$TCP_DIR/${prefix}_trace_${idx}"
  local output rc retry_output
  local -a args

  if [ -z "$target_ip" ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|NO_NODE_IP" > "$outfile"
    return
  fi
  if [ "$protocol" = "nexttrace" ]; then
    if [ "$family" != "4" ]; then
      echo "FAIL|$prov|$isp|$protocol|$host|UNSUPPORTED_FAMILY" > "$outfile"
      return
    fi
    args=(-4 -T -p "$port" --psize "$packet_length" -M -d disable-geoip -n -q 3 -m 30 "$target_ip")
    output=$(run_to "$TCP_TRACE_TIMEOUT" nexttrace-tiny "${args[@]}" 2>&1)
    rc=$?
  else
    args=(-n "-${family}" -T -p "$port" -q 3 -w 2 -m 30 "$target_ip" "$packet_length")
    output=$(run_to "$TCP_TRACE_TIMEOUT" traceroute "${args[@]}" 2>&1)
    rc=$?
  fi
  if [ "$rc" -eq 124 ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|TIMEOUT" > "$outfile"
    return
  fi
  {
    printf "# %s|%s|%s|%s|%s|%s\n" "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
    printf "target %s\n" "$target_ip"
    printf "%s\n" "$output"
  } > "$trace_file"
  if [ "$protocol" = "nexttrace" ] && [ "$rc" -ne 0 ] &&
     printf "%s\n" "$output" | grep -Eq '(^usage:|bad integer value|unknown arguments)'; then
    echo "FAIL|$prov|$isp|$protocol|$host|NEXTTRACE_ERROR" > "$outfile"
    return
  fi
  # 10099 之后国内段全隐藏时重试一次，补全国内骨干
  if [ "$family" = "4" ] && [ "$protocol" = "tcp" ] && tcp_need_10099_retry "$trace_file"; then
    retry_output=$(run_to "$TCP_TRACE_TIMEOUT" traceroute "${args[@]}" 2>&1)
    {
      printf "\n# retry 10099 hidden domestic segment|%s|%s|%s|%s|%s|%s\n" "$prov" "$isp" "$protocol" "$host" "$idx" "$target_ip"
      printf "target %s\n" "$target_ip"
      printf "%s\n" "$retry_output"
    } >> "$trace_file"
  fi
  if tcp_trace_ips "$trace_file" | grep -q .; then
    echo "TRACE|$prov|$isp|$protocol|$host|$idx" > "$outfile"
  elif [[ "$output" == *"Operation not permitted"* || "$output" == *"operation not permitted"* ]]; then
    echo "FAIL|$prov|$isp|$protocol|$host|PERMISSION" > "$outfile"
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL|$prov|$isp|$protocol|$host|TRACE_ERROR" > "$outfile"
  else
    echo "FAIL|$prov|$isp|$protocol|$host|NO_HOPS" > "$outfile"
  fi
}

# 并行追踪一组节点，查询 ASN 后输出线路标签：OK|省份|运营商|协议|域名|标签
# nexttrace-tiny 单进程约 21MB（traceroute 约 1.5MB），按当前可用内存单独限制并行：
# 预留 96MB，每个任务按 32MB 计，不超过 TCP_PARALLEL
tcp_nexttrace_parallel() {
  local avail p
  avail=$(awk '/^MemAvailable:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)
  [[ "$avail" =~ ^[0-9]+$ ]] || { echo 1; return; }
  p=$(( (avail - 96) / 32 ))
  [ "$p" -lt 1 ] && p=1
  [ "$p" -gt "$TCP_PARALLEL" ] && p=$TCP_PARALLEL
  echo "$p"
}

tcp_collect_routes() {
  local group="$1" family="$2" out_file="$3" prefix="$4" packet_length="${5:-44}" protocol="${6:-tcp}"
  local idx=0 i prov isp host ip port _r status value label tf limit="$TCP_PARALLEL"
  local raw="$TCP_DIR/${prefix}.raw" ips="$TCP_DIR/${prefix}.ips" cymru="$TCP_DIR/${prefix}.cymru" map="$TCP_DIR/${prefix}.asn"
  [ "$protocol" = nexttrace ] && limit=$(tcp_nexttrace_parallel)
  : > "$out_file"
  while IFS='|' read -r prov isp host ip port _r; do
    idx=$((idx + 1))
    while [ "$(jobs -pr | wc -l)" -ge "$limit" ]; do sleep 0.2; done
    tcp_trace_one "$family" "$protocol" "$prov" "$isp" "$host" "$idx" "${port:-80}" "$ip" "$prefix" "$packet_length" &
  done < <(tcp_selected "$group")
  wait
  [ "$idx" -eq 0 ] && return 0

  : > "$raw"; : > "$ips"; : > "$map"
  for ((i = 1; i <= idx; i++)); do
    [ -f "$TCP_DIR/${prefix}_${i}" ] && cat "$TCP_DIR/${prefix}_${i}" >> "$raw"
    [ -f "$TCP_DIR/${prefix}_trace_${i}" ] && tcp_trace_ips "$TCP_DIR/${prefix}_trace_${i}" >> "$ips"
  done
  sort -u "$ips" -o "$ips" 2>/dev/null
  if [ -s "$ips" ]; then
    tcp_cymru_query "$ips" "$cymru"
    tcp_build_asn_map "$cymru" "$map"
  fi

  while IFS='|' read -r status prov isp protocol host value; do
    tf="$TCP_DIR/${prefix}_trace_${value}"
    if [ "$status" = "TRACE" ] && [ -f "$tf" ]; then
      tcp_trace_ips "$tf" > "$tf.ips"
      case "$group" in
        cernet|cernet2) label=$(tcp_edu_route_label "$tf" "$map" "$tf.ips" "$family") ;;
        *) label=$(tcp_route_label "$tf" "$map" "$tf.ips" "$isp") ;;
      esac
      echo "OK|$prov|$isp|$protocol|$host|$label" >> "$out_file"
    elif [ -n "$status" ]; then
      echo "$status|$prov|$isp|$protocol|$host|${value:-Hidden}" >> "$out_file"
    fi
  done < "$raw"
}

# 后台依次完成各组线路识别（与原脚本相同：识别结束后才开始延迟/丢包探测）
tcp_start_routes() {
  (
    [ "$TCP_DO_R4" -eq 1 ] && tcp_collect_routes cdn4 4 "$TCP_DIR/label_route4" route4
    [ "$TCP_DO_LR" -eq 1 ] && tcp_collect_routes cdn4 4 "$TCP_DIR/label_large4" lroute4 1200 nexttrace
    [ "$TCP_DO_R6" -eq 1 ] && tcp_collect_routes cdn6 6 "$TCP_DIR/label_route6" route6
    [ "$TCP_DO_ER4" -eq 1 ] && tcp_collect_routes cernet 4 "$TCP_DIR/label_edu4" eroute4
    [ "$TCP_DO_ER6" -eq 1 ] && tcp_collect_routes cernet2 6 "$TCP_DIR/label_edu6" eroute6
  ) > "$TCP_DIR/route.log" 2>&1 &
  TCP_ROUTE_PID=$!
}

# ==================== 延迟 / 丢包探测（nping） ====================

tcp_nping_sport() {
  printf "%s\n" $((20000 + RANDOM % 40000))
}

tcp_nping_seq() {
  printf "%s\n" $((((RANDOM << 16) ^ RANDOM) & 0x7ffffffe))
}

tcp_nping_min_rtt() {
  local raw="$1"
  printf "%s\n" "$raw" | awk '
    function ep_ip(ep) {
      sub(/:[0-9]+$/, "", ep)
      return tolower(ep)
    }
    function ep_port(ep) {
      if (match(ep, /:[0-9]+$/)) {
        return substr(ep, RSTART + 1)
      }
      return ""
    }
    function parse_tcp_line(line, prefix, time_s, body, parts, left, right) {
      time_s = line
      sub(/^[^(]*\(/, "", time_s)
      sub(/s\).*/, "", time_s)
      body = line
      sub(/^.* TCP /, "", body)
      split(body, parts, " > ")
      if (!parts[1] || !parts[2]) return 0
      left = parts[1]
      right = parts[2]
      sub(/ .*/, "", right)
      if (!ep_port(left) || !ep_port(right)) return 0
      if (prefix == "sent") {
        sent_time = time_s + 0
        sent_src_ip = ep_ip(left)
        sent_src_port = ep_port(left)
        sent_dst_ip = ep_ip(right)
        sent_dst_port = ep_port(right)
        have_sent = 1
      } else {
        rcvd_time = time_s + 0
        rcvd_src_ip = ep_ip(left)
        rcvd_src_port = ep_port(left)
        rcvd_dst_ip = ep_ip(right)
        rcvd_dst_port = ep_port(right)
      }
      return 1
    }
    /^SENT .* TCP / && !have_sent {
      parse_tcp_line($0, "sent")
    }
    /^RCVD .* TCP / && have_sent {
      if (parse_tcp_line($0, "rcvd") &&
          rcvd_src_ip == sent_dst_ip &&
          rcvd_src_port == sent_dst_port &&
          rcvd_dst_ip == sent_src_ip &&
          rcvd_dst_port == sent_src_port) {
        rtt_ms = (rcvd_time - sent_time) * 1000
        if (!found || rtt_ms < min_rtt) min_rtt = rtt_ms
        found = 1
      }
    }
    END {
      if (found) {
        printf "%.3f\n", min_rtt
      } else {
        exit 1
      }
    }
  '
}

# 发送一个 SYN；结果写入调用方的 one_sent / one_rcvd / one_rtt
tcp_nping_once() {
  local ip="$1" payload="$2" raw
  shift 2
  raw=$(nping "$@" -g "$(tcp_nping_sport)" --seq "$(tcp_nping_seq)" --data-length "$payload" -c 1 "$ip" 2>&1)
  one_sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  one_rcvd=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [[ "$one_rcvd" =~ ^[0-9]+$ ]] && [ "$one_rcvd" -gt 0 ]; then
    # 只认端点与发出包完全对应的回包
    if one_rtt=$(tcp_nping_min_rtt "$raw"); then
      one_rcvd=1
    else
      one_rcvd=0
      one_rtt=""
    fi
  fi
}

# 逐包探测一个节点，输出：状态|省份|运营商|域名|IP|发送|收到|丢包率|平均延迟
tcp_probe_target() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" ip="$6" port="${7:-80}"
  if [ "$family" = "4" ] && [ -n "$ip" ] && ! tcp_is_public_v4 "$ip"; then
    ip=""
  fi
  if [ -z "$ip" ]; then
    echo "FAIL|$prov|$isp|$host|GETNODES|0|0|100.00|0"
    return
  fi

  local -a base=(--tcp -p "$port" --flags syn) l2=() cur=()
  local l2_ready=0 l2_failed=0 use_l2=0 route_data iface src smac dmac
  local sent=0 rcvd=0 rtt_sum="0" loss_pct avg_rtt one_sent one_rcvd one_rtt i
  local header_size=40 packet_size payload_size big_target=0 big_used=0 small_used=0 remaining big_rem small_rem
  if [ "$family" = "6" ]; then
    base=(-6 "${base[@]}")
    header_size=60
  fi
  [ "$TCP_LARGE_MODE" -eq 1 ] && big_target=$(((TCP_PACKETS * 3 + 3) / 4))
  if [ "$family" = "6" ] && [ "$TCP_V6_FORCE_L2" -eq 1 ]; then
    if route_data=$(tcp_v6_route "$ip"); then
      IFS='|' read -r iface src smac dmac <<< "$route_data"
      l2=(-6 -e "$iface" -S "$src" --source-mac "$smac" --dest-mac "$dmac" --tcp -p "$port" --flags syn)
      l2_ready=1
      use_l2=1
    else
      l2_failed=1
    fi
  fi

  for ((i = 1; i <= TCP_PACKETS; i++)); do
    case "$group" in
      cdn4|cdn6|cernet|cernet2) packet_size=$header_size ;;  # 标准 SYN，不带数据
      *)
        if [ -n "$TCP_PSIZE" ]; then
          packet_size=$TCP_PSIZE
        elif [ "$TCP_LARGE_MODE" -eq 1 ]; then
          remaining=$((TCP_PACKETS - i + 1))
          big_rem=$((big_target - big_used))
          small_rem=$((TCP_PACKETS - big_target - small_used))
          if [ "$big_rem" -ge "$remaining" ] || [ "$small_rem" -le 0 ] || [ $((RANDOM % remaining)) -lt "$big_rem" ]; then
            packet_size=${TCP_LARGE_BIG_SIZES[$((RANDOM % ${#TCP_LARGE_BIG_SIZES[@]}))]}
            big_used=$((big_used + 1))
          else
            packet_size=${TCP_LARGE_SMALL_SIZES[$((RANDOM % ${#TCP_LARGE_SMALL_SIZES[@]}))]}
            small_used=$((small_used + 1))
          fi
        else
          packet_size=$header_size
        fi
        ;;
    esac
    payload_size=$((packet_size - header_size))
    [ "$payload_size" -lt 0 ] && payload_size=0
    cur=("${base[@]}")
    [ "$use_l2" -eq 1 ] && cur=("${l2[@]}")
    tcp_nping_once "$ip" "$payload_size" "${cur[@]}"

    # IPv6 三层发包收不到回包时，改用二层（指定网卡与 MAC）重发
    if { ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || ! [[ "$one_rcvd" =~ ^[0-9]+$ ]] || [ "$one_rcvd" -eq 0 ]; } &&
       [ "$family" = "6" ] && [ "$use_l2" -eq 0 ] && [ "$l2_failed" -eq 0 ]; then
      if [ "$l2_ready" -eq 0 ]; then
        if route_data=$(tcp_v6_route "$ip"); then
          IFS='|' read -r iface src smac dmac <<< "$route_data"
          l2=(-6 -e "$iface" -S "$src" --source-mac "$smac" --dest-mac "$dmac" --tcp -p "$port" --flags syn)
          l2_ready=1
        else
          l2_failed=1
        fi
      fi
      if [ "$l2_ready" -eq 1 ]; then
        use_l2=1
        tcp_nping_once "$ip" "$payload_size" "${l2[@]}"
      fi
    fi

    if ! [[ "$one_sent" =~ ^[0-9]+$ ]] || [ "$one_sent" -ne 1 ] || ! [[ "$one_rcvd" =~ ^[0-9]+$ ]]; then
      echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
      return
    fi
    sent=$((sent + one_sent))
    if [ "$one_rcvd" -gt 0 ]; then
      if ! [[ "$one_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "FAIL|$prov|$isp|$host|$ip|0|0|100.00|NPING_ERROR"
        return
      fi
      rcvd=$((rcvd + 1))
      rtt_sum=$(awk -v a="$rtt_sum" -v b="$one_rtt" 'BEGIN { printf "%.6f", a + b }')
    fi
  done

  loss_pct=$(awk -v sent="$sent" -v rcvd="$rcvd" 'BEGIN { if (sent == 0) print "100.00"; else printf "%.2f", (sent - rcvd) * 100 / sent }')
  if [ "$rcvd" -gt 0 ]; then
    avg_rtt=$(awk -v sum="$rtt_sum" -v rcvd="$rcvd" 'BEGIN { printf "%.3f", sum / rcvd }')
  else
    avg_rtt=0
  fi
  echo "OK|$prov|$isp|$host|$ip|$sent|$rcvd|$loss_pct|$avg_rtt"
}

# 主备节点都测过且都成功时合并：丢包取平均，延迟取有效值的平均
tcp_combine() {
  local ps pp pi ph pip psent prcv ploss plat bs bp bi bh bip bsent brcv bloss blat sent rcv loss lat
  IFS='|' read -r ps pp pi ph pip psent prcv ploss plat <<< "$1"
  IFS='|' read -r bs bp bi bh bip bsent brcv bloss blat <<< "$2"
  if [ "$ps" != "OK" ] || [ "$bs" != "OK" ]; then
    echo "$2"
    return
  fi
  sent=$((psent + bsent))
  rcv=$((prcv + brcv))
  loss=$(awk -v a="$ploss" -v b="$bloss" 'BEGIN { printf "%.2f", (a + b) / 2 }')
  lat=$(awk -v a="$plat" -v b="$blat" 'BEGIN { if (a > 0 && b > 0) printf "%.3f", (a + b) / 2; else if (a > 0) printf "%.3f", a; else printf "%.3f", b }')
  echo "OK|$pp|$pi|$ph|$pip|$sent|$rcv|$loss|$lat"
}

# 测一个节点；主节点失败或丢包 >15% 时再测备用节点。结果写入 $TCP_DIR/组名_序号
tcp_test_one() {
  local group="$1" family="$2" prov="$3" isp="$4" host="$5" idx="$6"
  local ip="${7:-}" port="${8:-80}" bhost="${9:-}" bip="${10:-}" bport="${11:-80}"
  local outfile="$TCP_DIR/${group}_${idx}" primary backup p_status p_loss b_status b_loss
  primary=$(tcp_probe_target "$group" "$family" "$prov" "$isp" "$host" "$ip" "$port")
  IFS='|' read -r p_status _ _ _ _ _ _ p_loss _ <<< "$primary"

  if [ -n "$bip" ] &&
     { [ "$p_status" != "OK" ] || awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 > 15) }'; }; then
    backup=$(tcp_probe_target "$group" "$family" "$prov" "$isp" "$bhost" "$bip" "$bport")
    IFS='|' read -r b_status _ _ _ _ _ _ b_loss _ <<< "$backup"
    if [ "$p_status" != "OK" ] || awk -v loss="$p_loss" 'BEGIN { exit !(loss + 0 >= 100) }'; then
      printf "%s\n" "$backup" > "$outfile"
      return
    fi
    if [ "$b_status" = "OK" ]; then
      if awk -v loss="$b_loss" 'BEGIN { exit !(loss + 0 > 0) }'; then
        tcp_combine "$primary" "$backup" > "$outfile"
      else
        printf "%s\n" "$backup" > "$outfile"
      fi
      return
    fi
  fi
  printf "%s\n" "$primary" > "$outfile"
}

tcp_test_large_one() {
  local TCP_PSIZE="" TCP_LARGE_MODE=1
  tcp_test_one "$@"
}

# 大包预检：向 Cloudflare 发 20 个 1200B 包，丢包 >=80% 视为服务商防火墙限制大包
tcp_large_precheck() {
  local ip result status sent rcv loss _x
  ip=$(tcp_resolve4 "$TCP_LARGE_PRE_DOMAIN")
  if [ -z "$ip" ]; then
    TCP_LARGE_FW_LIMITED=1
    return 1
  fi
  local TCP_PACKETS="$TCP_LARGE_PRE_PACKETS" TCP_PSIZE="$TCP_LARGE_PRE_SIZE"
  result=$(tcp_probe_target largepre 4 "Cloudflare" "预检" "$TCP_LARGE_PRE_DOMAIN" "$ip" 443)
  IFS='|' read -r status _x _x _x _x sent rcv loss _x <<< "$result"
  if [ "$status" != "OK" ] || awk -v loss="${loss:-100}" 'BEGIN { exit !(loss + 0 >= 80) }'; then
    TCP_LARGE_FW_LIMITED=1
    return 1
  fi
  TCP_LARGE_FW_LIMITED=0
  return 0
}

# IPv6 预检：三层 nping 完全收不到回包时，后续 IPv6 探测直接走二层
tcp_v6_precheck() {
  local ip raw sent rcv
  TCP_V6_FORCE_L2=0
  ip=$(tcp_resolve6 "$TCP_LARGE_PRE_DOMAIN") || return 0
  raw=$(nping -6 --tcp -p 443 -g "$(tcp_nping_sport)" --seq "$(tcp_nping_seq)" --flags syn -c "$TCP_V6_PRE_PACKETS" "$ip" 2>&1)
  sent=$(printf "%s\n" "$raw" | sed -nE 's/.*sent:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  rcv=$(printf "%s\n" "$raw" | sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -gt 0 ] && ! tcp_nping_min_rtt "$raw" >/dev/null; then
    rcv=0
  fi
  if [[ "$sent" =~ ^[0-9]+$ ]] && [ "$sent" -gt 0 ] && [[ "$rcv" =~ ^[0-9]+$ ]] && [ "$rcv" -eq 0 ]; then
    TCP_V6_FORCE_L2=1
  fi
}

# ==================== 进度（stderr） ====================

# 统计已完成的结果文件数：route | probe
tcp_count_done() {
  local n=0 p f
  local -a pats=(cdn4 cdn6 large4 cernet cernet2)
  [ "$1" = "route" ] && pats=(route4 route6 lroute4 eroute4 eroute6)
  for p in "${pats[@]}"; do
    for f in "$TCP_DIR/${p}_"[0-9]*; do
      [ -e "$f" ] && n=$((n + 1))
    done
  done
  echo "$n"
}

tcp_prog_probe() {
  ui_prog "$TCP_STEP_PROBE $(ui_bar "$(tcp_count_done probe)" "$TCP_PROBE_TOTAL")"
}

tcp_wait_routes() {
  local done last=""
  [ -n "$TCP_ROUTE_PID" ] || return 0
  while kill -0 "$TCP_ROUTE_PID" 2>/dev/null; do
    done=$(tcp_count_done route)
    if [ "$done" != "$last" ]; then
      ui_prog "$TCP_STEP_ROUTE $(ui_bar "$done" "$TCP_ROUTE_TOTAL")"
      last=$done
    fi
    sleep 0.2
  done
  wait "$TCP_ROUTE_PID" 2>/dev/null
  TCP_ROUTE_PID=""
}

# 启动一组延迟/丢包探测：节点组 结果组 协议族 是否大包
tcp_probe_group() {
  local list="$1" group="$2" family="$3" large="${4:-0}" prov isp host ip port bhost bip bport bdef=80
  case "$list" in cernet|cernet2) bdef=443 ;; esac
  while IFS='|' read -r prov isp host ip port bhost bip bport; do
    TCP_IDX=$((TCP_IDX + 1))
    while [ $((TCP_IDX - $(tcp_count_done probe))) -gt "$TCP_PARALLEL" ]; do
      tcp_prog_probe
      sleep 0.2
    done
    if [ "$large" -eq 1 ]; then
      tcp_test_large_one "$group" "$family" "$prov" "$isp" "$host" "$TCP_IDX" "$ip" "${port:-80}" "$bhost" "$bip" "${bport:-$bdef}" &
    else
      tcp_test_one "$group" "$family" "$prov" "$isp" "$host" "$TCP_IDX" "$ip" "${port:-80}" "$bhost" "$bip" "${bport:-$bdef}" &
    fi
    tcp_prog_probe
  done < <(tcp_selected "$list")
}

# 按序号汇总某组结果到一个文件
tcp_gather() {
  local group="$1" out="$2" i
  : > "$out"
  for ((i = 1; i <= TCP_IDX; i++)); do
    [ -f "$TCP_DIR/${group}_${i}" ] && cat "$TCP_DIR/${group}_${i}" >> "$out"
  done
}

# ==================== 结果展示 ====================
# 每行不超过 80 列：三网/大包 2+省份6+2+(线路10 延迟5 丢包4)x3，以 " / " 分隔，共 79 列；
# 教育网 2+省份6+2+(线路18 延迟6 丢包6)x2，共 77 列。

# 单元格：标签 延迟 延迟色 丢包 丢包色 标签宽 延迟宽 丢包宽（色：G/Y/R/D）
tcp_cell() {
  local label="$1" lat="$2" latc="$3" loss="$4" lossc="$5" lw="$6" tw="$7" sw="$8" l t s
  local -A col=([G]="$C_G" [Y]="$C_Y" [R]="$C_R" [D]="$C_D")
  if [[ "$label" == *[^[:ascii:]]* ]]; then
    l=$(ui_pad "$label" "$lw")
  else
    # 超宽的组合线路先把 "->" 缩成 ">"（如 10099>9929），仍超宽则截断
    if [ "${#label}" -gt "$lw" ]; then
      label=${label//->/>}
      label=${label:0:$lw}
    fi
    printf -v l '%-*s' "$lw" "$label"
  fi
  printf -v t '%*s' "$tw" "$lat"
  printf -v s '%*s' "$sw" "$loss"
  printf '%s%s%s %s%s%s %s%s%s' "$C_W" "$l" "$C_0" "${col[$latc]}" "$t" "$C_0" "${col[$lossc]}" "$s" "$C_0"
}

# 结果行 → 制表行：省份\t键\t标签\t延迟\t延迟色\t丢包\t丢包色，末行 #\t零丢包\t1-20%\t>20%
# 颜色规则同原脚本：延迟 >240ms 或全丢红、151-240ms 黄；丢包 >20% 红、>0 黄
tcp_rows() {
  local mode="$1" route_file="$2" result_file="$3" nolabel="$4" tw="$5" key="${6:-}"
  awk -F'|' -v mode="$mode" -v nolabel="$nolabel" -v tw="$tw" -v key="$key" '
    function latc(v, l) { if (l >= 100) return "R"; if (v > 240) return "R"; if (v > 150) return "Y"; return "G" }
    function lossc(l) { if (l > 20) return "R"; if (l > 0) return "Y"; return "G" }
    function latt(v, l,   s) {
      if (l >= 100) return "-1ms"
      s = sprintf("%.0fms", v)
      if (length(s) > tw) s = sprintf("%.1fs", v / 1000)
      if (length(s) > tw) s = sprintf("%.0fs", v / 1000)
      return s
    }
    FILENAME == ARGV[1] {
      if (NF >= 6) route[$2 SUBSEP $3] = ($1 == "OK") ? $6 : "Hidden"
      next
    }
    {
      status = $1; prov = $2; isp = $3; loss = $8; lat = $9
      k = (key != "") ? key : isp
      if (mode == "edu") label = $10
      else label = ((prov SUBSEP isp) in route) ? route[prov SUBSEP isp] : (nolabel != "" ? nolabel : isp)
      if (label == "") label = "Hidden"
      if (status == "SKIP") { print prov "\t" k "\t" label "\t-\tR\t-\tR"; h++; next }
      if (status != "OK") { print prov "\t" k "\tfailed\t-\tR\t-\tR"; h++; next }
      l = loss + 0; v = lat + 0
      print prov "\t" k "\t" label "\t" latt(v, l) "\t" latc(v, l) "\t" int(loss + 0.5) "%\t" lossc(l)
      if (int(l) == 0) z++
      else if (int(l) <= 20) y++
      else h++
    }
    END { print "#\t" (z + 0) "\t" (y + 0) "\t" (h + 0) }
  ' "$route_file" "$result_file"
}

tcp_legend() {
  printf '  %s颜色: %s正常%s  %s延迟151-240ms或1-20%%重传%s  %s延迟>240ms或>20%%重传，或失败%s\n' \
    "$C_D" "$C_G" "$C_0" "$C_Y" "$C_0" "$C_R" "$C_0"
}

tcp_summary() {  # 前缀 零丢包文字 z y h
  printf '  %s%s%s:%3d%s    %s1-20%%:%3d%s    %s>20%%:%3d%s\n' "$1" "$C_G" "$2" "$3" "$C_0" "$C_Y" "$4" "$C_0" "$C_R" "$5" "$C_0"
}

# 三网 / 大包表格：标题 结果文件 线路文件 无线路时的占位 零丢包文字 防火墙受限
tcp_show_carrier() {
  local title="$1" result_file="$2" route_file="$3" nolabel="$4" zero_word="$5" fw="${6:-0}"
  local prov key label lat latc loss lossc z=0 y=0 h=0 isp row
  local -A cells=()
  local -a order=()
  while IFS=$'\t' read -r prov key label lat latc loss lossc; do
    if [ "$prov" = "#" ]; then
      z=$key; y=$label; h=$lat
      continue
    fi
    [ -n "${cells[$prov]+x}" ] || { order+=("$prov"); cells[$prov]=1; }
    cells["$prov|$key"]=$(tcp_cell "$label" "$lat" "$latc" "$loss" "$lossc" 10 5 4)
  done < <(tcp_rows carrier "$route_file" "$result_file" "$nolabel" 5)

  ui_sub "$title"
  tcp_summary "" "$zero_word" "$z" "$y" "$h"
  [ "$fw" -eq 1 ] && printf '  %s由于服务商防火墙限制，延迟和丢包无法探测%s\n' "$C_R" "$C_0"
  row="  ${C_BOLD}${C_C}$(ui_pad "省份" 6)${C_0}  "
  for isp in 电信 联通 移动; do
    [ "$isp" != "电信" ] && row+=" / "
    row+="${C_C}$(ui_pad "$isp" 10) $(ui_pad "延迟" 5 r) $(ui_pad "丢包" 4 r)${C_0}"
  done
  printf '%s\n' "$row"
  for prov in "${order[@]}"; do
    row="  ${C_C}$(ui_pad "$prov" 6)${C_0}  "
    for isp in 电信 联通 移动; do
      [ "$isp" != "电信" ] && row+=" / "
      row+="${cells["$prov|$isp"]:-$(tcp_cell "-" "-" D "-" D 10 5 4)}"
    done
    printf '%s\n' "$row"
  done
  tcp_legend
}

# 教育网表格：每个参数为 “列标题|结果文件”，一列或两列
tcp_show_edu() {
  local spec col file prov key label lat latc loss lossc row n=0
  local -A cells=() sums=()
  local -a order=() cols=()
  for spec in "$@"; do
    col=${spec%%|*}
    file=${spec#*|}
    cols+=("$col")
    while IFS=$'\t' read -r prov key label lat latc loss lossc; do
      if [ "$prov" = "#" ]; then
        sums[$col]="$key $label $lat"
        continue
      fi
      [ -n "${cells[$prov]+x}" ] || { order+=("$prov"); cells[$prov]=1; }
      cells["$prov|$col"]=$(tcp_cell "$label" "$lat" "$latc" "$loss" "$lossc" 18 6 6)
    done < <(tcp_rows edu /dev/null "$file" "" 6 "$col")
  done

  ui_sub "教育网回程"
  for col in "${cols[@]}"; do
    tcp_summary "$(ui_pad "$col" 13)" "零丢包" ${sums[$col]}
  done
  row="  ${C_BOLD}${C_C}$(ui_pad "省份" 6)${C_0}  "
  for col in "${cols[@]}"; do
    [ "$n" -gt 0 ] && row+=" / "
    row+="${C_C}$(ui_pad "$col" 18) $(ui_pad "延迟" 6 r) $(ui_pad "丢包" 6 r)${C_0}"
    n=$((n + 1))
  done
  printf '%s\n' "$row"
  for prov in "${order[@]}"; do
    row="  ${C_C}$(ui_pad "$prov" 6)${C_0}  "
    n=0
    for col in "${cols[@]}"; do
      [ "$n" -gt 0 ] && row+=" / "
      row+="${cells["$prov|$col"]:-$(tcp_cell "-" "-" D "-" D 18 6 6)}"
      n=$((n + 1))
    done
    printf '%s\n' "$row"
  done
  tcp_legend
}

# 教育网结果附上线路标签（第 10 列），与原脚本一致：识别失败记 Hidden，探测失败记 failed
tcp_edu_attach() {
  local result_file="$1" label_file="$2" out="$3" ran="$4" status prov isp host ip snd rcv loss lat label
  : > "$out"
  while IFS='|' read -r status prov isp host ip snd rcv loss lat; do
    if [ "$ran" -eq 1 ]; then
      label=$(awk -F'|' -v p="$prov" '$2 == p { if ($1 == "OK") print $6; else print "Hidden"; exit }' "$label_file")
      label=${label:-Hidden}
    else
      label=$TCP_NOLABEL
    fi
    [ "$status" != "OK" ] && [ "$status" != "SKIP" ] && label="failed"
    echo "$status|$prov|$isp|$host|$ip|$snd|$rcv|$loss|$lat|$label" >> "$out"
  done < "$result_file"
}

# ==================== 入口 ====================

tcp_run() {
  local has_tr=0 has_nt=0 n4=0 n6=0 ne4=0 ne6=0 i large_n=0 prov isp host ip _r
  local d
  ui_section "TCP 回程"

  if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
    ui_err "临时目录不可用，已跳过回程检测"
    return 1
  fi
  deps_ok nping || return 0
  TCP_DIR="$WORKDIR/tcp"
  rm -rf "$TCP_DIR"
  mkdir -p "$TCP_DIR" || { ui_err "无法创建临时目录 $TCP_DIR"; return 1; }

  TCP_PACKETS=$TCP_PACKETS_DEFAULT
  if [[ "$OPT_COUNT" =~ ^[0-9]+$ ]] && [ "$OPT_COUNT" -ge 1 ] && [ "$OPT_COUNT" -le 600 ]; then
    TCP_PACKETS=$OPT_COUNT
  fi
  TCP_PARALLEL=$(tcp_auto_parallel)
  TCP_IDX=0
  TCP_LARGE_FW_LIMITED=0
  TCP_V6_FORCE_L2=0
  tcp_set_provinces

  TCP_DO_P4=$((TCP_ROUTE * RUN_V4))
  TCP_DO_P6=$((TCP_ROUTE * RUN_V6))
  TCP_DO_L=$((TCP_LARGE * RUN_V4))
  TCP_DO_E4=$((TCP_EDU * RUN_V4))
  TCP_DO_E6=$((TCP_EDU * RUN_V6))
  if [ $((TCP_DO_P4 + TCP_DO_P6 + TCP_DO_L + TCP_DO_E4 + TCP_DO_E6)) -eq 0 ]; then
    ui_warn "没有可执行的回程检测项目"
    return 0
  fi

  command -v traceroute >/dev/null 2>&1 && has_tr=1
  command -v nexttrace-tiny >/dev/null 2>&1 && has_nt=1
  if [ "$has_tr" -eq 0 ] && [ $((TCP_DO_P4 + TCP_DO_P6 + TCP_DO_E4 + TCP_DO_E6)) -gt 0 ]; then
    ui_warn "缺少 traceroute，线路未识别"
  fi
  if [ "$has_nt" -eq 0 ] && [ "$TCP_DO_L" -eq 1 ]; then
    ui_warn "缺少 nexttrace-tiny，大包线路未识别"
  fi
  TCP_DO_R4=$((TCP_DO_P4 * has_tr))
  TCP_DO_R6=$((TCP_DO_P6 * has_tr))
  TCP_DO_LR=$((TCP_DO_L * has_nt))
  TCP_DO_ER4=$((TCP_DO_E4 * has_tr))
  TCP_DO_ER6=$((TCP_DO_E6 * has_tr))

  ui_prog "正在获取回程节点"
  tcp_load_nodes
  n4=$(tcp_count cdn4)
  n6=$(tcp_count cdn6)
  ne4=$(tcp_count cernet)
  ne6=$(tcp_count cernet2)
  TCP_ROUTE_TOTAL=$((TCP_DO_R4 * n4 + TCP_DO_LR * n4 + TCP_DO_R6 * n6 + TCP_DO_ER4 * ne4 + TCP_DO_ER6 * ne6))
  TCP_PROBE_TOTAL=$((TCP_DO_P4 * n4 + TCP_DO_L * n4 + TCP_DO_P6 * n6 + TCP_DO_E4 * ne4 + TCP_DO_E6 * ne6))
  if [ "$TCP_PROBE_TOTAL" -eq 0 ]; then
    ui_warn "所选省份没有可检测的节点"
    return 0
  fi

  # 第一阶段：回程线路识别（后台），结束后才发 nping，避免探测流量影响路由响应
  if [ "$TCP_ROUTE_TOTAL" -gt 0 ]; then
    TCP_STEP_ROUTE="[1/2] 回程线路识别"
    TCP_STEP_PROBE="[2/2] 延迟丢包探测"
    tcp_start_routes
    tcp_wait_routes
  else
    TCP_STEP_PROBE="延迟丢包探测"
  fi

  # 第二阶段：预检
  if [ $((TCP_DO_P6 + TCP_DO_E6)) -gt 0 ]; then
    ui_prog "${TCP_STEP_PROBE} IPv6 预检"
    tcp_v6_precheck
  fi
  if [ "$TCP_DO_L" -eq 1 ]; then
    ui_prog "${TCP_STEP_PROBE} 大包预检"
    if ! tcp_large_precheck; then
      TCP_PROBE_TOTAL=$((TCP_PROBE_TOTAL - n4))
    fi
  fi

  # 第三阶段：延迟 / 丢包探测
  tcp_prog_probe
  [ "$TCP_DO_P4" -eq 1 ] && tcp_probe_group cdn4 cdn4 4
  [ "$TCP_DO_P6" -eq 1 ] && tcp_probe_group cdn6 cdn6 6
  [ "$TCP_DO_L" -eq 1 ] && [ "$TCP_LARGE_FW_LIMITED" -eq 0 ] && tcp_probe_group cdn4 large4 4 1
  [ "$TCP_DO_E4" -eq 1 ] && tcp_probe_group cernet cernet 4
  [ "$TCP_DO_E6" -eq 1 ] && tcp_probe_group cernet2 cernet2 6
  while [ $((TCP_IDX - $(tcp_count_done probe))) -gt 0 ]; do
    tcp_prog_probe
    sleep 0.2
  done
  # 先结束进度显示的后台进程，否则下面的 wait 会一直等它
  ui_prog_clear
  wait

  # 大包被防火墙限制：各节点记为 SKIP（线路照常展示，延迟丢包为 -）
  if [ "$TCP_DO_L" -eq 1 ] && [ "$TCP_LARGE_FW_LIMITED" -eq 1 ]; then
    i=0
    while IFS='|' read -r prov isp host ip _r; do
      i=$((i + 1))
      printf 'SKIP|%s|%s|%s|%s|0|0|-|-\n' "$prov" "$isp" "$host" "${ip:-FIREWALL_LIMITED}" > "$TCP_DIR/large4_$i"
      large_n=$i
    done < <(tcp_selected cdn4)
    [ "$large_n" -gt "$TCP_IDX" ] && TCP_IDX=$large_n
  fi

  # 汇总与展示
  d="$TCP_DIR"
  if [ "$TCP_DO_P4" -eq 1 ]; then
    tcp_gather cdn4 "$d/res_cdn4"
    if [ "$TCP_DO_R4" -eq 1 ]; then
      tcp_show_carrier "三网回程 · IPv4" "$d/res_cdn4" "$d/label_route4" "" "零丢包" 0
    else
      tcp_show_carrier "三网回程 · IPv4" "$d/res_cdn4" /dev/null "$TCP_NOLABEL" "零丢包" 0
    fi
  fi
  if [ "$TCP_DO_P6" -eq 1 ]; then
    tcp_gather cdn6 "$d/res_cdn6"
    if [ "$TCP_DO_R6" -eq 1 ]; then
      tcp_show_carrier "三网回程 · IPv6" "$d/res_cdn6" "$d/label_route6" "" "零丢包" 0
    else
      tcp_show_carrier "三网回程 · IPv6" "$d/res_cdn6" /dev/null "$TCP_NOLABEL" "零丢包" 0
    fi
  fi
  if [ "$TCP_DO_L" -eq 1 ]; then
    tcp_gather large4 "$d/res_large4"
    if [ "$TCP_DO_LR" -eq 1 ]; then
      tcp_show_carrier "大包回程 · IPv4" "$d/res_large4" "$d/label_large4" "" "零重传" "$TCP_LARGE_FW_LIMITED"
    else
      tcp_show_carrier "大包回程 · IPv4" "$d/res_large4" /dev/null "$TCP_NOLABEL" "零重传" "$TCP_LARGE_FW_LIMITED"
    fi
  fi
  if [ $((TCP_DO_E4 + TCP_DO_E6)) -gt 0 ]; then
    local -a edu=()
    if [ "$TCP_DO_E4" -eq 1 ]; then
      tcp_gather cernet "$d/res_cernet.raw"
      tcp_edu_attach "$d/res_cernet.raw" "$d/label_edu4" "$d/res_cernet" "$TCP_DO_ER4"
      edu+=("CERNET-IPv4|$d/res_cernet")
    fi
    if [ "$TCP_DO_E6" -eq 1 ]; then
      tcp_gather cernet2 "$d/res_cernet2.raw"
      tcp_edu_attach "$d/res_cernet2.raw" "$d/label_edu6" "$d/res_cernet2" "$TCP_DO_ER6"
      edu+=("CERNET2-IPv6|$d/res_cernet2")
    fi
    tcp_show_edu "${edu[@]}"
  fi
  return 0
}

# ==================== 内置节点快照 ====================
# getNodes 不可用时使用；来源 https://tcpquality.ibsgss.uk/getNodes?format=tsv&scope=all
# （只保留 cdn / cernet / cernet2，获取于 2026-10-19）
tcp_nodes_snapshot() {
  cat <<'TCP_NODES_EOF'
type	family	province	isp	host	ip	port	target	backup_host	backup_ip	backup_port	backup_target
cdn	4	河北	电信	he-ct-v4.ibsgss.uk	219.148.62.1	80	he-ct-v4.ip.zstaticcdn.com	bak.he-ct-v4.ibsgss.uk	144.7.111.241	80	he-xiongan-ct-v4.ip.zstaticcdn.com
cdn	6	河北	电信	he-ct-v6.ibsgss.uk	240e:b1:c802:0:8000:0:b00:99	80	he-ct-v6.ip.zstaticcdn.com	bak.he-ct-v6.ibsgss.uk		80	sjz-ct-v6.ip.zstaticcdn.com
cdn	4	河北	联通	he-cu-v4.ibsgss.uk	110.249.198.53	80	he-cu-v4.ip.zstaticcdn.com	bak.he-cu-v4.ibsgss.uk	120.52.92.249	80	he-langfang-cu-v4.ip.zstaticcdn.com
cdn	6	河北	联通	he-cu-v6.ibsgss.uk	2408:871a:a100:8:8000:0:b00:79	80	he-cu-v6.ip.zstaticcdn.com	bak.he-cu-v6.ibsgss.uk		80	sjz-cu-v6.ip.zstaticcdn.com
cdn	4	河北	移动	he-cm-v4.ibsgss.uk	111.63.63.207	80	he-cm-v4.ip.zstaticcdn.com	bak.he-cm-v4.ibsgss.uk		80	sjz-cm-v4.ip.zstaticcdn.com
cdn	6	河北	移动	he-cm-v6.ibsgss.uk	2409:8c20:a11:f001:8000:0:b00:84	80	he-cm-v6.ip.zstaticcdn.com	bak.he-cm-v6.ibsgss.uk		80	sjz-cm-v6.ip.zstaticcdn.com
cdn	4	山西	电信	sx-ct-v4.ibsgss.uk	113.24.210.59	80	sx-ct-v4.ip.zstaticcdn.com	bak.sx-ct-v4.ibsgss.uk	1.71.6.232	80	sx-taiyuan-ct-v4.ip.zstaticcdn.com
cdn	6	山西	电信	sx-ct-v6.ibsgss.uk	240e:925:2:400:8000:0:b00:98	80	sx-ct-v6.ip.zstaticcdn.com	bak.sx-ct-v6.ibsgss.uk		80	ty-ct-v6.ip.zstaticcdn.com
cdn	4	山西	联通	sx-cu-v4.ibsgss.uk	121.30.176.170	80	sx-cu-v4.ip.zstaticcdn.com	bak.sx-cu-v4.ibsgss.uk	60.220.186.44	80	sx-changzhi-cu-v4.ip.zstaticcdn.com
cdn	6	山西	联通	sx-cu-v6.ibsgss.uk	2408:8726:5400:100:8000:0:b00:87	80	sx-cu-v6.ip.zstaticcdn.com	bak.sx-cu-v6.ibsgss.uk		80	ty-cu-v6.ip.zstaticcdn.com
cdn	4	山西	移动	sx-cm-v4.ibsgss.uk	183.201.125.189	80	sx-cm-v4.ip.zstaticcdn.com	bak.sx-cm-v4.ibsgss.uk		80	ty-cm-v4.ip.zstaticcdn.com
cdn	6	山西	移动	sx-cm-v6.ibsgss.uk	2409:8c0c:310:2401::b00:79	80	sx-cm-v6.ip.zstaticcdn.com	bak.sx-cm-v6.ibsgss.uk		80	ty-cm-v6.ip.zstaticcdn.com
cdn	4	辽宁	电信	ln-ct-v4.ibsgss.uk	42.202.219.237	80	ln-ct-v4.ip.zstaticcdn.com	bak.ln-ct-v4.ibsgss.uk	123.187.241.248	80	ln-liaoyang-ct-v4.ip.zstaticcdn.com
cdn	6	辽宁	电信	ln-ct-v6.ibsgss.uk	240e:90c:a201:100:8000:0:b00:69	80	ln-ct-v6.ip.zstaticcdn.com	bak.ln-ct-v6.ibsgss.uk		80	sy-ct-v6.ip.zstaticcdn.com
cdn	4	辽宁	联通	ln-cu-v4.ibsgss.uk	42.59.0.146	80	ln-cu-v4.ip.zstaticcdn.com	bak.ln-cu-v4.ibsgss.uk	123.188.232.40	80	ln-chaoyang-cu-v4.ip.zstaticcdn.com
cdn	6	辽宁	联通	ln-cu-v6.ibsgss.uk	2408:8630:20b0:3:8000:0:b00:228	80	ln-cu-v6.ip.zstaticcdn.com	bak.ln-cu-v6.ibsgss.uk		80	sy-cu-v6.ip.zstaticcdn.com
cdn	4	辽宁	移动	ln-cm-v4.ibsgss.uk	111.26.225.253	80	ln-cm-v4.ip.zstaticcdn.com	bak.ln-cm-v4.ibsgss.uk	221.180.166.1	80	ln.10086.cn
cdn	6	辽宁	移动	ln-cm-v6.ibsgss.uk	2409:8c18:700:1002:8000:0:b00:227	80	ln-cm-v6.ip.zstaticcdn.com	bak.ln-cm-v6.ibsgss.uk		80	sy-cm-v6.ip.zstaticcdn.com
cdn	4	吉林	电信	jl-ct-v4.ibsgss.uk	36.104.133.171	80	jl-ct-v4.ip.zstaticcdn.com	bak.jl-ct-v4.ibsgss.uk	36.97.235.3	443	jl.189.cn
cdn	6	吉林	电信	jl-ct-v6.ibsgss.uk	240e:910:e000:201:8000:0:b00:98	80	jl-ct-v6.ip.zstaticcdn.com	bak.jl-ct-v6.ibsgss.uk		80	cc-ct-v6.ip.zstaticcdn.com
cdn	4	吉林	联通	jl-cu-v4.ibsgss.uk	101.28.250.249	80	jl-cu-v4.ip.zstaticcdn.com	bak.jl-cu-v4.ibsgss.uk	139.215.227.2	80	jl-changchun-cu-v4.ip.zstaticcdn.com
cdn	6	吉林	联通	jl-cu-v6.ibsgss.uk	2408:871a:a100:8:8000:0:b00:79	80	jl-cu-v6.ip.zstaticcdn.com	bak.jl-cu-v6.ibsgss.uk		80	cc-cu-v6.ip.zstaticcdn.com
cdn	4	吉林	移动	jl-cm-v4.ibsgss.uk	111.26.225.209	80	jl-cm-v4.ip.zstaticcdn.com	bak.jl-cm-v4.ibsgss.uk		80	cc-cm-v4.ip.zstaticcdn.com
cdn	6	吉林	移动	jl-cm-v6.ibsgss.uk	2409:8c18:700:300d:8000:0:b00:71	80	jl-cm-v6.ip.zstaticcdn.com	bak.jl-cm-v6.ibsgss.uk		80	cc-cm-v6.ip.zstaticcdn.com
cdn	4	黑龙江	电信	hl-ct-v4.ibsgss.uk	42.101.49.95	80	hl-ct-v4.ip.zstaticcdn.com	bak.hl-ct-v4.ibsgss.uk	219.147.133.224	80	hl.189.cn
cdn	6	黑龙江	电信	hl-ct-v6.ibsgss.uk	240e:908:8106:2:8000:0:b00:33	80	hl-ct-v6.ip.zstaticcdn.com	bak.hl-ct-v6.ibsgss.uk		80	hrb-ct-v6.ip.zstaticcdn.com
cdn	4	黑龙江	联通	hl-cu-v4.ibsgss.uk	221.207.117.203	80	hl-cu-v4.ip.zstaticcdn.com	bak.hl-cu-v4.ibsgss.uk	122.156.220.108	80	hl-daqing-cu-v4.ip.zstaticcdn.com
cdn	6	黑龙江	联通	hl-cu-v6.ibsgss.uk	2408:8738:4000:4::b00:74	80	hl-cu-v6.ip.zstaticcdn.com	bak.hl-cu-v6.ibsgss.uk		80	hrb-cu-v6.ip.zstaticcdn.com
cdn	4	黑龙江	移动	hl-cm-v4.ibsgss.uk	111.26.225.253	80	hl-cm-v4.ip.zstaticcdn.com	bak.hl-cm-v4.ibsgss.uk		80	hrb-cm-v4.ip.zstaticcdn.com
cdn	6	黑龙江	移动	hl-cm-v6.ibsgss.uk	2409:8c02:11c:38::b00:146	80	hl-cm-v6.ip.zstaticcdn.com	bak.hl-cm-v6.ibsgss.uk		80	hrb-cm-v6.ip.zstaticcdn.com
cdn	4	江苏	电信	js-ct-v4.ibsgss.uk	180.102.111.180	80	js-ct-v4.ip.zstaticcdn.com	bak.js-ct-v4.ibsgss.uk	117.62.239.129	80	js-nanjing-ct-v4.ip.zstaticcdn.com
cdn	6	江苏	电信	js-ct-v6.ibsgss.uk	240e:979:9509:180::b00:81	80	js-ct-v6.ip.zstaticcdn.com	bak.js-ct-v6.ibsgss.uk		80	nj-ct-v6.ip.zstaticcdn.com
cdn	4	江苏	联通	js-cu-v4.ibsgss.uk	112.86.231.245	80	js-cu-v4.ip.zstaticcdn.com	bak.js-cu-v4.ibsgss.uk	112.86.231.59	80	js-nanjing-cu-v4.ip.zstaticcdn.com
cdn	6	江苏	联通	js-cu-v6.ibsgss.uk	2408:873c:6010:5:8000:0:b00:77	80	js-cu-v6.ip.zstaticcdn.com	bak.js-cu-v6.ibsgss.uk		80	nj-cu-v6.ip.zstaticcdn.com
cdn	4	江苏	移动	js-cm-v4.ibsgss.uk	36.155.201.108	80	js-cm-v4.ip.zstaticcdn.com	bak.js-cm-v4.ibsgss.uk	36.133.24.129	80	js-wuxi-cm-v4.ip.zstaticcdn.com
cdn	6	江苏	移动	js-cm-v6.ibsgss.uk	2409:8c20:6ed1:10c:8000:0:b00:138	80	js-cm-v6.ip.zstaticcdn.com	bak.js-cm-v6.ibsgss.uk		80	nj-cm-v6.ip.zstaticcdn.com
cdn	4	浙江	电信	zj-ct-v4.ibsgss.uk	183.131.147.4	80	zj-ct-v4.ip.zstaticcdn.com	bak.zj-ct-v4.ibsgss.uk	125.122.86.249	80	zj-hangzhou-ct-v4.ip.zstaticcdn.com
cdn	6	浙江	电信	zj-ct-v6.ibsgss.uk	240e:f7:c000:30f:8000:0:b00:216	80	zj-ct-v6.ip.zstaticcdn.com	bak.zj-ct-v6.ibsgss.uk		80	hz-ct-v6.ip.zstaticcdn.com
cdn	4	浙江	联通	zj-cu-v4.ibsgss.uk	60.12.119.66	80	zj-cu-v4.ip.zstaticcdn.com	bak.zj-cu-v4.ibsgss.uk	116.148.187.12	80	zj-huzhou-cu-v4.ip.zstaticcdn.com
cdn	6	浙江	联通	zj-cu-v6.ibsgss.uk	2408:873c:6810:5:8000:0:b00:220	80	zj-cu-v6.ip.zstaticcdn.com	bak.zj-cu-v6.ibsgss.uk		80	hz-cu-v6.ip.zstaticcdn.com
cdn	4	浙江	移动	zj-cm-v4.ibsgss.uk	112.13.92.194	80	zj-cm-v4.ip.zstaticcdn.com	bak.zj-cm-v4.ibsgss.uk	36.133.95.128	80	zj-ningbo-cm-v4.ip.zstaticcdn.com
cdn	6	浙江	移动	zj-cm-v6.ibsgss.uk	2409:8c28:c05:41:8000:0:b00:57	80	zj-cm-v6.ip.zstaticcdn.com	bak.zj-cm-v6.ibsgss.uk		80	hz-cm-v6.ip.zstaticcdn.com
cdn	4	安徽	电信	ah-ct-v4.ibsgss.uk	117.68.18.49	80	ah-ct-v4.ip.zstaticcdn.com	bak.ah-ct-v4.ibsgss.uk	117.68.126.249	80	ah-wuhu-ct-v4.ip.zstaticcdn.com
cdn	6	安徽	电信	ah-ct-v6.ibsgss.uk	240e:958:2004:1:8000:0:b00:98	80	ah-ct-v6.ip.zstaticcdn.com	bak.ah-ct-v6.ibsgss.uk		80	hf-ct-v6.ip.zstaticcdn.com
cdn	4	安徽	联通	ah-cu-v4.ibsgss.uk	112.132.39.170	80	ah-cu-v4.ip.zstaticcdn.com	bak.ah-cu-v4.ibsgss.uk	218.104.71.170	80	ah-hefei-cu-v4.ip.zstaticcdn.com
cdn	6	安徽	联通	ah-cu-v6.ibsgss.uk	2406:8880:0:4:8000:0:b00:93	80	ah-cu-v6.ip.zstaticcdn.com	bak.ah-cu-v6.ibsgss.uk		80	hf-cu-v6.ip.zstaticcdn.com
cdn	4	安徽	移动	ah-cm-v4.ibsgss.uk	39.145.24.48	80	ah-cm-v4.ip.zstaticcdn.com	bak.ah-cm-v4.ibsgss.uk	202.141.176.110	80	ah-hefei-cm-v4.ip.zstaticcdn.com
cdn	6	安徽	移动	ah-cm-v6.ibsgss.uk	2409:8c30:1000:1a01:8000:0:b00:224	80	ah-cm-v6.ip.zstaticcdn.com	bak.ah-cm-v6.ibsgss.uk		80	hf-cm-v6.ip.zstaticcdn.com
cdn	4	福建	电信	fj-ct-v4.ibsgss.uk	106.126.9.253	80	fj-ct-v4.ip.zstaticcdn.com	bak.fj-ct-v4.ibsgss.uk	203.55.129.248	80	fj-fuzhou-ct-v4.ip.zstaticcdn.com
cdn	6	福建	电信	fj-ct-v6.ibsgss.uk	240e:d6:6666:25:8000:0:b00:95	80	fj-ct-v6.ip.zstaticcdn.com	bak.fj-ct-v6.ibsgss.uk		80	fz-ct-v6.ip.zstaticcdn.com
cdn	4	福建	联通	fj-cu-v4.ibsgss.uk	36.248.48.210	80	fj-cu-v4.ip.zstaticcdn.com	bak.fj-cu-v4.ibsgss.uk	218.107.193.105	80	fj-xiamen-cu-v4.ip.zstaticcdn.com
cdn	6	福建	联通	fj-cu-v6.ibsgss.uk	2408:8748:a101:218:8000:0:b00:83	80	fj-cu-v6.ip.zstaticcdn.com	bak.fj-cu-v6.ibsgss.uk		80	fz-cu-v6.ip.zstaticcdn.com
cdn	4	福建	移动	fj-cm-v4.ibsgss.uk	112.48.173.86	80	fj-cm-v4.ip.zstaticcdn.com	bak.fj-cm-v4.ibsgss.uk		80	fz-cm-v4.ip.zstaticcdn.com
cdn	6	福建	移动	fj-cm-v6.ibsgss.uk	2409:8c34:2220:5:8000:0:b00:98	80	fj-cm-v6.ip.zstaticcdn.com	bak.fj-cm-v6.ibsgss.uk		80	fz-cm-v6.ip.zstaticcdn.com
cdn	4	江西	电信	jx-ct-v4.ibsgss.uk	117.21.179.2	80	jx-ct-v4.ip.zstaticcdn.com	bak.jx-ct-v4.ibsgss.uk	117.21.249.187	443	jx.189.cn
cdn	6	江西	电信	jx-ct-v6.ibsgss.uk	240e:960:3601:1:8000:0:b00:46	80	jx-ct-v6.ip.zstaticcdn.com	bak.jx-ct-v6.ibsgss.uk		80	nc-ct-v6.ip.zstaticcdn.com
cdn	4	江西	联通	jx-cu-v4.ibsgss.uk	116.153.32.148	80	jx-cu-v4.ip.zstaticcdn.com	bak.jx-cu-v4.ibsgss.uk	113.195.207.112	80	jx-fuzhou-cu-v4.ip.zstaticcdn.com
cdn	6	江西	联通	jx-cu-v6.ibsgss.uk	2408:874c:1ff:100:8000:0:b00:86	80	jx-cu-v6.ip.zstaticcdn.com	bak.jx-cu-v6.ibsgss.uk		80	nc-cu-v6.ip.zstaticcdn.com
cdn	4	江西	移动	jx-cm-v4.ibsgss.uk	117.169.96.226	80	jx-cm-v4.ip.zstaticcdn.com	bak.jx-cm-v4.ibsgss.uk		80	nc-cm-v4.ip.zstaticcdn.com
cdn	6	江西	移动	jx-cm-v6.ibsgss.uk	2409:8c50:a00:2073:8000:0:b00:44	80	jx-cm-v6.ip.zstaticcdn.com	bak.jx-cm-v6.ibsgss.uk		80	nc-cm-v6.ip.zstaticcdn.com
cdn	4	山东	电信	sd-ct-v4.ibsgss.uk	140.249.80.214	80	sd-ct-v4.ip.zstaticcdn.com	bak.sd-ct-v4.ibsgss.uk	182.40.97.247	80	sd-qingdao-ct-v4.ip.zstaticcdn.com
cdn	6	山东	电信	sd-ct-v6.ibsgss.uk	240e:946:3009:0:8000:0:b00:87	80	sd-ct-v6.ip.zstaticcdn.com	bak.sd-ct-v6.ibsgss.uk		80	jn-ct-v6.ip.zstaticcdn.com
cdn	4	山东	联通	sd-cu-v4.ibsgss.uk	61.179.131.126	80	sd-cu-v4.ip.zstaticcdn.com	bak.sd-cu-v4.ibsgss.uk	61.133.126.16	80	sd-binzhou-cu-v4.ip.zstaticcdn.com
cdn	6	山东	联通	sd-cu-v6.ibsgss.uk	2408:8719:64:70:8000:0:b00:218	80	sd-cu-v6.ip.zstaticcdn.com	bak.sd-cu-v6.ibsgss.uk		80	jn-cu-v6.ip.zstaticcdn.com
cdn	4	山东	移动	sd-cm-v4.ibsgss.uk	120.221.173.226	80	sd-cm-v4.ip.zstaticcdn.com	bak.sd-cm-v4.ibsgss.uk	36.133.120.128	80	sd-jinan-cm-v4.ip.zstaticcdn.com
cdn	6	山东	移动	sd-cm-v6.ibsgss.uk	2409:8c3c:900:200:8000:0:b00:89	80	sd-cm-v6.ip.zstaticcdn.com	bak.sd-cm-v6.ibsgss.uk		80	jn-cm-v6.ip.zstaticcdn.com
cdn	4	河南	电信	ha-ct-v4.ibsgss.uk	171.15.110.251	80	ha-ct-v4.ip.zstaticcdn.com	bak.ha-ct-v4.ibsgss.uk	1.194.160.249	80	ha-zhengzhou-ct-v4.ip.zstaticcdn.com
cdn	6	河南	电信	ha-ct-v6.ibsgss.uk	240e:93c:209:2:8000:0:b00:55	80	ha-ct-v6.ip.zstaticcdn.com	bak.ha-ct-v6.ibsgss.uk		80	zz-ct-v6.ip.zstaticcdn.com
cdn	4	河南	联通	ha-cu-v4.ibsgss.uk	221.15.71.2	80	ha-cu-v4.ip.zstaticcdn.com	bak.ha-cu-v4.ibsgss.uk	221.15.71.2	80	ha-luoyang-cu-v4.ip.zstaticcdn.com
cdn	6	河南	联通	ha-cu-v6.ibsgss.uk	2408:8720:806:100:8000:0:b00:223	80	ha-cu-v6.ip.zstaticcdn.com	bak.ha-cu-v6.ibsgss.uk		80	zz-cu-v6.ip.zstaticcdn.com
cdn	4	河南	移动	ha-cm-v4.ibsgss.uk	111.6.167.130	80	ha-cm-v4.ip.zstaticcdn.com	bak.ha-cm-v4.ibsgss.uk	36.133.36.128	80	ha-zhengzhou-cm-v4.ip.zstaticcdn.com
cdn	6	河南	移动	ha-cm-v6.ibsgss.uk	2409:8c44:2:ff16:8000:0:b00:86	80	ha-cm-v6.ip.zstaticcdn.com	bak.ha-cm-v6.ibsgss.uk		80	zz-cm-v6.ip.zstaticcdn.com
cdn	4	湖北	电信	hb-ct-v4.ibsgss.uk	111.174.12.90	80	hb-ct-v4.ip.zstaticcdn.com	bak.hb-ct-v4.ibsgss.uk	171.43.197.25	80	hb-wuhan-ct-v4.ip.zstaticcdn.com
cdn	6	湖北	电信	hb-ct-v6.ibsgss.uk	240e:95d:1904:ff:8000:0:b00:90	80	hb-ct-v6.ip.zstaticcdn.com	bak.hb-ct-v6.ibsgss.uk		80	wh-ct-v6.ip.zstaticcdn.com
cdn	4	湖北	联通	hb-cu-v4.ibsgss.uk	220.202.13.176	80	hb-cu-v4.ip.zstaticcdn.com	bak.hb-cu-v4.ibsgss.uk	61.242.167.105	80	hb-ezhou-cu-v4.ip.zstaticcdn.com
cdn	6	湖北	联通	hb-cu-v6.ibsgss.uk	2408:874f:a000:1:8000:0:b00:90	80	hb-cu-v6.ip.zstaticcdn.com	bak.hb-cu-v6.ibsgss.uk		80	wh-cu-v6.ip.zstaticcdn.com
cdn	4	湖北	移动	hb-cm-v4.ibsgss.uk	111.48.110.33	80	hb-cm-v4.ip.zstaticcdn.com	bak.hb-cm-v4.ibsgss.uk		80	wh-cm-v4.ip.zstaticcdn.com
cdn	6	湖北	移动	hb-cm-v6.ibsgss.uk	2409:8c4c:e00:210:8000:0:b00:87	80	hb-cm-v6.ip.zstaticcdn.com	bak.hb-cm-v6.ibsgss.uk		80	wh-cm-v6.ip.zstaticcdn.com
cdn	4	湖南	电信	hn-ct-v4.ibsgss.uk	202.103.124.48	80	hn-ct-v4.ip.zstaticcdn.com	bak.hn-ct-v4.ibsgss.uk	175.6.215.252	80	hn-chenzhou-ct-v4.ip.zstaticcdn.com
cdn	6	湖南	电信	hn-ct-v6.ibsgss.uk	240e:c2:1800:19b:8000:0:b00:46	80	hn-ct-v6.ip.zstaticcdn.com	bak.hn-ct-v6.ibsgss.uk		80	cs-ct-v6.ip.zstaticcdn.com
cdn	4	湖南	联通	hn-cu-v4.ibsgss.uk	42.49.82.120	80	hn-cu-v4.ip.zstaticcdn.com	bak.hn-cu-v4.ibsgss.uk	61.240.206.2	80	hn-changsha-cu-v4.ip.zstaticcdn.com
cdn	6	湖南	联通	hn-cu-v6.ibsgss.uk	2408:8763:0:2c5:8000:0:b00:71	80	hn-cu-v6.ip.zstaticcdn.com	bak.hn-cu-v6.ibsgss.uk		80	cs-cu-v6.ip.zstaticcdn.com
cdn	4	湖南	移动	hn-cm-v4.ibsgss.uk	36.133.12.20	80	hn-cm-v4.ip.zstaticcdn.com	bak.hn-cm-v4.ibsgss.uk	36.133.12.2	80	hn-zhuzhou-cm-v4.ip.zstaticcdn.com
cdn	6	湖南	移动	hn-cm-v6.ibsgss.uk	2409:8c50:a00:2084:8000:0:b00:86	80	hn-cm-v6.ip.zstaticcdn.com	bak.hn-cm-v6.ibsgss.uk		80	cs-cm-v6.ip.zstaticcdn.com
cdn	4	广东	电信	gd-ct-v4.ibsgss.uk	14.22.119.35	80	gd-ct-v4.ip.zstaticcdn.com	bak.gd-ct-v4.ibsgss.uk	36.111.36.247	80	gd-guangzhou-ct-v4.ip.zstaticcdn.com
cdn	6	广东	电信	gd-ct-v6.ibsgss.uk	240e:97c:38:280::b00:9	80	gd-ct-v6.ip.zstaticcdn.com	bak.gd-ct-v6.ibsgss.uk	240e:980:1200:607::b00:216	80	gz-ct-v6.ip.zstaticcdn.com
cdn	4	广东	联通	gd-cu-v4.ibsgss.uk	122.13.24.8	80	gd-cu-v4.ip.zstaticcdn.com	bak.gd-cu-v4.ibsgss.uk	157.148.134.3	80	gd-dongguan-cu-v4.ip.zstaticcdn.com
cdn	6	广东	联通	gd-cu-v6.ibsgss.uk	2408:8756:dcff:e001:8000:0:b00:98	80	gd-cu-v6.ip.zstaticcdn.com	bak.gd-cu-v6.ibsgss.uk	2408:877f:30:7:8000:0:b00:224	80	gz-cu-v6.ip.zstaticcdn.com
cdn	4	广东	移动	gd-cm-v4.ibsgss.uk	211.139.145.129	80	gd-cm-v4.ip.zstaticcdn.com	bak.gd-cm-v4.ibsgss.uk	120.233.155.2	80	gd-dongguan-cm-v4.ip.zstaticcdn.com
cdn	6	广东	移动	gd-cm-v6.ibsgss.uk	2409:8c54:b030:1100:8000:0:b00:8	80	gd-cm-v6.ip.zstaticcdn.com	bak.gd-cm-v6.ibsgss.uk	2409:8c62:e10:32:8000:0:b00:99	80	gz-cm-v6.ip.zstaticcdn.com
cdn	4	海南	电信	hi-ct-v4.ibsgss.uk	113.240.92.176	80	hi-ct-v4.ip.zstaticcdn.com	bak.hi-ct-v4.ibsgss.uk	124.225.90.48	80	hi-haikou-ct-v4.ip.zstaticcdn.com
cdn	6	海南	电信	hi-ct-v6.ibsgss.uk	240e:97c:39:f80::b00:228	80	hi-ct-v6.ip.zstaticcdn.com	bak.hi-ct-v6.ibsgss.uk		80	haikou-ct-v6.ip.zstaticcdn.com
cdn	4	海南	联通	hi-cu-v4.ibsgss.uk	153.0.233.27	80	hi-cu-v4.ip.zstaticcdn.com	bak.hi-cu-v4.ibsgss.uk	221.11.190.218	80	221.11.190.218
cdn	6	海南	联通	hi-cu-v6.ibsgss.uk	2408:8760:110:102:8000:0:b00:85	80	hi-cu-v6.ip.zstaticcdn.com	bak.hi-cu-v6.ibsgss.uk		80	haikou-cu-v6.ip.zstaticcdn.com
cdn	4	海南	移动	hi-cm-v4.ibsgss.uk	111.29.49.161	80	hi-cm-v4.ip.zstaticcdn.com	bak.hi-cm-v4.ibsgss.uk	221.176.83.73	80	hi.10086.cn
cdn	6	海南	移动	hi-cm-v6.ibsgss.uk	2409:8c5e:5000:40:8000:0:b00:83	80	hi-cm-v6.ip.zstaticcdn.com	bak.hi-cm-v6.ibsgss.uk		80	haikou-cm-v6.ip.zstaticcdn.com
cdn	4	四川	电信	sc-ct-v4.ibsgss.uk	118.112.1.150	80	sc-ct-v4.ip.zstaticcdn.com	bak.sc-ct-v4.ibsgss.uk	118.122.233.42	443	sc.189.cn
cdn	6	四川	电信	sc-ct-v6.ibsgss.uk	240e:d9:ac01:80::b00:95	80	sc-ct-v6.ip.zstaticcdn.com	bak.sc-ct-v6.ibsgss.uk		80	cd-ct-v6.ip.zstaticcdn.com
cdn	4	四川	联通	sc-cu-v4.ibsgss.uk	119.6.217.100	80	sc-cu-v4.ip.zstaticcdn.com	bak.sc-cu-v4.ibsgss.uk	124.161.187.120	80	sc-dazhou-cu-v4.ip.zstaticcdn.com
cdn	6	四川	联通	sc-cu-v6.ibsgss.uk	2408:8766:0:1002:8000:0:b00:4	80	sc-cu-v6.ip.zstaticcdn.com	bak.sc-cu-v6.ibsgss.uk		80	cd-cu-v6.ip.zstaticcdn.com
cdn	4	四川	移动	sc-cm-v4.ibsgss.uk	36.133.60.1	80	sc-cm-v4.ip.zstaticcdn.com	bak.sc-cm-v4.ibsgss.uk	36.133.60.1	80	sc-chengdu-cm-v4.ip.zstaticcdn.com
cdn	6	四川	移动	sc-cm-v6.ibsgss.uk	2409:8c6c:561:c:8000:0:b00:85	80	sc-cm-v6.ip.zstaticcdn.com	bak.sc-cm-v6.ibsgss.uk		80	cd-cm-v6.ip.zstaticcdn.com
cdn	4	贵州	电信	gz-ct-v4.ibsgss.uk	45.251.95.99	80	gz-ct-v4.ip.zstaticcdn.com	bak.gz-ct-v4.ibsgss.uk	114.135.115.117	443	gz.189.cn
cdn	6	贵州	电信	gz-ct-v6.ibsgss.uk	240e:980:1200:607::b00:216	80	gz-ct-v6.ip.zstaticcdn.com	bak.gz-ct-v6.ibsgss.uk		80	gy-ct-v6.ip.zstaticcdn.com
cdn	4	贵州	联通	gz-cu-v4.ibsgss.uk	59.80.45.89	80	gz-cu-v4.ip.zstaticcdn.com	bak.gz-cu-v4.ibsgss.uk	59.80.34.200	80	gz-guiyang-cu-v4.ip.zstaticcdn.com
cdn	6	贵州	联通	gz-cu-v6.ibsgss.uk	2408:877f:30:7:8000:0:b00:224	80	gz-cu-v6.ip.zstaticcdn.com	bak.gz-cu-v6.ibsgss.uk		80	gy-cu-v6.ip.zstaticcdn.com
cdn	4	贵州	移动	gz-cm-v4.ibsgss.uk	36.136.125.170	80	gz-cm-v4.ip.zstaticcdn.com	bak.gz-cm-v4.ibsgss.uk	36.134.90.65	80	gz-guiyang-cm-v4.ip.zstaticcdn.com
cdn	6	贵州	移动	gz-cm-v6.ibsgss.uk	2409:8c62:e10:32:8000:0:b00:99	80	gz-cm-v6.ip.zstaticcdn.com	bak.gz-cm-v6.ibsgss.uk		80	gy-cm-v6.ip.zstaticcdn.com
cdn	4	云南	电信	yn-ct-v4.ibsgss.uk	106.60.4.70	80	yn-ct-v4.ip.zstaticcdn.com	bak.yn-ct-v4.ibsgss.uk		80	km-ct-v4.ip.zstaticcdn.com
cdn	6	云南	电信	yn-ct-v6.ibsgss.uk	240e:94c:4000:313:8000:0:b00:77	80	yn-ct-v6.ip.zstaticcdn.com	bak.yn-ct-v6.ibsgss.uk		80	km-ct-v6.ip.zstaticcdn.com
cdn	4	云南	联通	yn-cu-v4.ibsgss.uk	119.62.43.2	80	yn-cu-v4.ip.zstaticcdn.com	bak.yn-cu-v4.ibsgss.uk	180.130.209.24	80	yn-dehong-cu-v4.ip.zstaticcdn.com
cdn	6	云南	联通	yn-cu-v6.ibsgss.uk	2408:8763:0:2c5:8000:0:b00:63	80	yn-cu-v6.ip.zstaticcdn.com	bak.yn-cu-v6.ibsgss.uk		80	km-cu-v6.ip.zstaticcdn.com
cdn	4	云南	移动	yn-cm-v4.ibsgss.uk	218.202.0.254	80	yn-cm-v4.ip.zstaticcdn.com	bak.yn-cm-v4.ibsgss.uk		80	km-cm-v4.ip.zstaticcdn.com
cdn	6	云南	移动	yn-cm-v6.ibsgss.uk	2409:8c6c:550:1614:8000:0:b00:8	80	yn-cm-v6.ip.zstaticcdn.com	bak.yn-cm-v6.ibsgss.uk		80	km-cm-v6.ip.zstaticcdn.com
cdn	4	陕西	电信	sn-ct-v4.ibsgss.uk	113.141.78.120	80	sn-ct-v4.ip.zstaticcdn.com	bak.sn-ct-v4.ibsgss.uk	203.2.167.233	80	sn-xian-ct-v4.ip.zstaticcdn.com
cdn	6	陕西	电信	sn-ct-v6.ibsgss.uk	240e:bf:b800:4115:8000:0:b00:95	80	sn-ct-v6.ip.zstaticcdn.com	bak.sn-ct-v6.ibsgss.uk		80	xa-ct-v6.ip.zstaticcdn.com
cdn	4	陕西	联通	sn-cu-v4.ibsgss.uk	124.89.67.172	80	sn-cu-v4.ip.zstaticcdn.com	bak.sn-cu-v4.ibsgss.uk	124.89.84.248	80	sn-xianyang-cu-v4.ip.zstaticcdn.com
cdn	6	陕西	联通	sn-cu-v6.ibsgss.uk	2408:8766:0:1002:8000:0:b00:4	80	sn-cu-v6.ip.zstaticcdn.com	bak.sn-cu-v6.ibsgss.uk		80	xa-cu-v6.ip.zstaticcdn.com
cdn	4	陕西	移动	sn-cm-v4.ibsgss.uk	218.200.36.30	80	sn-cm-v4.ip.zstaticcdn.com	bak.sn-cm-v4.ibsgss.uk	36.133.96.128	80	sn-xian-cm-v4.ip.zstaticcdn.com
cdn	6	陕西	移动	sn-cm-v6.ibsgss.uk	2409:8c70:3a10:2:8000:0:b00:74	80	sn-cm-v6.ip.zstaticcdn.com	bak.sn-cm-v6.ibsgss.uk		80	xa-cm-v6.ip.zstaticcdn.com
cdn	4	甘肃	电信	gs-ct-v4.ibsgss.uk	113.142.39.64	80	gs-ct-v4.ip.zstaticcdn.com	bak.gs-ct-v4.ibsgss.uk	125.75.103.73	80	gs-lanzhou-ct-v4.ip.zstaticcdn.com
cdn	6	甘肃	电信	gs-ct-v6.ibsgss.uk	240e:bf:c800:2904:8000:0:b00:63	80	gs-ct-v6.ip.zstaticcdn.com	bak.gs-ct-v6.ibsgss.uk		80	lz-ct-v6.ip.zstaticcdn.com
cdn	4	甘肃	联通	gs-cu-v4.ibsgss.uk	116.176.34.50	80	gs-cu-v4.ip.zstaticcdn.com	bak.gs-cu-v4.ibsgss.uk		80	lz-cu-v4.ip.zstaticcdn.com
cdn	6	甘肃	联通	gs-cu-v6.ibsgss.uk	2408:8001:c01d:7:8000:0:b00:35	80	gs-cu-v6.ip.zstaticcdn.com	bak.gs-cu-v6.ibsgss.uk		80	lz-cu-v6.ip.zstaticcdn.com
cdn	4	甘肃	移动	gs-cm-v4.ibsgss.uk	117.157.235.170	80	gs-cm-v4.ip.zstaticcdn.com	bak.gs-cm-v4.ibsgss.uk	211.139.91.37	80	gs.10086.cn
cdn	6	甘肃	移动	gs-cm-v6.ibsgss.uk	2409:8c74:f100:414:8000:0:b00:83	80	gs-cm-v6.ip.zstaticcdn.com	bak.gs-cm-v6.ibsgss.uk		80	lz-cm-v6.ip.zstaticcdn.com
cdn	4	青海	电信	qh-ct-v4.ibsgss.uk	118.213.159.253	80	qh-ct-v4.ip.zstaticcdn.com	bak.qh-ct-v4.ibsgss.uk	223.221.8.12	443	qh.189.cn
cdn	6	青海	电信	qh-ct-v6.ibsgss.uk	240e:90:2006:2:8000:0:b00:84	80	qh-ct-v6.ip.zstaticcdn.com	bak.qh-ct-v6.ibsgss.uk		80	xn-ct-v6.ip.zstaticcdn.com
cdn	4	青海	联通	qh-cu-v4.ibsgss.uk	43.242.183.150	80	qh-cu-v4.ip.zstaticcdn.com	bak.qh-cu-v4.ibsgss.uk	139.170.157.88	80	qh-xining-cu-v4.ip.zstaticcdn.com
cdn	6	青海	联通	qh-cu-v6.ibsgss.uk	2408:8776:1:13:8000:0:b00:224	80	qh-cu-v6.ip.zstaticcdn.com	bak.qh-cu-v6.ibsgss.uk		80	xn-cu-v6.ip.zstaticcdn.com
cdn	4	青海	移动	qh-cm-v4.ibsgss.uk	111.44.158.48	80	qh-cm-v4.ip.zstaticcdn.com	bak.qh-cm-v4.ibsgss.uk		80	xn-cm-v4.ip.zstaticcdn.com
cdn	6	青海	移动	qh-cm-v6.ibsgss.uk	2409:8c78:100:30:8000:0:b00:99	80	qh-cm-v6.ip.zstaticcdn.com	bak.qh-cm-v6.ibsgss.uk		80	xn-cm-v6.ip.zstaticcdn.com
cdn	4	内蒙古	电信	nm-ct-v4.ibsgss.uk	219.148.161.68	80	nm-ct-v4.ip.zstaticcdn.com	bak.nm-ct-v4.ibsgss.uk	150.223.192.249	80	nm-huhehaote-ct-v4.ip.zstaticcdn.com
cdn	6	内蒙古	电信	nm-ct-v6.ibsgss.uk	240e:918:8011:8000::b00:85	80	nm-ct-v6.ip.zstaticcdn.com	bak.nm-ct-v6.ibsgss.uk		80	hhht-ct-v6.ip.zstaticcdn.com
cdn	4	内蒙古	联通	nm-cu-v4.ibsgss.uk	116.95.24.2	80	nm-cu-v4.ip.zstaticcdn.com	bak.nm-cu-v4.ibsgss.uk	106.74.14.40	80	nm-huhehaote-cu-v4.ip.zstaticcdn.com
cdn	6	内蒙古	联通	nm-cu-v6.ibsgss.uk	2408:872b:e02:12:8000:0:b00:8	80	nm-cu-v6.ip.zstaticcdn.com	bak.nm-cu-v6.ibsgss.uk		80	hhht-cu-v6.ip.zstaticcdn.com
cdn	4	内蒙古	移动	nm-cm-v4.ibsgss.uk	218.202.107.179	80	nm-cm-v4.ip.zstaticcdn.com	bak.nm-cm-v4.ibsgss.uk	36.134.88.65	80	nm-huhehaote-cm-v4.ip.zstaticcdn.com
cdn	6	内蒙古	移动	nm-cm-v6.ibsgss.uk	2409:8c10:c00:1b:8000:0:b00:181	80	nm-cm-v6.ip.zstaticcdn.com	bak.nm-cm-v6.ibsgss.uk		80	hhht-cm-v6.ip.zstaticcdn.com
cdn	4	广西	电信	gx-ct-v4.ibsgss.uk	171.111.157.173	80	gx-ct-v4.ip.zstaticcdn.com	bak.gx-ct-v4.ibsgss.uk	116.8.128.2	443	gx.189.cn
cdn	6	广西	电信	gx-ct-v6.ibsgss.uk	240e:951:2c10:5800:8000:0:b00:7	80	gx-ct-v6.ip.zstaticcdn.com	bak.gx-ct-v6.ibsgss.uk		80	nn-ct-v6.ip.zstaticcdn.com
cdn	4	广西	联通	gx-cu-v4.ibsgss.uk	58.144.112.204	80	gx-cu-v4.ip.zstaticcdn.com	bak.gx-cu-v4.ibsgss.uk	182.91.12.76	80	gx-guilin-cu-v4.ip.zstaticcdn.com
cdn	6	广西	联通	gx-cu-v6.ibsgss.uk	2408:8763:0:2c5:8000:0:b00:71	80	gx-cu-v6.ip.zstaticcdn.com	bak.gx-cu-v6.ibsgss.uk		80	nn-cu-v6.ip.zstaticcdn.com
cdn	4	广西	移动	gx-cm-v4.ibsgss.uk	36.136.125.169	80	gx-cm-v4.ip.zstaticcdn.com	bak.gx-cm-v4.ibsgss.uk	112.54.48.41	443	gx.10086.cn
cdn	6	广西	移动	gx-cm-v6.ibsgss.uk	2409:8c5c:110:27:8000:0:b00:98	80	gx-cm-v6.ip.zstaticcdn.com	bak.gx-cm-v6.ibsgss.uk		80	nn-cm-v6.ip.zstaticcdn.com
cdn	4	西藏	电信	xz-ct-v4.ibsgss.uk	45.251.95.98	80	xz-ct-v4.ip.zstaticcdn.com	bak.xz-ct-v4.ibsgss.uk	113.62.183.157	80	xz-lasa-ct-v4.ip.zstaticcdn.com
cdn	6	西藏	电信	xz-ct-v6.ibsgss.uk	240e:980:1200:607::b00:216	80	xz-ct-v6.ip.zstaticcdn.com	bak.xz-ct-v6.ibsgss.uk		80	lasa-ct-v6.ip.zstaticcdn.com
cdn	4	西藏	联通	xz-cu-v4.ibsgss.uk	116.172.153.99	80	xz-cu-v4.ip.zstaticcdn.com	bak.xz-cu-v4.ibsgss.uk		80	lasa-cu-v4.ip.zstaticcdn.com
cdn	6	西藏	联通	xz-cu-v6.ibsgss.uk	2408:876e:3:0:8000:0:b00:227	80	xz-cu-v6.ip.zstaticcdn.com	bak.xz-cu-v6.ibsgss.uk		80	lasa-cu-v6.ip.zstaticcdn.com
cdn	4	西藏	移动	xz-cm-v4.ibsgss.uk	117.180.231.226	80	xz-cm-v4.ip.zstaticcdn.com	bak.xz-cm-v4.ibsgss.uk		80	lasa-cm-v4.ip.zstaticcdn.com
cdn	6	西藏	移动	xz-cm-v6.ibsgss.uk	2409:8c7e:0:18:8000:0:b00:228	80	xz-cm-v6.ip.zstaticcdn.com	bak.xz-cm-v6.ibsgss.uk		80	lasa-cm-v6.ip.zstaticcdn.com
cdn	4	宁夏	电信	nx-ct-v4.ibsgss.uk	222.75.44.146	80	nx-ct-v4.ip.zstaticcdn.com	bak.nx-ct-v4.ibsgss.uk	61.133.213.210	443	nx.189.cn
cdn	6	宁夏	电信	nx-ct-v6.ibsgss.uk	240e:91c:0:5:8000:0:b00:228	80	nx-ct-v6.ip.zstaticcdn.com	bak.nx-ct-v6.ibsgss.uk		80	yinchuan-ct-v6.ip.zstaticcdn.com
cdn	4	宁夏	联通	nx-cu-v4.ibsgss.uk	42.63.59.199	80	nx-cu-v4.ip.zstaticcdn.com	bak.nx-cu-v4.ibsgss.uk	42.63.68.8	80	nx-yinchuan-cu-v4.ip.zstaticcdn.com
cdn	6	宁夏	联通	nx-cu-v6.ibsgss.uk	2408:8778:109:2:8000:0:b00:95	80	nx-cu-v6.ip.zstaticcdn.com	bak.nx-cu-v6.ibsgss.uk		80	yinchuan-cu-v6.ip.zstaticcdn.com
cdn	4	宁夏	移动	nx-cm-v4.ibsgss.uk	183.204.210.215	80	nx-cm-v4.ip.zstaticcdn.com	bak.nx-cm-v4.ibsgss.uk	218.203.120.131	443	nx.10086.cn
cdn	6	宁夏	移动	nx-cm-v6.ibsgss.uk	2409:8c44:2:ff16:8000:0:b00:86	80	nx-cm-v6.ip.zstaticcdn.com	bak.nx-cm-v6.ibsgss.uk		80	yinchuan-cm-v6.ip.zstaticcdn.com
cdn	4	新疆	电信	xj-ct-v4.ibsgss.uk	113.142.39.64	80	xj-ct-v4.ip.zstaticcdn.com	bak.xj-ct-v4.ibsgss.uk	120.71.61.247	80	xj-wulumuqi-ct-v4.ip.zstaticcdn.com
cdn	6	新疆	电信	xj-ct-v6.ibsgss.uk	240e:bf:c800:2904:8000:0:b00:85	80	xj-ct-v6.ip.zstaticcdn.com	bak.xj-ct-v6.ibsgss.uk		80	wlmq-ct-v6.ip.zstaticcdn.com
cdn	4	新疆	联通	xj-cu-v4.ibsgss.uk	116.178.236.178	80	xj-cu-v4.ip.zstaticcdn.com	bak.xj-cu-v4.ibsgss.uk	124.88.196.248	80	xj-bayinguoleng-cu-v4.ip.zstaticcdn.com
cdn	6	新疆	联通	xj-cu-v6.ibsgss.uk	2408:877a:2000:3:4000:0:b00:227	80	xj-cu-v6.ip.zstaticcdn.com	bak.xj-cu-v6.ibsgss.uk		80	wlmq-cu-v6.ip.zstaticcdn.com
cdn	4	新疆	移动	xj-cm-v4.ibsgss.uk	36.189.15.245	80	xj-cm-v4.ip.zstaticcdn.com	bak.xj-cm-v4.ibsgss.uk	221.181.13.25	443	xj.10086.cn
cdn	6	新疆	移动	xj-cm-v6.ibsgss.uk	2409:8c70:3a10:2:8000:0:b00:74	80	xj-cm-v6.ip.zstaticcdn.com	bak.xj-cm-v6.ibsgss.uk		80	wlmq-cm-v6.ip.zstaticcdn.com
cdn	4	北京	电信	bj-ct-v4.ibsgss.uk	106.37.68.13	80	bj-ct-v4.ip.zstaticcdn.com	bak.bj-ct-v4.ibsgss.uk	106.37.68.13	443	bj.189.cn
cdn	6	北京	电信	bj-ct-v6.ibsgss.uk	240e:93c:209:2:8000:0:b00:59	80	bj-ct-v6.ip.zstaticcdn.com	bak.bj-ct-v6.ibsgss.uk	240e:93c:209:2:8000:0:b00:59	80	bj-ct-v6.ip.zstaticcdn.com
cdn	4	北京	联通	bj-cu-v4.ibsgss.uk	221.222.185.232	80	bj-cu-v4.ip.zstaticcdn.com	bak.bj-cu-v4.ibsgss.uk	221.222.185.232	80	bj-cu-v4.ip.zstaticcdn.com
cdn	6	北京	联通	bj-cu-v6.ibsgss.uk	2408:8706:0:db80::b00:72	80	bj-cu-v6.ip.zstaticcdn.com	bak.bj-cu-v6.ibsgss.uk	2408:8706:0:db80::b00:72	80	bj-cu-v6.ip.zstaticcdn.com
cdn	4	北京	移动	bj-cm-v4.ibsgss.uk	211.136.25.153	80	bj-cm-v4.ip.zstaticcdn.com	bak.bj-cm-v4.ibsgss.uk	211.136.25.153	80	bj-cm-v4.ip.zstaticcdn.com
cdn	6	北京	移动	bj-cm-v6.ibsgss.uk	2409:8c20:6ed1:10d:8000:0:b00:79	80	bj-cm-v6.ip.zstaticcdn.com	bak.bj-cm-v6.ibsgss.uk	2409:8c20:6ed1:10d:8000:0:b00:79	80	bj-cm-v6.ip.zstaticcdn.com
cdn	4	天津	电信	tj-ct-v4.ibsgss.uk	123.151.109.108	80	tj-ct-v4.ip.zstaticcdn.com	bak.tj-ct-v4.ibsgss.uk	221.238.15.10	443	tj.189.cn
cdn	6	天津	电信	tj-ct-v6.ibsgss.uk	240e:928:601:400:8000:0:b00:80	80	tj-ct-v6.ip.zstaticcdn.com	bak.tj-ct-v6.ibsgss.uk	240e:928:601:400:8000:0:b00:80	80	tj-ct-v6.ip.zstaticcdn.com
cdn	4	天津	联通	tj-cu-v4.ibsgss.uk	117.8.227.168	80	tj-cu-v4.ip.zstaticcdn.com	bak.tj-cu-v4.ibsgss.uk	117.8.227.168	80	tj-cu-v4.ip.zstaticcdn.com
cdn	6	天津	联通	tj-cu-v6.ibsgss.uk	2408:871a:4800:40f::b00:98	80	tj-cu-v6.ip.zstaticcdn.com	bak.tj-cu-v6.ibsgss.uk	2408:871a:4800:40f::b00:98	80	tj-cu-v6.ip.zstaticcdn.com
cdn	4	天津	移动	tj-cm-v4.ibsgss.uk	211.103.90.101	80	tj-cm-v4.ip.zstaticcdn.com	bak.tj-cm-v4.ibsgss.uk	117.131.199.193	443	117.131.199.193
cdn	6	天津	移动	tj-cm-v6.ibsgss.uk	2409:8c1e:75b0:2003:8000:0:b00:62	80	tj-cm-v6.ip.zstaticcdn.com	bak.tj-cm-v6.ibsgss.uk	2409:8c1e:75b0:2003:8000:0:b00:62	80	tj-cm-v6.ip.zstaticcdn.com
cdn	4	上海	电信	sh-ct-v4.ibsgss.uk	101.226.94.50	80	sh-ct-v4.ip.zstaticcdn.com	bak.sh-ct-v4.ibsgss.uk	101.95.52.35	80	sh.189.cn
cdn	6	上海	电信	sh-ct-v6.ibsgss.uk	240e:96c:1100:6a80::b00:95	80	sh-ct-v6.ip.zstaticcdn.com	bak.sh-ct-v6.ibsgss.uk	240e:96c:1100:6a80::b00:95	80	sh-ct-v6.ip.zstaticcdn.com
cdn	4	上海	联通	sh-cu-v4.ibsgss.uk	112.64.235.107	80	sh-cu-v4.ip.zstaticcdn.com	bak.sh-cu-v4.ibsgss.uk	112.64.235.107	80	sh-cu-v4.ip.zstaticcdn.com
cdn	6	上海	联通	sh-cu-v6.ibsgss.uk	2408:873c:6810:5:8000:0:b00:220	80	sh-cu-v6.ip.zstaticcdn.com	bak.sh-cu-v6.ibsgss.uk	2408:873c:6810:5:8000:0:b00:220	80	sh-cu-v6.ip.zstaticcdn.com
cdn	4	上海	移动	sh-cm-v4.ibsgss.uk	117.185.117.109	80	sh-cm-v4.ip.zstaticcdn.com	bak.sh-cm-v4.ibsgss.uk	117.185.117.109	80	sh-cm-v4.ip.zstaticcdn.com
cdn	6	上海	移动	sh-cm-v6.ibsgss.uk	2409:8c1e:75b0:2003:8000:0:b00:319	80	sh-cm-v6.ip.zstaticcdn.com	bak.sh-cm-v6.ibsgss.uk	2409:8c1e:75b0:2003:8000:0:b00:319	80	sh-cm-v6.ip.zstaticcdn.com
cdn	4	重庆	电信	cq-ct-v4.ibsgss.uk	119.84.169.8	80	cq-ct-v4.ip.zstaticcdn.com	bak.cq-ct-v4.ibsgss.uk	219.152.188.41	443	cq.189.cn
cdn	6	重庆	电信	cq-ct-v6.ibsgss.uk	240e:930:1000::1d0	80	cq-ct-v6.ip.zstaticcdn.com	bak.cq-ct-v6.ibsgss.uk	240e:930:1000::1d0	80	cq-ct-v6.ip.zstaticcdn.com
cdn	4	重庆	联通	cq-cu-v4.ibsgss.uk	58.144.112.204	80	cq-cu-v4.ip.zstaticcdn.com	bak.cq-cu-v4.ibsgss.uk	58.144.112.204	80	cq-cu-v4.ip.zstaticcdn.com
cdn	6	重庆	联通	cq-cu-v6.ibsgss.uk	2408:8763:0:2c5:8000:0:b00:63	80	cq-cu-v6.ip.zstaticcdn.com	bak.cq-cu-v6.ibsgss.uk	2408:8763:0:2c5:8000:0:b00:63	80	cq-cu-v6.ip.zstaticcdn.com
cdn	4	重庆	移动	cq-cm-v4.ibsgss.uk	120.226.150.246	80	cq-cm-v4.ip.zstaticcdn.com	bak.cq-cm-v4.ibsgss.uk	218.201.25.131	80	cq.10086.cn
cdn	6	重庆	移动	cq-cm-v6.ibsgss.uk	2409:8c6c:561:c:8000:0:b00:85	80	cq-cm-v6.ip.zstaticcdn.com	bak.cq-cm-v6.ibsgss.uk	2409:8c6c:561:c:8000:0:b00:85	80	cq-cm-v6.ip.zstaticcdn.com
cernet	4	河北	CERNET	cernet-he-v4.ibsgss.uk	115.24.175.50	443	www.hebut.edu.cn				
cernet2	6	河北	CERNET2	cernet2-he-v6.ibsgss.uk	2001:250:405:12::50	443	www.hebut.edu.cn				
cernet	4	山西	CERNET	cernet-sx-v4.ibsgss.uk	202.207.240.104	443	www.tyut.edu.cn				
cernet2	6	山西	CERNET2	cernet2-sx-v6.ibsgss.uk	2001:250:c01:5000:cacf:f068::	443	www.tyut.edu.cn				
cernet	4	辽宁	CERNET	cernet-ln-v4.ibsgss.uk	202.118.76.222	443	www.dlut.edu.cn				
cernet2	6	辽宁	CERNET2	cernet2-ln-v6.ibsgss.uk	2001:da8:a800:7::222	443	www.dlut.edu.cn				
cernet	4	吉林	CERNET	cernet-jl-v4.ibsgss.uk	202.198.16.83	443	www.jlu.edu.cn				
cernet2	6	吉林	CERNET2	cernet2-jl-v6.ibsgss.uk	2001:da8:b000::80	443	www.jlu.edu.cn				
cernet	4	黑龙江	CERNET	cernet-hl-v4.ibsgss.uk	202.118.254.135	443	www.hit.edu.cn				
cernet2	6	黑龙江	CERNET2	cernet2-hl-v6.ibsgss.uk	2001:da8:b800:253::c0a8:3208	443	www.hit.edu.cn				
cernet	4	江苏	CERNET	cernet-js-v4.ibsgss.uk	202.119.32.7	443	www.nju.edu.cn				
cernet2	6	江苏	CERNET2	cernet2-js-v6.ibsgss.uk	2001:da8:1007::9999	443	www.nju.edu.cn				
cernet	4	浙江	CERNET	cernet-zj-v4.ibsgss.uk	210.33.16.1	443	www.nbu.edu.cn				
cernet2	6	浙江	CERNET2	cernet2-zj-v6.ibsgss.uk	2001:da8:e028:1000::123	443	www.nbu.edu.cn				
cernet	4	安徽	CERNET	cernet-ah-v4.ibsgss.uk	210.45.240.198	443	www.hfut.edu.cn	bak.cernet-ah-v4.ibsgss.uk	210.45.96.212	443	www.ahmu.edu.cn
cernet2	6	安徽	CERNET2	cernet2-ah-v6.ibsgss.uk	2001:250:5401:160::55	443	www.ahu.edu.cn	bak.cernet2-ah-v6.ibsgss.uk	2001:da8:d813:195::70	443	www.ahnu.edu.cn
cernet	4	福建	CERNET	cernet-fj-v4.ibsgss.uk	219.229.81.211	443	www.xmu.edu.cn				
cernet2	6	福建	CERNET2	cernet2-fj-v6.ibsgss.uk	2001:da8:e800:251c::211	443	www.xmu.edu.cn				
cernet	4	江西	CERNET	cernet-jx-v4.ibsgss.uk	219.229.232.50	443	www.jxust.edu.cn				
cernet2	6	江西	CERNET2	cernet2-jx-v6.ibsgss.uk	2001:250:6c0b:6010::10:50	443	www.jxust.edu.cn				
cernet	4	山东	CERNET	cernet-sd-v4.ibsgss.uk	202.194.7.118	443	www.sdu.edu.cn				
cernet2	6	山东	CERNET2	cernet2-sd-v6.ibsgss.uk	2001:da8:7000:7:202:194:7:118	443	www.sdu.edu.cn				
cernet	4	河南	CERNET	cernet-ha-v4.ibsgss.uk	202.196.64.48	443	www.zzu.edu.cn				
cernet2	6	河南	CERNET2	cernet2-ha-v6.ibsgss.uk	2001:da8:5000:6c00::47	443	www.zzu.edu.cn				
cernet	4	湖北	CERNET	cernet-hb-v4.ibsgss.uk	115.156.123.19	443	www.whu.edu.cn				
cernet2	6	湖北	CERNET2	cernet2-hb-v6.ibsgss.uk	2001:250:4001:4::8	443	www.whu.edu.cn				
cernet	4	湖南	CERNET	cernet-hn-v4.ibsgss.uk	202.197.61.57	443	www.csu.edu.cn	bak.cernet-hn-v4.ibsgss.uk	202.197.229.30	443	www.xtu.edu.cn
cernet2	6	湖南	CERNET2	cernet2-hn-v6.ibsgss.uk	2001:250:4400:64::57	443	www.csu.edu.cn	bak.cernet2-hn-v6.ibsgss.uk	2001:da8:d00a:fffa::30	443	www.xtu.edu.cn
cernet	4	广东	CERNET	cernet-gd-v4.ibsgss.uk	202.116.64.8	443	www.sysu.edu.cn				
cernet2	6	广东	CERNET2	cernet2-gd-v6.ibsgss.uk	2001:da8:2000:2193::28	443	www.scut.edu.cn				
cernet	4	海南	CERNET	cernet-hi-v4.ibsgss.uk	210.37.79.21	443	www.hainanu.edu.cn	bak.cernet-hi-v4.ibsgss.uk	210.37.79.21	443	www.muhn.edu.cn
cernet2	6	海南	CERNET2	cernet2-hi-v6.ibsgss.uk	2001:250:3801:207:2::a	443	www.hainanu.edu.cn	bak.cernet2-hi-v6.ibsgss.uk	2001:250:3802:2001::13	443	www.muhn.edu.cn
cernet	4	四川	CERNET	cernet-sc-v4.ibsgss.uk	202.115.47.167	443	www.scu.edu.cn				
cernet2	6	四川	CERNET2	cernet2-sc-v6.ibsgss.uk		443	www.scu.edu.cn				
cernet	4	贵州	CERNET	cernet-gz-v4.ibsgss.uk	210.40.12.58	443	www.gzu.edu.cn				
cernet2	6	贵州	CERNET2	cernet2-gz-v6.ibsgss.uk	2001:250:2c00::60	443	www.gzu.edu.cn				
cernet	4	云南	CERNET	cernet-yn-v4.ibsgss.uk	202.203.225.46	443	www.ynnu.edu.cn	bak.cernet-yn-v4.ibsgss.uk	113.55.13.95	443	www.ynu.edu.cn
cernet2	6	云南	CERNET2	cernet2-yn-v6.ibsgss.uk	2001:250:2804:2::1:46	443	www.ynnu.edu.cn	bak.cernet2-yn-v6.ibsgss.uk	2001:250:2800:0:28:0:13:95	443	www.ynu.edu.cn
cernet	4	陕西	CERNET	cernet-sn-v4.ibsgss.uk	202.117.1.13	443	www.xjtu.edu.cn				
cernet2	6	陕西	CERNET2	cernet2-sn-v6.ibsgss.uk	2001:250:1001:1::ca75:10d	443	www.xjtu.edu.cn				
cernet	4	甘肃	CERNET	cernet-gs-v4.ibsgss.uk	202.201.0.81	443	www.lzu.edu.cn				
cernet2	6	甘肃	CERNET2	cernet2-gs-v6.ibsgss.uk	2001:da8:c000:2::2026	443	www.lzu.edu.cn				
cernet	4	青海	CERNET	cernet-qh-v4.ibsgss.uk	210.27.177.240	443	www.qhu.edu.cn				
cernet2	6	青海	CERNET2	cernet2-qh-v6.ibsgss.uk	2001:250:1e00:2::144:28	443	www.qhnu.edu.cn				
cernet	4	内蒙古	CERNET	cernet-nm-v4.ibsgss.uk	183.175.40.132	443	www.imu.edu.cn				
cernet2	6	内蒙古	CERNET2	cernet2-nm-v6.ibsgss.uk	2001:da8:21d:c101::2	443	www.imu.edu.cn				
cernet	4	广西	CERNET	cernet-gx-v4.ibsgss.uk	210.36.16.35	443	www.gxu.edu.cn				
cernet2	6	广西	CERNET2	cernet2-gx-v6.ibsgss.uk	2001:250:3401:1::35	443	www.gxu.edu.cn				
cernet	4	西藏	CERNET	cernet-xz-v4.ibsgss.uk	202.200.16.13	443	www.xzmu.edu.cn				
cernet2	6	西藏	CERNET2	cernet2-xz-v6.ibsgss.uk	2001:da8:4023:16::13	443	www.xzmu.edu.cn				
cernet	4	宁夏	CERNET	cernet-nx-v4.ibsgss.uk	222.23.220.245	443	www.nxu.edu.cn				
cernet2	6	宁夏	CERNET2	cernet2-nx-v6.ibsgss.uk	2001:250:1c00:1::245	443	www.nxu.edu.cn				
cernet	4	新疆	CERNET	cernet-xj-v4.ibsgss.uk	111.115.76.75	443	www.xju.edu.cn				
cernet2	6	新疆	CERNET2	cernet2-xj-v6.ibsgss.uk	2001:250:1800:1997::4	443	www.xju.edu.cn				
cernet	4	北京	CERNET	cernet-bj-v4.ibsgss.uk	101.6.15.66	443	www.tsinghua.edu.cn				
cernet2	6	北京	CERNET2	cernet2-bj-v6.ibsgss.uk	2402:f000:1:402:101:6:15:66	443	www.tsinghua.edu.cn				
cernet	4	天津	CERNET	cernet-tj-v4.ibsgss.uk	202.113.2.198	443	www.tju.edu.cn				
cernet2	6	天津	CERNET2	cernet2-tj-v6.ibsgss.uk	2001:da8:a000:ab23::10	443	www.tju.edu.cn				
cernet	4	上海	CERNET	cernet-sh-v4.ibsgss.uk	202.120.2.114	443	www.sjtu.edu.cn				
cernet2	6	上海	CERNET2	cernet2-sh-v6.ibsgss.uk	2001:da8:8000:6181:202:120:2:114	443	www.sjtu.edu.cn				
cernet	4	重庆	CERNET	cernet-cq-v4.ibsgss.uk	202.202.2.6	443	www.cqu.edu.cn				
cernet2	6	重庆	CERNET2	cernet2-cq-v6.ibsgss.uk	2001:da8:c800:2::6	443	www.cqu.edu.cn				
TCP_NODES_EOF
}

# ==================== 菜单与参数 ====================

show_help() {
  cat <<EOF
VPSCheck v${VERSION} - VPS 检测脚本

用法: bash check.sh [选项]
不带检测项目参数、且在终端中运行时，显示交互菜单。

检测项目（可组合）:
  -A                全部检测
  -N                网络信息（BGP / 上游 / NAT）
  -I                IP 质量（基础信息 / 风险 / 解锁 / 邮局 / 黑名单）
  -T                所有回程（三网 + 大包 + 教育网）
  -R                三网回程
  -L                大包回程（仅 IPv4）
  -E                教育网回程（CERNET / CERNET2）

其他选项:
  -4 / -6           只测 IPv4 / IPv6
  -c NUM            回程每节点发包数（1-600）
  --province CODE   回程只测指定省份，可重复（如 bj、sh、gd 或 北京）
  -o FILE           报告另存为纯文本
  -y                缺少依赖时自动安装，不询问
  -h                显示帮助

回程检测（-T/-R/-L/-E）需要 root 权限。
EOF
}

parse_args() {
  local any=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -A) DO_NET=1; DO_IP=1; TCP_ROUTE=1; TCP_LARGE=1; TCP_EDU=1; any=1 ;;
      -N) DO_NET=1; any=1 ;;
      -I) DO_IP=1; any=1 ;;
      -T) TCP_ROUTE=1; TCP_LARGE=1; TCP_EDU=1; any=1 ;;
      -R) TCP_ROUTE=1; any=1 ;;
      -L) TCP_LARGE=1; any=1 ;;
      -E) TCP_EDU=1; any=1 ;;
      -4) OPT_ONLY4=1 ;;
      -6) OPT_ONLY6=1 ;;
      -c)
        [[ "${2:-}" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 600 ] || { echo "-c 需要 1-600 的整数" >&2; exit 1; }
        OPT_COUNT=$((10#$2)); shift ;;
      --province)
        [ -n "${2:-}" ] || { echo "--province 需要参数" >&2; exit 1; }
        OPT_PROVINCES+=("$2"); shift ;;
      -o)
        [ -n "${2:-}" ] && [[ "$2" != -* ]] || { echo "-o 需要文件路径" >&2; exit 1; }
        OPT_OUTPUT="$2"; shift ;;
      -y) OPT_YES=1 ;;
      -h|--help) show_help; exit 0 ;;
      *) echo "未知参数: $1（-h 查看帮助）" >&2; exit 1 ;;
    esac
    shift
  done
  if [ "$OPT_ONLY4" -eq 1 ] && [ "$OPT_ONLY6" -eq 1 ]; then
    echo "-4 与 -6 不能同时使用" >&2; exit 1
  fi
  [ "$any" -eq 1 ]
}

show_menu() {
  local tag="" choice n ok
  local -a picks
  [ "$IS_ROOT" -eq 0 ] && tag="${C_D}(需 root，当前不可用)${C_0}" || tag="${C_D}(需 root)${C_0}"
  local err=""
  while :; do
    ui_clear
    {
      printf '%s%s%s\n' "$C_BOLD$C_W" "$(ui_pad "VPSCheck v${VERSION}" "$UI_W" c)" "$C_0"
      ui_line '='
      printf '  1. %s\n' "全部检测"
      printf '  2. %s %s\n' "$(ui_pad 网络信息 14)" "${C_D}BGP / 上游 / NAT${C_0}"
      printf '  3. %s %s\n' "$(ui_pad "IP 质量" 14)" "${C_D}基础信息 / 风险 / 解锁 / 邮局 / 黑名单${C_0}"
      printf '  4. %s %s %s\n' "$(ui_pad 所有回程 14)" "$(ui_pad "${C_D}三网 + 大包 + 教育网${C_0}" 30)" "$tag"
      printf '  5. %s %s %s\n' "$(ui_pad 三网回程 14)" "$(ui_pad "${C_D}线路类型 / 丢包 / 延迟${C_0}" 30)" "$tag"
      printf '  6. %s %s %s\n' "$(ui_pad 大包回程 14)" "$(ui_pad "${C_D}大包预检 / 丢包 / 线路${C_0}" 30)" "$tag"
      printf '  7. %s %s %s\n' "$(ui_pad 教育网回程 14)" "$(ui_pad "${C_D}CERNET / CERNET2${C_0}" 30)" "$tag"
      printf '  0. 退出\n'
      ui_line '-'
      [ -n "$err" ] && echo "${C_Y}${err}${C_0}"
    } >&2
    read -r -p "请选择（可多选，空格分隔，如 2 3 4）: " choice </dev/tty || exit 1
    read -r -a picks <<<"$choice"
    ok=1
    [ "${#picks[@]}" -eq 0 ] && ok=0
    for n in "${picks[@]}"; do
      case "$n" in
        0) exit 0 ;;
        1) DO_NET=1; DO_IP=1; TCP_ROUTE=1; TCP_LARGE=1; TCP_EDU=1 ;;
        2) DO_NET=1 ;;
        3) DO_IP=1 ;;
        4) TCP_ROUTE=1; TCP_LARGE=1; TCP_EDU=1 ;;
        5) TCP_ROUTE=1 ;;
        6) TCP_LARGE=1 ;;
        7) TCP_EDU=1 ;;
        *) ok=0 ;;
      esac
    done
    [ "$ok" -eq 1 ] && break
    DO_NET=0; DO_IP=0; TCP_ROUTE=0; TCP_LARGE=0; TCP_EDU=0
    err="输入无效，请重新选择"
  done

  [ $((OPT_ONLY4 + OPT_ONLY6)) -eq 0 ] && show_fam_menu
}

# 协议选择：自动按检测结果，或指定 IPv4 / IPv6
show_fam_menu() {
  local choice auto err=""
  if [ "$HAS_V4" -eq 1 ] && [ "$HAS_V6" -eq 1 ]; then auto="双栈"
  elif [ "$HAS_V4" -eq 1 ]; then auto="IPv4"
  else auto="IPv6"; fi
  while :; do
    ui_clear
    {
      printf '%s%s%s\n' "$C_BOLD$C_W" "$(ui_pad "测试协议" "$UI_W" c)" "$C_0"
      ui_line '='
      ui_kv "IPv4" "${PUB4:-${C_D}未检测到${C_0}}"
      ui_kv "IPv6" "${PUB6:-${C_D}未检测到${C_0}}"
      ui_line '-'
      printf '  1. 自动 %s\n' "${C_D}(${auto})${C_0}"
      printf '  2. 仅 IPv4\n'
      printf '  3. 仅 IPv6\n'
      printf '  0. 退出\n'
      ui_line '-'
      [ -n "$err" ] && echo "${C_Y}${err}${C_0}"
    } >&2
    read -r -p "请选择（回车=自动）: " choice </dev/tty || exit 1
    case "${choice// /}" in
      ""|1) return 0 ;;
      2) [ "$HAS_V4" -eq 1 ] && { OPT_ONLY4=1; return 0; }
         err="本机没有 IPv4 公网地址，请重新选择" ;;
      3) [ "$HAS_V6" -eq 1 ] && { OPT_ONLY6=1; return 0; }
         err="本机没有 IPv6 公网地址，请重新选择" ;;
      0) exit 0 ;;
      *) err="输入无效，请重新选择" ;;
    esac
  done
}

# ==================== 主流程 ====================

selected_items() {
  local -a s=()
  [ "$DO_NET" -eq 1 ] && s+=("网络信息")
  [ "$DO_IP" -eq 1 ] && s+=("IP 质量")
  [ "$TCP_ROUTE" -eq 1 ] && s+=("三网回程")
  [ "$TCP_LARGE" -eq 1 ] && s+=("大包回程")
  [ "$TCP_EDU" -eq 1 ] && s+=("教育网回程")
  local IFS='/'
  echo "${s[*]}" | sed 's#/# / #g'
}

print_header() {
  ui_line '='
  printf '%s%s%s\n' "$C_BOLD$C_W" "$(ui_pad "VPSCheck v${VERSION}  -  VPS 综合检测" "$UI_W" c)" "$C_0"
  ui_line '='
  ui_kv "检测时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  ui_kv "IPv4" "${PUB4:-${C_D}未检测到${C_0}}"
  ui_kv "IPv6" "${PUB6:-${C_D}未检测到${C_0}}"
  ui_kv "检测项目" "$(selected_items)"
}

run_checks() {
  local start fam
  start=$(date +%s)
  print_header

  for fam in 4 6; do
    [ "$fam" = 4 ] && { [ "$RUN_V4" -eq 1 ] || continue; }
    [ "$fam" = 6 ] && { [ "$RUN_V6" -eq 1 ] || continue; }
    [ "$DO_NET" -eq 1 ] && net_run "$fam"
  done
  for fam in 4 6; do
    [ "$fam" = 4 ] && { [ "$RUN_V4" -eq 1 ] || continue; }
    [ "$fam" = 6 ] && { [ "$RUN_V6" -eq 1 ] || continue; }
    [ "$DO_IP" -eq 1 ] && ip_run "$fam"
  done
  if [ $((TCP_ROUTE + TCP_LARGE + TCP_EDU)) -gt 0 ]; then
    if [ "$IS_ROOT" -eq 1 ]; then
      tcp_run
    else
      ui_section "TCP 回程"
      ui_warn "回程检测需要 root 权限"
    fi
  fi

  printf '\n'
  ui_line '='
  printf '  检测完成，用时 %s\n' "$(fmt_duration $(( $(date +%s) - start )))"
}

cleanup() {
  ui_prog_clear
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}

# 结束某进程的全部子孙进程（不含自身）
kill_tree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$c"
    kill "$c" 2>/dev/null
  done
}

on_interrupt() {
  trap - INT TERM
  ui_prog_clear
  echo "${C_Y}已中断${C_0}" >&2
  cleanup
  trap '' TERM
  if [ "$(cut -d' ' -f5 "/proc/$$/stat" 2>/dev/null)" = "$$" ]; then
    kill 0 2>/dev/null
  else
    kill_tree $$
  fi
  exit "${1:-130}"
}

main() {
  setup_colors
  local has_items=0
  parse_args "$@" && has_items=1

  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/vpscheck.XXXXXX") || { echo "无法创建临时目录" >&2; exit 1; }
  trap cleanup EXIT
  trap 'on_interrupt 130' INT
  trap 'on_interrupt 143' TERM
  timeout --foreground 5 true >/dev/null 2>&1 && RUN_TO_FG=1

  command -v curl >/dev/null 2>&1 || { echo "需要 curl，请先安装" >&2; exit 1; }
  ui_prog "正在获取公网 IP"
  detect_public_ips
  ui_prog_clear
  if [ "$HAS_V4" -eq 0 ] && [ "$HAS_V6" -eq 0 ]; then
    echo "${C_R}无法获取公网 IP，请检查网络连接${C_0}" >&2
    exit 1
  fi

  if [ "$has_items" -eq 0 ]; then
    if [ -t 0 ] && [ -t 2 ]; then
      show_menu
      ui_clear
    else
      show_help >&2
      exit 1
    fi
  fi

  RUN_V4=$HAS_V4
  RUN_V6=$HAS_V6
  [ "$OPT_ONLY4" -eq 1 ] && RUN_V6=0
  [ "$OPT_ONLY6" -eq 1 ] && RUN_V4=0
  if [ "$RUN_V4" -eq 0 ] && [ "$RUN_V6" -eq 0 ]; then
    echo "${C_R}本机没有可用的 IPv$([ "$OPT_ONLY4" -eq 1 ] && echo 4 || echo 6) 公网地址${C_0}" >&2
    exit 1
  fi

  ensure_deps
  if [ "$has_items" -eq 0 ]; then
    # 安装失败的提示留在屏幕上，按回车后再清屏
    [ "$DEPS_FAILED" -eq 1 ] && read -r -p "按回车继续…" _ </dev/tty
    ui_clear
  fi

  if [ -n "$OPT_OUTPUT" ]; then
    local raw="$WORKDIR/report.ansi"
    run_checks | tee "$raw"
    if sed $'s/\033\\[[0-9;]*m//g' "$raw" > "$OPT_OUTPUT" 2>/dev/null; then
      echo "  报告已保存到 $OPT_OUTPUT"
    else
      echo "${C_R}  报告保存失败：$OPT_OUTPUT${C_0}" >&2
      exit 1
    fi
  else
    run_checks
  fi
}

# 被 source 时只加载函数，不执行（便于单独调试各模块）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
