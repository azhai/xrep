#!/usr/bin/env bash
#
# tests/run3.sh — krep 对齐功能的断言（ADR 0005）
#
#   -r / glob / exclude / hidden、-l / -L、-n、-o、-m、-e / -f、--json、--stats、
#   --color、短标志捆绑与归一化、以及"单文件默认输出"的回归护栏。
#
# 用法：tests/run3.sh <bin>
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib.sh"

SUITE="run3.sh（krep 对齐功能）"
BIN="${1:-$REPO/xrep}"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行二进制: $BIN" >&2
  exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/xrep_run3_XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

A=tests/fixtures/a.txt
B=tests/fixtures/b.txt
DIR=tests/fixtures/dir
PATS=tests/fixtures/pats.txt
S="$SCRATCH"

# 取 stdout 里第一条 `context hex` 行，判断是否含 ANSI 转义。
# 之所以只看这一行：进度条那一行在 --color never 下**仍然着色**（见文末已知缺陷），
# 整段判空会把缺陷当成断言失败，而这里要验的是"命中字节的着色"。
esc_in_ctx() {
  local line
  line="$(printf '%s\n' "$OUT" | grep 'context hex' | head -1)"
  case "$line" in
  *$'\033'*) echo 1 ;;
  *) echo 0 ;;
  esac
}

echo "==== tests/run3.sh: krep 对齐功能断言 ===="
echo "bin = $BIN"
echo

# ---------------------------------------------------------------------------
# 1) -r 递归与过滤
# ---------------------------------------------------------------------------
run -r test $DIR
has "walk-r-递归展开目录" "$OUT" "Scanned 4 files, total hits: 3"
hasnt "walk-r-默认跳过隐藏项" "$OUT" ".hidden"

run -r --hidden test $DIR
has "walk-r---hidden 收录隐藏项" "$OUT" "Scanned 5 files, total hits: 4"
has "walk-r---hidden 命中隐藏文件" "$OUT" "tests/fixtures/dir/.hidden/e.txt:1:0"

run -r --glob '*.txt' test $DIR
has "walk-r---glob 只收 txt" "$OUT" "Scanned 2 files, total hits: 2"
hasnt "walk-r---glob 排除 .bin" "$OUT" "b.bin"

run -r --exclude sub test $DIR
has "walk-r---exclude 排除目录" "$OUT" "Scanned 2 files, total hits: 2"
hasnt "walk-r---exclude 的目录不再出现" "$OUT" "sub/c.txt"

run -r --exclude '*.bin' test $DIR
hasnt "walk-r---exclude 按 glob 排除" "$OUT" "b.bin"

run test $DIR
has "walk-非递归传目录-报错而非静默" "$ERR" "is a directory (use -r to search recursively)"

run -r test $DIR
has "walk-r-结果按条目名排序" "$OUT" "tests/fixtures/dir/a.txt:1:0
tests/fixtures/dir/b.bin:1:0
tests/fixtures/dir/sub/c.txt:1:0"

# ---------------------------------------------------------------------------
# 2) -l / -L（只列"有/无命中"的文件名）
# ---------------------------------------------------------------------------
run -l test $A
eq "list-l-有命中时只打文件名" "tests/fixtures/a.txt" "$OUT"
run -l zzz-nope $A
eq "list-l-无命中时不打印" "" "$OUT"
run -L zzz-nope $A
eq "list-L-无命中时打文件名" "tests/fixtures/a.txt" "$OUT"
run -L test $A
eq "list-L-有命中时不打印" "" "$OUT"

run -r -l test $DIR
eq "list-l-递归只列有命中的" "tests/fixtures/dir/a.txt
tests/fixtures/dir/b.bin
tests/fixtures/dir/sub/c.txt" "$OUT"

run -l --json test $A
eq "list-l---json 输出对象而非裸文件名" '{"file":"tests/fixtures/a.txt","matched":true}' "$OUT"

# ---------------------------------------------------------------------------
# 3) -n / -o / -m
# ---------------------------------------------------------------------------
run -n test $A
eq "line-n-单文件输出 行:偏移" "1:6
2:17
5:58" "$OUT"

run -n test $A $B
has "line-n-多文件输出 路径:行:偏移" "$OUT" "tests/fixtures/a.txt:1:6"

run -o test $A
has "only-matching-打印命中字节的 hex" "$OUT" "  matched hex: 74657374"

run -m 2 test $A
has "max-count-保留前 2 条" "$OUT" "match offset: 17"
hasnt "max-count-第 3 条被截掉" "$OUT" "match offset: 58"

run -m 0 test $A
has "max-count-0 表示不限" "$OUT" "match offset: 58"

# ---------------------------------------------------------------------------
# 4) -e / -f 多模式
# ---------------------------------------------------------------------------
run -e test -e world -c $A
has "multi-e-多模式命中累加" "$OUT" "tests/fixtures/a.txt: 4 hits"

run -f $PATS -c $A
has "multi-f-从文件读模式" "$OUT" "tests/fixtures/a.txt: 3 hits"

run -e test -c $A
has "multi-e-有 -e 时位置参数全是文件" "$OUT" "tests/fixtures/a.txt: 3 hits"

