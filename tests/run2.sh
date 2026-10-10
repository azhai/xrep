#!/usr/bin/env bash
#
# tests/run2.sh — ADR 0002 那批"新增/变更行为"的断言
#
#   版本、线程数夹取（0 / 超大 / 非法）、dump-prefix 清洗、dump 落盘失败退出码、
#   --skip-empty、--dump-append、--max-size、多文件汇总、空文件、参数互斥。
#
# 用法：tests/run2.sh <bin>
#
# 与 run.sh 的分工：run.sh 是"逐字节快照"（golden，不知道对错，只报变化），
# 这里每一条都是**有明确对错**的断言 —— 行为被无意改坏时它会直接指名道姓。
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib.sh"

SUITE="run2.sh（ADR 0002 行为）"
BIN="${1:-$REPO/xrep}"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行二进制: $BIN" >&2
  exit 2
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/xrep_run2_XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

A=tests/fixtures/a.txt
B=tests/fixtures/b.txt
EMPTY=tests/fixtures/empty.bin
S="$SCRATCH" # 落盘输出一律写到临时目录，不在仓库里留痕

echo "==== tests/run2.sh: ADR 0002 行为断言 ===="
echo "bin = $BIN"
echo

# ---------------------------------------------------------------------------
# 1) --version（纯增量选项）
# ---------------------------------------------------------------------------
run --version
eq "version-打印版本号" "xrep 0.3.0" "$OUT"
eq "version-退出码为 0" "0" "$CODE"
run -v
eq "version-短标志 -v 等价" "xrep 0.3.0" "$OUT"

# ---------------------------------------------------------------------------
# 2) 线程数夹取（ADR 0002 §3：0 与超大值都不再静默/挂死）
# ---------------------------------------------------------------------------
# 注意：-c 属于"传统输出模式"，进度条会先打一行再打结论行，
# 因此这里一律用 has 匹配结论行，不用 eq 比对整段 stdout。
run --threads 0 -c test $A
has "threads-0-不再静默 0 命中" "$OUT" "tests/fixtures/a.txt: 3 hits"
run -t 1 -c test $A
has "threads-0-与 -t 1 等价" "$OUT" "tests/fixtures/a.txt: 3 hits"

run --threads 100000 -c test $A
eq "threads-超大值-不挂死（退出码 0）" "0" "$CODE"
has "threads-超大值-命中数正确" "$OUT" "tests/fixtures/a.txt: 3 hits"

run --threads abc -c test $A
eq "threads-非法值-退出码 1" "1" "$CODE"
has "threads-非法值-写 stderr" "$ERR" "threads"

# ---------------------------------------------------------------------------
# 3) --dump-prefix 清洗（ADR 0002 §1：唯一的契约变更）
# ---------------------------------------------------------------------------
rm -rf "$S/pfx1"
mkdir -p "$S/pfx1"
run --dump-prefix "$S/pfx1/" test ./$A
eq "dump-prefix-含 './' 也能落盘（退出码 0）" "0" "$CODE"
exists "dump-prefix-产出文件" "$S/pfx1/._tests_fixtures_a.txt.txt"
file_eq "dump-prefix-内容是全部命中" "$S/pfx1/._tests_fixtures_a.txt.txt" "6
17
58"

rm -rf "$S/pfx2"
mkdir -p "$S/pfx2"
run --dump-prefix "$S/pfx2/" test $A
exists "dump-prefix-普通相对路径" "$S/pfx2/tests_fixtures_a.txt.txt"

# ---------------------------------------------------------------------------
# 4) dump 内容与落盘失败退出码
# ---------------------------------------------------------------------------
rm -f "$S/d.txt"
run --dump "$S/d.txt" test $A
file_eq "dump-内容按偏移升序" "$S/d.txt" "6
17
58"

run --dump "$S/no-such-dir/d.txt" test $A
eq "dump-落盘失败-退出码 1" "1" "$CODE"
has "dump-落盘失败-原因写 stderr" "$ERR" "Failed to open dump file"

# ---------------------------------------------------------------------------
# 5) --skip-empty（0 命中时是否产出文件）
# ---------------------------------------------------------------------------
rm -f "$S/se0.txt"
run --dump "$S/se0.txt" --skip-empty zzz-nope $A
missing "skip-empty-0 命中不产出文件" "$S/se0.txt"

rm -f "$S/se1.txt"
run --dump "$S/se1.txt" zzz-nope $A
exists "默认-0 命中仍产出空文件" "$S/se1.txt"
file_eq "默认-0 命中产出的是空文件" "$S/se1.txt" ""

rm -f "$S/se2.txt"
run --dump "$S/se2.txt" --skip-empty test $A
exists "skip-empty-有命中照样产出" "$S/se2.txt"

# ---------------------------------------------------------------------------
# 6) --dump-append（追加而非覆盖）
# ---------------------------------------------------------------------------
rm -f "$S/ap.txt"
run --dump "$S/ap.txt" test $A
file_eq "append-第一次是覆盖写" "$S/ap.txt" "6
17
58"
run --dump "$S/ap.txt" --dump-append test $A
file_eq "append-第二次追加后内容翻倍" "$S/ap.txt" "6
17
58
6
17
58"

# ---------------------------------------------------------------------------
# 7) --max-size（读入前按大小跳过）
# ---------------------------------------------------------------------------
rm -f "$S/ms.txt"
run --max-size 10 --dump "$S/ms.txt" -c test $A
# 被跳过的文件"不是 0 命中，而是没扫"，因此 stdout **连 0 hits 都不打印**
# （打印 0 hits 会让脚本误判成"扫过且没命中"）。原因固定写 stderr。
eq "max-size-跳过时 stdout 完全无声" "" "$OUT"
has "max-size-跳过原因写 stderr" "$ERR" "exceeds --max-size"
missing "max-size-跳过的文件不落盘" "$S/ms.txt"

run --max-size 1000 -c test $A
has "max-size-未超限时正常扫描" "$OUT" "tests/fixtures/a.txt: 3 hits"

run --max-size abc -c test $A
eq "max-size-非法值-退出码 1" "1" "$CODE"

# ---------------------------------------------------------------------------
# 8) 多文件汇总与 --quiet
# ---------------------------------------------------------------------------
run -n test $A $B
has "多文件-汇总行" "$OUT" "Scanned 2 files, total hits: 3"
run -q test $A $B
eq "quiet-不打印汇总行" "" "$OUT"

# ---------------------------------------------------------------------------
# 9) 空文件（快速跳过并行路径，但落盘语义不变）
# ---------------------------------------------------------------------------
run -c test $EMPTY
# 空文件走"快速跳过并行路径"：不建线程池、不渲染进度条，故 stdout 只有结论行。
eq "空文件-0 命中" "tests/fixtures/empty.bin: 0 hits" "$OUT"
rm -f "$S/emp.txt"
run --dump "$S/emp.txt" test $EMPTY
exists "空文件-仍产出 dump 文件" "$S/emp.txt"
file_eq "空文件-dump 内容为空" "$S/emp.txt" ""

# ---------------------------------------------------------------------------
# 10) 参数互斥
# ---------------------------------------------------------------------------
run --dump "$S/x.txt" --dump-prefix "$S/p_" test $A
eq "dump 与 dump-prefix 互斥-退出码 1" "1" "$CODE"
has "dump 与 dump-prefix 互斥-写 stderr" "$ERR" "dump"

summary
