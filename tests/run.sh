#!/usr/bin/env bash
#
# tests/run.sh — 历史命令回归矩阵（golden / characterization test）
#
# 做什么：把一批"历史命令"逐条跑一遍，为每条采集
#   argv（隐去二进制路径）、退出码、stdout、stderr、以及它产出的**所有文件**，
# 与 tests/golden/<name>.txt 逐字节比对。
#
# 为什么需要它：`odin test` 默认并行跑用例，而输出写的是进程级 stdout ——
# 单元测试里捕获 fd 1 会被其它用例污染（见 README）。**输出文本**只能靠
# 外部进程这样验收：每个命令一个独立进程、独立工作目录，互不干扰。
#
# 用法：
#   tests/run.sh <bin> [outdir]            # 比对 golden，打印 PASS/FAIL 与 diff
#   tests/run.sh --update <bin> [outdir]   # **重新生成** golden
#   TESTS_FILTER=dump tests/run.sh ...     # 只跑名字含 "dump" 的命令
#
# 纪律（README「行为验收矩阵」）：
#   * golden 记录的是**当前 HEAD 的行为**（重构早已合入，"改动前"已无从取得），
#     因此它是一张"现状快照"，不是"重构前后等价"的证明。
#   * 等价重构   → diff 必须为空；
#   * 有意改行为 → 用 --update 重新生成，并在 commit 里逐条解释每一处 diff。
#
# 可复现性的三个前提（写新命令时必须遵守，否则 golden 会变成噪声源）：
#   1. 全部用**相对路径**（cwd = 仓库根）；脚本会把绝对路径归一化为 @OUT@/@REPO@。
#   2. **不要**把 --stats / --bench 放进这里：它们打印计时值（%.2f ms），
#      每次运行都不同。计时类断言放在 run3.sh 里做字段级检查。
#   3. fixture 保持小（< 2 MiB）：单分片 → 单 worker 产出 → 打印顺序确定；
#      且耗时远低于进度条的 200 ms 刷新间隔 → 不会插入带百分比的中间帧。
#
# 唯一的例外是末尾两条 chunk-overlap-* 命令：它们**故意**用 2 MiB+ 的文件
# 去跨分片。多 worker 时"逐条流式打印"的先后顺序取决于调度，因此这两条
# 一律用 `-c`（只打一行结论）+ `--dump`（归并后按偏移有序，与调度无关），
# 把可观察输出压成两段确定的文本。**不要**给它们去掉 -c。
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$REPO/tests/golden"

UPDATE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE=1
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "用法: tests/run.sh [--update] <bin> [outdir]" >&2
  exit 2
fi

BIN="$1"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行二进制: $BIN" >&2
  exit 2
fi
# 归一化成绝对路径：脚本内部会先 cd 到仓库根，相对路径会失效。
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
OUT="${2:-$REPO/tests/.out}"

# 每轮运行用一棵**全新的**临时树，退出时整棵删掉：
#   $OUT/run-<pid>/<name>        每条命令的产出目录
#   $OUT/run-<pid>/.cap/<name>   本脚本的账本
#   $OUT/run-<pid>/.setup/       现造的大文件（分片边界那两条要用）
# 之所以不"每条命令跑完就 rm"：有些环境（含 CI 沙箱）会拦截并审计 rm，
# 77 次调用能把一轮验收从几秒拖到一分钟。改成整棵树删一次，既快又避开
# "单轮批量删除上限"这类限制。
RUN="$OUT/run-$$"
SETUP="$RUN/.setup"
mkdir -p "$RUN" || {
  echo "无法创建 $RUN" >&2
  exit 1
}
trap 'rm -rf "$RUN"' EXIT

# 分片边界相关的两条命令需要一个"大于一个分片"的输入（TASK_CHUNK_SIZE = 2 MiB，
# 见 lib/base.odin）。这种文件不进仓库（2 MiB × 2），在临时目录里现造：
# 全 'z' 填充，只在关键偏移埋一处 "test"。
#   chunk_straddle.bin —— 埋在 chunk-2：跨越分片边界，只被前一个任务看到
#   chunk_dup.bin      —— 埋在 chunk  ：完全落在重叠窗口内，被两个任务各报一次
setup_large_fixtures() {
  mkdir -p "$SETUP"
  local chunk=$((2 * 1024 * 1024)) # TASK_CHUNK_SIZE；改动它 golden 会跟着变
  local size=$((chunk + 1024))
  local f
  for f in chunk_straddle chunk_dup; do
    head -c "$size" /dev/zero | tr '\000' 'z' >"$SETUP/$f.bin"
  done
  printf 'test' | dd of="$SETUP/chunk_straddle.bin" bs=1 seek=$((chunk - 2)) conv=notrunc 2>/dev/null
  printf 'test' | dd of="$SETUP/chunk_dup.bin" bs=1 seek=$chunk conv=notrunc 2>/dev/null
}
setup_large_fixtures

