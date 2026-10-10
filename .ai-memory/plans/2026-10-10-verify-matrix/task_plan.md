# Task Plan: 把外部命令矩阵落进仓库

## Goal
README 里那三套"对外可观察行为"的命令矩阵原本只存在于 `/tmp/xrep_verify/`
（该目录已被清理，脚本不可恢复），现把它们重建为**仓库内的 `tests/` 目录**，
并用一条 `./verify.sh` 跑完，使"输出文本的验收"不再依赖任何人手上的临时目录。

## 约束（决定设计的关键事实）
1. `/tmp/xrep_verify/` 已不存在 → 从 README + ADR 0002/0005 的验证章节**重建**，
   不追求与原文逐字一致，只要求覆盖同一批行为面。
2. golden 基线只能以**当前 HEAD 的行为**为准（重构早已合入，"改动前的 HEAD"
   已无从取得）→ 这是 characterization test：golden 记录现状，有意为之的行为
   变更需 `--update` 重新生成并在 commit 里逐条解释 diff。
3. `odin test` 并行跑用例 → stdout 不可捕获，**输出文本只能靠外部进程矩阵**验收，
   这正是本任务存在的理由。
4. 输出必须**跨机器可复现**：全部用相对路径（cwd = 仓库根）、禁用 `--stats`
   进 golden（`%.2f ms` 是计时值）、fixture 小于 2 MiB（单分片 → 单 worker
   产出 → 打印顺序确定；且 <200ms 不触发进度条渲染）。

## Phases
- [x] 0. 确认 /tmp 脚本已丢失，从 README/ADR 重建覆盖清单
- [x] 1. `tests/fixtures/`（文本 + 空文件 + 目录树 + 模式文件）
- [x] 2. `tests/run.sh`：历史命令 golden 矩阵（stdout/stderr/退出码/产出文件）
- [x] 3. `tests/lib.sh` + `tests/run2.sh`：ADR 0002 行为断言
- [x] 4. `tests/run3.sh`：krep 对齐功能断言
- [x] 5. `verify.sh`：build → 单元自检 → 三套矩阵，一条命令
- [x] 6. 跑通（含"连跑两次 diff 为空"的确定性校验）+ 更新 README

## Open questions
- 无：全部为"把验收资产搬进仓库"，不改生产行为。

## Resume point
若上下文重置：从 Phase 6 的验证步骤继续（`./verify.sh`）。