# ---------------------------------------------------------------------------
# 5) --json / --jsonl
# ---------------------------------------------------------------------------
run --json test $A
has "json-字段齐全" "$OUT" '{"file":"tests/fixtures/a.txt","line":1,"offset":6,"len":4}'
hasnt "json-结构化模式下不带进度条" "$OUT" "bytes"

run --json --count test $A
eq "json-count-输出计数对象" '{"file":"tests/fixtures/a.txt","count":3}' "$OUT"

run --jsonl test $A
has "jsonl-与 --json 同义" "$OUT" '"offset":6'

# ---------------------------------------------------------------------------
# 6) --stats（写 stderr，含计时值故只验字段）
# ---------------------------------------------------------------------------
run --stats test $A
has "stats-写 stderr" "$ERR" "stats: 1 files scanned"
has "stats-含字节数" "$ERR" "63 bytes"
has "stats-含命中数" "$ERR" "3 hits"
hasnt "stats-不写 stdout" "$OUT" "stats:"

# 整段 stdout 里有没有 ANSI 转义（回归护栏：进度条曾经绕过 --color，
# 见 README 已知行为与限制里被修掉的那条 —— 形参写反导致 use_color 恒为 true）。
esc_anywhere() {
  case "$OUT" in
  *$'\033'*) echo 1 ;;
  *) echo 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# 7) --color（ADR 0005：--no-color 真正生效）
# ---------------------------------------------------------------------------
run --color never --context 4 test $A
eq "color-never-命中字节不着色" "0" "$(esc_in_ctx)"
eq "color-never-整段输出无 ANSI（含进度条）" "0" "$(esc_anywhere)"

run --no-color --context 4 test $A
eq "color-no-color-与 --color never 等价（命中）" "0" "$(esc_in_ctx)"
eq "color-no-color-整段输出无 ANSI（含进度条）" "0" "$(esc_anywhere)"

# --color auto：本矩阵的 stdout 全是管道（非 TTY），故应当完全不着色。
run --color auto --context 4 test $A
eq "color-auto-非 TTY 下整段无 ANSI" "0" "$(esc_anywhere)"

run --color always --context 4 test $A
eq "color-always-命中字节着色" "1" "$(esc_in_ctx)"
eq "color-always-整段输出有 ANSI" "1" "$(esc_anywhere)"

# 默认就是 always
run --context 4 test $A
eq "color-默认即 always" "1" "$(esc_anywhere)"

# ---------------------------------------------------------------------------
# 8) 短标志捆绑 / 归一化（--k=v、-t8、-rn）
# ---------------------------------------------------------------------------
run -rn test $DIR
has "short--rn 等价于 -r -n" "$OUT" "tests/fixtures/dir/a.txt:1:0"
run -r -n test $DIR
has "short--rn 与分开写结果一致" "$OUT" "tests/fixtures/dir/a.txt:1:0"

run -t8 -c test $A
has "short--t8 附着值生效" "$OUT" "tests/fixtures/a.txt: 3 hits"
run --threads=8 -c test $A
has "equals---threads=8 生效" "$OUT" "tests/fixtures/a.txt: 3 hits"
# fixture 里既有 "test"（3 处）也有 "TEST"（1 处），正好用来区分两种大小写语义。
run -i TEST -c $A
has "short--i 等价于 --ignore-case（两态都命中）" "$OUT" "tests/fixtures/a.txt: 4 hits"

# ---------------------------------------------------------------------------
# 9) 大小写与区间
# ---------------------------------------------------------------------------
run -c TEST $A
# 大写模式在大小写敏感下只命中那 1 处大写的 "TEST"，3 处小写 "test" 不算。
has "case-默认大小写敏感（只命中同形）" "$OUT" "tests/fixtures/a.txt: 1 hits"

run --after 20 -c test $A
has "after-过滤掉小偏移" "$OUT" "tests/fixtures/a.txt: 1 hits"
run --before 20 -c test $A
has "before-过滤掉大偏移" "$OUT" "tests/fixtures/a.txt: 2 hits"

run --offset-hex test $A
has "offset-hex-十六进制输出" "$OUT" "match offset: 0x6"

run --context 4 test $A
has "context-N-打印 hex 上下文" "$OUT" "  context hex: "

# ---------------------------------------------------------------------------
# 10) 回归护栏：单文件默认输出必须仍是"偏移导向"
# ---------------------------------------------------------------------------
run test $A
has "护栏-单文件默认仍是 match offset" "$OUT" "match offset: 6"
has "护栏-单文件默认仍有 results 汇总行" "$OUT" "=== tests/fixtures/a.txt: 1 results ==="
# 已知行为 #3：pretty 汇总会先丢弃前 2 条命中（3 命中 → 显示 1 条）。
has "护栏-pretty 汇总丢弃前 2 条（已知行为#3）" "$OUT" "=== tests/fixtures/a.txt: 1 results ==="

rm -f "$S/lim.txt"
run --limit 1 --dump "$S/lim.txt" test $A
file_eq "limit-不影响 dump（--dump 用完整结果集）" "$S/lim.txt" "6
17
58"

summary
