#!/usr/bin/env bash
#
# xrep 编译脚本
#
# 说明：
#   - 本机 PATH 里的 `clang` 被 Android NDK 的 x86_64 clang 抢先占用，
#     会导致 Odin 链接失败（对象文件无法识别）。
#   - 因此显式指定 ODIN_CC 为系统 Apple clang，并强制使用 lld 链接器。
#
set -euo pipefail

cd "$(dirname "$0")"

# 输出二进制名
OUT="${OUT:-xrep}"

# 源码已按职责拆成子目录包（lib/search/engine/app），见 ADR 0006 / ADR 0007。
# Odin 的 import 路径是**相对源文件所在目录**解析的，兄弟包之间必须靠
# collection 才能互相引用，因此统一加 -collection:xrep=.  （路径相对仓库根）。
COLLECTION="${COLLECTION:-xrep=.}"

# 可选：-o:none|-o:minimal|-o:size|-o:speed（默认 size，兼顾体积与性能）
OPT="${OPT:-size}"

# 切换为目标平台路径下的系统 Apple clang
if [[ -x /usr/bin/clang ]]; then
  export ODIN_CC="${ODIN_CC:-/usr/bin/clang}"
fi

echo "ODIN_CC = ${ODIN_CC:-<系统默认>}"
echo "==== odin build -o:${OPT} ===="

odin build . \
  -collection:"${COLLECTION}" \
  -o:"${OPT}" \
  -linker:lld \
  -out:"${OUT}"

echo "==== 构建完成: ./${OUT} ===="
echo "用法: ./${OUT} <模式> [文件...] [标志]   (见 ./${OUT} --help)"