# 全程在仓库根下执行：所有命令的参数都是相对路径（golden 可移植的前提之一）。
cd "$REPO"
# 字节序：glob 展开顺序与字符串比较都不再受 locale 影响。
export LC_ALL=C

PASS=0
FAIL=0
FAILED=()

# 跑一条命令并采集其全部可观察输出。
#   cmd <名字> <argv...>
# argv 里的 @OUT@ 会被替换成该命令专属的临时目录（落盘类命令要用它）。
cmd() {
  local name="$1"
  shift

  if [[ -n "${TESTS_FILTER:-}" && "$name" != *"$TESTS_FILTER"* ]]; then
    return
  fi

  # 产出目录与"账本"目录分开，且账本**不在** $dir 之下：
  #   $dir    —— 命令写入的地方（dump 等），会被完整抄进 golden
  #   .cap    —— 本脚本自己的账本（stdout/stderr/golden/diff）
  # 分开是必须的：账本与产出同级时会被一并列出，于是 golden 里出现
  # `--- .diff ---`（上一次失败的 diff 残留）甚至"golden 抄自己"，
  # 表现为"第一次全绿、第二次开始成片失败"。
  # $dir 每轮都是新的（见 RUN 的说明），因此这里不需要 rm。
  local dir="$RUN/$name"
  local cap="$RUN/.cap/$name"
  mkdir -p "$dir" "$cap" || {
    echo "无法创建 $dir / $cap" >&2
    exit 1
  }

  local args=() a
  for a in "$@"; do
    a="${a//@OUT@/$dir}"
    a="${a//@SETUP@/$SETUP}"
    args+=("$a")
  done

  # 打印文件内容，并把机器相关的绝对路径换成占位符，使 golden 与仓库位置无关。
  # 刻意不用 `sed`：每条命令要跑 3~4 次，而 fork/exec 在 CI 里并不便宜
  # （本机实测原本 77 条命令要 60s，其中绝大部分是子进程开销）。
  # 代价：以 NUL 为分隔符读入，因此只适用于文本输出 —— xrep 的 stdout/stderr
  # 与 dump 文件都是文本，够用。
  emit_norm() {
    local content=""
    IFS= read -r -d '' content <"$1"
    content="${content//$dir/@OUT@}"
    content="${content//$SETUP/@SETUP@}"
    content="${content//$REPO/@REPO@}"
    printf '%s' "$content"
  }

  # `${args[@]+"${args[@]}"}` 这个看似多余的包裹是为了 macOS 自带的 bash 3.2：
  # 它把 `set -u` 下的空数组也当成未绑定变量（`meta-no-args` 这条就踩到了）。
  # cwd 在脚本开头就已切到仓库根，因此这里不需要再开子 shell 去 cd。
  "$BIN" ${args[@]+"${args[@]}"} >"$cap/stdout" 2>"$cap/stderr"
  local code=$?

  {
    # argv0 隐去：help/usage 文本里的程序名是硬编码的 "xrep"，与调用方式无关。
    printf '=== cmd ===\nxrep'
    for a in "$@"; do
      printf ' %s' "$a"
    done
    printf '\n'
    printf '=== exit ===\n%d\n' "$code"
    printf '=== stdout ===\n'
    emit_norm "$cap/stdout"
    printf '=== stderr ===\n'
    emit_norm "$cap/stderr"
    printf '=== files ===\n'
    # 用 glob 而不是 find + sed + sort：产出文件都在 $dir 顶层（不递归），
    # 而 LC_ALL=C 已保证 glob 展开顺序是字节序。
    local f
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      printf -- '--- %s ---\n' "${f##*/}"
      emit_norm "$f"
    done
  } >"$cap/golden"

  if [[ $UPDATE -eq 1 ]]; then
    mkdir -p "$GOLDEN"
    cp "$cap/golden" "$GOLDEN/$name.txt"
    printf '  UPDATE  %s\n' "$name"
    return
  fi

  if [[ ! -f "$GOLDEN/$name.txt" ]]; then
    FAIL=$((FAIL + 1))
    FAILED+=("$name (golden 缺失，先跑 --update)")
    printf '  MISSING %s\n' "$name"
    return
  fi

  if diff -u "$GOLDEN/$name.txt" "$cap/golden" >"$cap/diff"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
    printf '  FAIL    %s\n' "$name"
    sed 's/^/          /' "$cap/diff"
  fi
}

