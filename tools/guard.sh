#!/usr/bin/env bash
#
# 静态护栏（成本极低，放在 golden 矩阵之前跑）。
#
# 防的是 ADR 0006 记录的两个坑：
#   坑 1 —— 批量给符号加「包名前缀」时误伤**字符串字面量**，
#           输出文本被静默改坏（`"OK slice_map"` -> `"OK search.slice_map"`）。
#           这类问题 golden 矩阵能抓到，但要跑完全部命令才发现；这里提前拦。
#   坑 2 —— 提取顶层声明时漏掉 `:` / `:=` 形式，符号拿不到前缀，
#           编译报 Undeclared（ loud，但返工成本高）。
#
# 三道检查：
#   1. 工具自检         —— 证明工具本身仍能正确处理字符串/注释/字段/切片/局部变量
#   2. 字面量污染检测   —— 扫描全部 .odin，字符串里不允许出现 `<包>.<已知符号>`
#   3. 包依赖方向       —— main -> app -> engine -> search -> lib 单向，禁止反向
#
# 退出码非 0 即视为验收失败。

set -uo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-python3}"

echo "---- 重构工具自检 ----"
"$PY" tools/odin_qualify.py selftest || exit 1
echo

echo "---- 字面量污染检测 ----"
"$PY" tools/odin_qualify.py check-literals || exit 1
echo

echo "---- 包依赖方向 ----"
make deps || exit 1
