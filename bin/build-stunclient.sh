#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
#
# 静态编译 stuntman 的 stunclient（VPSCheck 的 NAT 检测用）。
# 在 Alpine 容器内运行（musl + 静态链接 OpenSSL），产物不依赖任何系统库：
#
#   docker run --rm -v "$PWD:/work" -w /work alpine:3.22 sh bin/build-stunclient.sh
#
# 产物：dist/stunclient_linux_<amd64|arm64>
# stuntman 源码：https://github.com/jselbie/stunserver（Apache-2.0）

set -eu

# master 2026-02-13（1.2.16 之后）：兼容 OpenSSL 1.1 / 3，含过滤行为测试的修复。
# 最后一个标签 version1.2.13 只支持 OpenSSL 1.0，无法编译。
STUNTMAN_REPO="https://github.com/jselbie/stunserver.git"
STUNTMAN_COMMIT="1582042ca33f747f88101fbadec4944714aa8bbb"

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac

apk add --no-cache build-base boost-dev openssl-dev openssl-libs-static git file >/dev/null

src=$(mktemp -d)
git -C "$src" init --quiet
git -C "$src" fetch --quiet --depth 1 "$STUNTMAN_REPO" "$STUNTMAN_COMMIT"
git -C "$src" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
actual=$(git -C "$src" rev-parse HEAD)
if [ "$actual" != "$STUNTMAN_COMMIT" ]; then
  echo "源码提交不符：期望 $STUNTMAN_COMMIT，实际 $actual" >&2
  exit 1
fi

# 只编译客户端需要的部分
for d in common stuncore networkutils client; do
  make -C "$src/$d" LDFLAGS="-static -s" >/dev/null
done

out="dist/stunclient_linux_${arch}"
mkdir -p dist
cp "$src/client/stunclient" "$out"

file "$out"
if ! file "$out" | grep -q 'statically linked'; then
  echo "产物不是静态链接" >&2
  exit 1
fi
"$out" --help >/dev/null
sha256sum "$out"