echo "==== tests/run.sh: 历史命令 golden 矩阵 ===="
echo "bin    = ${BIN}"
echo "out    = ${OUT}"
echo "golden = ${GOLDEN}"
echo

# ---------------------------------------------------------------------------
# 1) 基本命中与输出形态（传统偏移输出：逐字节兼容的契约面）
# ---------------------------------------------------------------------------
cmd basic-single        test tests/fixtures/a.txt
cmd basic-multi-file    test tests/fixtures/a.txt tests/fixtures/b.txt
cmd ignore-case         -i TEST tests/fixtures/a.txt
cmd ignore-case-long    --ignore-case TEST tests/fixtures/a.txt
cmd line-number         -n test tests/fixtures/a.txt
cmd only-matching       -o test tests/fixtures/a.txt
cmd count               -c test tests/fixtures/a.txt
cmd count-long          --count test tests/fixtures/a.txt
cmd max-count           -m 2 test tests/fixtures/a.txt
cmd quiet               -q test tests/fixtures/a.txt
cmd offset-hex          --offset-hex test tests/fixtures/a.txt
cmd limit               --limit 1 test tests/fixtures/a.txt
cmd context             --context 8 test tests/fixtures/a.txt
cmd after               --after 20 test tests/fixtures/a.txt
cmd before              --before 20 test tests/fixtures/a.txt
cmd after-before        --after 10 --before 30 test tests/fixtures/a.txt
cmd no-hit              zzz-nope tests/fixtures/a.txt

# ---------------------------------------------------------------------------
# 2) 线程（含 ADR 0002 的两个"夹取"边界：0 与超大值）
# ---------------------------------------------------------------------------
cmd threads-1           -t 1 test tests/fixtures/a.txt
cmd threads-4           -t 4 test tests/fixtures/a.txt
cmd threads-0           --threads 0 test tests/fixtures/a.txt
cmd threads-huge        --threads 100000 test tests/fixtures/a.txt
cmd threads-equals      --threads=8 test tests/fixtures/a.txt
cmd threads-attached    -t8 test tests/fixtures/a.txt

# ---------------------------------------------------------------------------
# 3) dump（--dump / --dump-prefix 清洗 / --skip-empty / --max-size）
# ---------------------------------------------------------------------------
cmd dump-plain          --dump @OUT@/d.txt test tests/fixtures/a.txt
cmd dump-hex            --dump @OUT@/d.txt --offset-hex test tests/fixtures/a.txt
cmd dump-quiet          --dump @OUT@/d.txt -q test tests/fixtures/a.txt
cmd dump-prefix         --dump-prefix @OUT@/pfx_ test tests/fixtures/a.txt
cmd dump-prefix-dot     --dump-prefix @OUT@/pfx_ test ./tests/fixtures/a.txt
cmd dump-prefix-nested  --dump-prefix @OUT@/pfx_ -r test tests/fixtures/dir
# 结构化输出（-n / --json）+ 多文件时的**逐文件** dump：每个输入文件一份
# `P{sanitized(path)}.txt`，0 命中的文件也照常产出空文件（除非 --skip-empty）。
# 这条把"输出模式与落盘互不干扰"钉住：换输出模式不该改变落盘的份数与内容。
cmd dump-prefix-walk-json -r --json --dump-prefix @OUT@/p_ test tests/fixtures/dir
cmd dump-skip-empty-0   --dump @OUT@/d.txt --skip-empty zzz-nope tests/fixtures/a.txt
cmd dump-skip-empty-1   --dump @OUT@/d.txt --skip-empty test tests/fixtures/a.txt
cmd dump-empty-default  --dump @OUT@/d.txt zzz-nope tests/fixtures/a.txt
cmd dump-multiple       --dump @OUT@/d.txt test tests/fixtures/a.txt tests/fixtures/b.txt
cmd dump-max-size-skip  --max-size 10 --dump @OUT@/d.txt test tests/fixtures/a.txt
cmd dump-max-size-ok    --max-size 1000 --dump @OUT@/d.txt test tests/fixtures/a.txt
cmd dump-missing-dir    --dump @OUT@/no-such-dir/d.txt test tests/fixtures/a.txt
cmd dump-empty-file     --dump @OUT@/d.txt test tests/fixtures/empty.bin

