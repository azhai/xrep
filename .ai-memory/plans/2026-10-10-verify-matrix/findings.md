# Findings

## 2026-10-10 — /tmp 里的三套脚本已不可恢复
- Learned: `/tmp/xrep_verify/` 不存在（临时目录已被清理），README 仍引用它。
- Source: `ls /tmp/xrep_verify` → No such file or directory
- Implication: 只能从 README「行为验收矩阵」表 + ADR 0002/0005 的「验证」章节
  重建覆盖清单；不追求逐字复原，只要求覆盖同一批行为面。

## 2026-10-10 — golden 基线只能以当前 HEAD 为准
- Learned: ADR 0002/0005 的 `run.sh` 是与"重构前的 HEAD 产物"做 `diff -r`；
  重构早已合入，那个基线已不存在。
- Implication: 仓库内的 golden 是 **characterization test**（记录现状），
  不是"重构前后等价"的证明。纪律改为：等价重构 → diff 必须为空；
  有意改行为 → `--update` 重新生成 + commit 里逐条解释 diff。

## 2026-10-10 — 输出可复现性的三个前提
- Learned（读源码）：
  1. `print_help` / `print_version` 里的程序名是**硬编码** "xrep"，
     不含 `os.args[0]` → 不论怎么调用二进制，帮助文本都稳定。
     Source: cli.odin:509-568
  2. `--stats` 打印 `%.2f ms`（计时值）→ **不能**进 golden，只能做字段级断言。
     Source: main.odin:149-160
  3. 进度条在 `now - last_render >= PROGRESS_MIN_INTERVAL(200ms)` 时才渲染，
     `last_render` 初值为启动时刻 → 短任务从不渲染。
     Source: progress.odin
- Implication: fixture 全部 < 2 MiB（单分片 → 单 worker 产出 → 打印顺序确定；
  且耗时远低于 200ms → 无进度条输出）。`--stats` 只在 run3.sh 用正则断言。

## 2026-10-10 — 输出文本的确切形态（写断言用）
- Source: scan.odin:190-200, 175-188, 159-173
- 传统模式：`\n=== {label}: {N} results ===\n`，随后是 `--- summary ---`
  或 `--- summary (first N) ---` + `  [%d] match offset: %s`；
  且**先丢弃前 2 条命中**（`slice_drop(filtered, 2)`，README 已知行为#3）。
- `--count`：`{label}: {N} hits`；`--count --json`：`{"file":"..","count":N}`
- `-l` / `-L`：只打印 label（json 时打印对象）
- `--max-size` 跳过：stdout 无输出，stderr `skip {path}: size {n} exceeds --max-size {n}`
- 文件缺失：stderr `open {path} failed: {err}`

## 2026-10-10 — 顺带发现并修复的生产缺陷
- Learned: `scan.odin:260` 写的是 `progress_init(&prog, u64(file_size), true, progress_on)`，
  而形参顺序是 `(p, total_bytes, use_color, enabled)` —— `use_color` 被写死成 `true`。
- Source: progress.odin:29 / scan.odin:260
- Status: **已修**（传 `o.use_color`），并加了"两个 bool 别写反"的注释。
- 验证：默认/`always` 4 行 ANSI，`never`/`no-color`/`auto` 0 行；
  golden 只有 3 条命令变化（`color-never`/`color-no-color`/`color-auto`），各一行。
- 沉淀：`tests/run3.sh` 的颜色段现在断言**整段 stdout 有无 ANSI**（不再只看
  `context hex` 那一行）。教训是 —— golden 只报"变了"，断言才报"错了"，
  两者互补才能把这类"声明支持但实际绕过"的缺陷按住。
- 附带确认：全仓库只有这一处调用点写错实参顺序，其余 13 处（测试/bench/自检）
  都与形参一致。形参相邻的 bool（`use_color` / `enabled`）是典型的"沉默错误"来源，
  注释里点名比事后 debug 便宜。

## 2026-10-10 — 本环境的两个沙箱特性（会伪装成脚本 bug）
- Learned: 本环境**拦截并审计 `rm`**，单次 `rm -rf` 约 0.5s CPU；且对"单轮批量删除"
  有上限（实测 500 个文件，超出时 `rm` 直接失败）。
- Implication: 测试脚本要**按轮整体删一次**（`trap 'rm -rf "$RUN"' EXIT` + 每轮一棵
  新树），不要"每条命令跑完就 rm"。否则：慢一个数量级（57s → 1.9s 的差距），
  并且第二次运行会成片失败（表现为 golden 大面积不匹配，极易误判成逻辑错误）。
  本机数据：77 条命令 × (1 rm + 1 mkdir + 3 find/sed/sort) → 57s；
  改为 1 次 rm + glob/内建替换 → 1.85s。
- Learned: `fork/exec` 在本环境也不便宜（约 50ms/次）。能用 bash 内建替代的
  （glob 替代 find、`${var//pat/repl}` 替代 sed、`read -d ''` 读文件）就替代。
- 判断依据：二分计时（按 `TESTS_FILTER` 分组 → 单条命令 → 只造大文件），
  不要凭直觉改。

## Errors logged
- 详见 progress.md「尝试与失败记录」（账本文件污染 golden 导致"第二次起成片失败"、
  bash 3.2 空数组 + set -u、file_eq 参数顺序、-c 的进度条前缀、max-size 无声语义、
  两处期望值算错）。