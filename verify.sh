#!/usr/bin/env bash
#
# xrep 完整验收脚本（一条命令跑完）
#
# 做什么：
#   0. tools/guard.sh —— 静态护栏（重构工具自检 + 字面量污染检测 + 包依赖方向）
#   1. ./test.sh      —— odin test 单元测试（含内存泄漏检查）+ 内建自检 --test
#   2. tests/run.sh   —— 历史命令 golden 矩阵（stdout/stderr/退出码/产出文件逐字节比对）
#   3. tests/run2.sh  —— ADR 0002 新增/变更行为的断言
#   4. tests/run3.sh  —— krep 对齐功能（ADR 0005）的断言
#
# 为什么分这么多层：`odin test` 覆盖函数级行为，但**输出文本**没法在里面验 ——
# 测试运行器并行跑用例，捕获进程级 stdout 会被其它用例污染（见 README）。
# 输出文本因此交给 2/3/4 这三套外部进程矩阵，它们各自一个进程、互不干扰。
# 第 0 层是后来加的：ADR 0006 拆包时踩过"批量加前缀误伤字符串字面量"的坑，
# 那种改坏是静默的，越早拦住越便宜。
#
# 常用变体：
#   ./verify.sh                # 全部
#   ./verify.sh --update       # 重新生成 golden（**仅在有意改行为时**）
#   TESTS_FILTER=dump ./verify.sh
#
set -uo pipefail

cd "$(dirname "$0")"

UPDATE=""
if [[ "${1:-}" == "--update" ]]; then
  UPDATE="--update"
  echo "!! --update：golden 将被重新生成，请在 commit 里逐条解释每一处 diff"
  echo
fi

FAILED_STAGES=()

run_stage() {
  local name="$1"
  shift
  echo
  echo "################ $name ################"
  if "$@"; then
    echo "---- $name: OK"
  else
    echo "---- $name: FAILED"
    FAILED_STAGES+=("$name")
  fi
}

# 静态护栏先行：成本极低，且能在跑完 78 条命令之前就抓住静默的文本改坏。
run_stage "静态护栏（字面量 / 包依赖）" ./tools/guard.sh

# test.sh 内部会调用 build.sh，因此跑完它之后 ./xrep 一定是最新的。
run_stage "单元测试 + 内建自检" ./test.sh
run_stage "历史命令 golden 矩阵" ./tests/run.sh $UPDATE ./xrep
if [[ -z "$UPDATE" ]]; then
  run_stage "ADR 0002 行为断言" ./tests/run2.sh ./xrep
  run_stage "krep 对齐功能断言" ./tests/run3.sh ./xrep
fi

echo
echo "################ 验收汇总 ################"
if [[ ${#FAILED_STAGES[@]} -eq 0 ]]; then
  echo "全部通过"
  exit 0
fi
printf '未通过的阶段：\n'
printf '  - %s\n' "${FAILED_STAGES[@]}"
exit 1