# ---------------------------------------------------------------------------
# 4) 多模式（-e 重复 / -f 文件 / 位置参数的重新分配）
# ---------------------------------------------------------------------------
cmd multi-e             -e test -e world tests/fixtures/a.txt
cmd multi-e-long        --pattern test --pattern world tests/fixtures/a.txt
cmd multi-f             -f tests/fixtures/pats.txt tests/fixtures/a.txt
cmd multi-f-missing     -f @OUT@/no-such-pats.txt tests/fixtures/a.txt
cmd multi-e-positional  -e test tests/fixtures/a.txt
cmd multi-mixed-case    -i -e TEST -e world tests/fixtures/a.txt

# ---------------------------------------------------------------------------
# 5) 目录遍历（-r / --hidden / --glob / --exclude，对齐 krep）
# ---------------------------------------------------------------------------
cmd walk-recursive      -r test tests/fixtures/dir
cmd walk-hidden         -r --hidden test tests/fixtures/dir
cmd walk-glob           -r --glob '*.txt' test tests/fixtures/dir
cmd walk-exclude-dir    -r --exclude sub test tests/fixtures/dir
cmd walk-exclude-glob   -r --exclude '*.bin' test tests/fixtures/dir
cmd walk-no-recursive   test tests/fixtures/dir
cmd walk-list-with      -r -l test tests/fixtures/dir
cmd walk-list-without   -r -L test tests/fixtures/dir
cmd walk-json           -r --json test tests/fixtures/dir
cmd walk-bundle-rn      -rn test tests/fixtures/dir

# ---------------------------------------------------------------------------
# 6) 输出开关（-l / -L / --json / --color）
# ---------------------------------------------------------------------------
cmd list-with           -l test tests/fixtures/a.txt
cmd list-without        -L test tests/fixtures/a.txt
cmd list-with-nomatch   -l zzz-nope tests/fixtures/a.txt
cmd list-without-nomatch -L zzz-nope tests/fixtures/a.txt
cmd json                --json test tests/fixtures/a.txt
cmd jsonl               --jsonl test tests/fixtures/a.txt
cmd json-count          --json --count test tests/fixtures/a.txt
cmd color-never         --color never test tests/fixtures/a.txt
cmd color-no-color      --no-color test tests/fixtures/a.txt
cmd color-auto          --color=auto test tests/fixtures/a.txt
cmd color-always        --color always --count test tests/fixtures/a.txt

# ---------------------------------------------------------------------------
# 7) 错误路径与元命令
# ---------------------------------------------------------------------------
cmd err-missing-file    test tests/fixtures/nope.bin
cmd err-bad-threads     --threads abc test tests/fixtures/a.txt
cmd err-bad-maxsize     --max-size abc test tests/fixtures/a.txt
cmd err-dump-conflict   --dump @OUT@/d.txt --dump-prefix @OUT@/p_ test tests/fixtures/a.txt
cmd err-unknown-flag    --no-such-flag test tests/fixtures/a.txt
cmd meta-help           --help
cmd meta-help-short     -h
cmd meta-version        --version
cmd meta-version-short  -v
cmd meta-selftest       --test
cmd meta-no-args

# ---------------------------------------------------------------------------
# 8) 分片重叠窗口的契约（README 已知行为#2）
#
# 每个任务向后多扫 CHUNK_OVERLAP(16) 字节以免切断跨分片匹配，代价是完全落在
# [分片边界, 分片边界+16) 的命中会被相邻两个任务**各报一次**（不去重）。
# 这两条把两个方向都钉住：跨界的只报一次，恰在边界的报两次。
#
# 为什么用 -c + --dump：多 worker 下逐条流式打印的先后顺序取决于调度，
# 只有"结论行"和"归并后的 dump"是与调度无关的。见文件头的例外说明。
# ---------------------------------------------------------------------------
cmd chunk-straddle-reported-once   -c --dump @OUT@/d.txt test @SETUP@/chunk_straddle.bin
cmd chunk-boundary-reported-twice  -c --dump @OUT@/d.txt test @SETUP@/chunk_dup.bin

echo
if [[ $UPDATE -eq 1 ]]; then
  echo "==== golden 已重新生成到 tests/golden/ （请在 commit 里逐条解释 diff）===="
  exit 0
fi

echo "==== run.sh: $((PASS + FAIL)) 条命令，PASS=$PASS FAIL=$FAIL ===="
if [[ $FAIL -eq 0 ]]; then
  exit 0
fi
printf '失败命令：\n'; printf '  - %s\n' "${FAILED[@]}"
exit 1
