# Findings

## 2026-09-12 — Odin 工具链事实
- Learned: 本机 `odin` 为 `dev-2026-09`（`/opt/homebrew/bin/odin`）。
- Learned: `odin build .` **会**编译 `*_test.odin`（本版本不按测试后缀排除），
  因此测试文件必须能通过普通构建；`@(test)` 不执行，无副作用。
- Learned: `odin test .` 同样走 clang 链接，必须 `ODIN_CC=/usr/bin/clang` + `-linker:lld`，
  否则报 `unknown file type *.o`（与 build.sh 注释记录的 NDK clang 抢占问题同源）。
- Learned: `odin test` 不执行 `main`，凡在 `main()` 里初始化的全局（`lower_table`、`alg_table`）
  在测试中为空 → 测试必须自行 `init_lower_table()` / `init_alg_table()`。
- Learned: proc 值支持 `==` / `!=`；`[]u8`→`string` 不能隐式或显式转换，需 `transmute`。
- Source: `/tmp/odin_probe` 探针工程。
- Implication: 需要独立 `test.sh` 固化编译参数；测试切勿依赖 main 初始化。

## 2026-09-12 — 既有实现中的"可疑但必须保留"的行为
- `scan_file`: `filtered` 用于 dump/count，但 pretty 输出用 `slice_drop(filtered, 2)` 丢掉前 2 条 → 保留，加注释。
- `cli`: `--no-color` 接受但不改变任何行为（`use_color` 恒真）→ 保留，加注释。
- `matcher`: `bndm_match` 实际直接委托 `naive_match`（无位并行实现）→ 保留，加注释。
- `progress_add`: `enabled=false` 时**连 `scanned` 都不累加**（提前 return）→ 保留，测试按此断言。
- Implication: 本次任务目标是"降低耦合"，不是修 bug；任何行为修正都会破坏等价性证明。

## 2026-09-12 — 可测试性缝隙（Capability Seam）
- `parse_args` 原实现内嵌 `os.exit`，无法单测错误分支 → 改为返回
  `(Options, Parse_Outcome, message)`，退出策略留在 `main`；`--help` 的"即时退出"语义
  用 `.Help` 三态保持（`--threads abc --help` 仍退出 1）。
- `print_context` 的窗口夹取算 �� → 抽出纯函数 `context_range(file_len, offset, pat_len, ctx)`，
  hex 渲染逻辑不变；边界算术因此可单测。
- Source: AGENTS.md §3（capability seam）、§4（verify）。
