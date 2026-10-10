#!/usr/bin/env bash
#
# tests/lib.sh — run2.sh / run3.sh 共用的断言小工具
#
# 只做四件事：跑二进制并分离 stdout/stderr/退出码，提供一组断言，
# 统计 PASS/FAIL，最后打印汇总并按结果退出。
#
# 用法（在 run*.sh 里）：
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   SUITE="run2.sh（ADR 0002 行为）"
#   BIN="$1"; REPO=...
#   ...断言...
#   summary
#
set -uo pipefail

PASS=0
FAIL=0
FAILED=()

ok() {
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  printf '  FAIL  %s\n' "$1"
}

# eq <名字> <期望> <实际>
eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    bad "$1"
    printf '        期望: [%s]\n        实际: [%s]\n' "$2" "$3"
  fi
}

# has <名字> <文本> <必须包含的子串>
has() {
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1"
    printf '        期望包含: [%s]\n        实际:     [%s]\n' "$3" "$2"
  fi
}

# hasnt <名字> <文本> <必须不包含的子串>
hasnt() {
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    bad "$1"
    printf '        期望不含: [%s]\n        实际:     [%s]\n' "$3" "$2"
  fi
}

# file_eq <名字> <路径> <期望内容>
file_eq() {
  local want="$3" got=""
  if [[ -f "$2" ]]; then
    got="$(cat "$2")"
  fi
  eq "$1" "$want" "$got"
}

exists() {
  if [[ -f "$2" ]]; then
    ok "$1"
  else
    bad "$1"
    printf '        期望存在的文件: %s\n' "$2"
  fi
}

missing() {
  if [[ ! -e "$2" ]]; then
    ok "$1"
  else
    bad "$1"
    printf '        期望不存在的路径: %s\n' "$2"
  fi
}

# 跑一次二进制：结果放进 OUT / ERR / CODE（在仓库根目录下执行，路径一律相对）。
run() {
  local outf="$SCRATCH/.out" errf="$SCRATCH/.err"
  (cd "$REPO" && "$BIN" "$@") >"$outf" 2>"$errf"
  CODE=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
}

summary() {
  echo
  echo "==== ${SUITE}: $((PASS + FAIL)) 条断言，PASS=$PASS FAIL=$FAIL ===="
  if [[ $FAIL -eq 0 ]]; then
    exit 0
  fi
  printf '失败断言：\n'
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
}
