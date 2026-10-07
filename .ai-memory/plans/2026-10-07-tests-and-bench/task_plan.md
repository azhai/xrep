# Task Plan: 补充 xrep 的测试与基准

## Goal
在不改动任何对外可观察行为的前提下，把单元测试从 105 例扩到 ~130 例（覆盖全部
未被测的纯函数、统计累加、`-m`/`-l`/`-L`/`--json` 编排路径、并发压力），
并把 `--bench` 从"3 个算法 × 1 个模式"扩成分组基准（模式长度 / 大小写 / 多模式 /
并行扫描线程伸缩性），全绿且 0 内存泄漏。

## Phases
- [x] 0. 读取全部生产代码 + 现有测试，列出覆盖缺口
- [x] 1. 补纯函数与编排层单测（common / scan / walk）
- [x] 2. 补算法与并发层测试（matcher 差分、task_pool、output_queue、worker）
- [x] 3. 扩充 bench.odin（分组 + 线程伸缩性）
- [x] 4. 扩充 selftest.odin 冒烟项
- [x] 5. 验证：./test.sh 全绿 0 泄漏 + ./xrep --bench 可运行；更新 README

## 覆盖缺口清单（Phase 0 结论）

| 缺口 | 位置 | 处理 |
| --- | --- | --- |
| `legacy_output` 纯判定无直接测试 | scan.odin:66 | 真值表用例 |
| `line_index_needed` 无直接测试 | scan.odin:73 | 真值表用例 |
| `Run_Stats` 累加（files/bytes/hits/skipped/matched）零覆盖 | scan.odin:150 | 新增统计用例 |
| `-m/--max-count` 截断 filtered 无覆盖（README 却声称已覆盖） | scan.odin:130 | 新增用例 + 修正 README |
| `path_label` 为空时回退 path 无覆盖 | scan.odin:88 | 断言落盘文件名 |
| `strip_dot_slash` / `join_path` / `walk_hidden` 无直接测试 | walk.odin | 新增纯函数用例 |
| `walk_dir` 不可读目录的错误路径 | walk.odin:187 | 新增用例（stderr，不崩） |
| `ctx_pattern_count` / `ctx_pattern_at` 无直接测试 | common.odin:72 | 新增用例 |
| matcher 无参考实现差分（随机数据交叉验证） | matcher.odin | 新增确定性 PRNG 差分用例 |
| `task_pool` 多线程并发弹出无覆盖 | task_pool.odin | 4 线程 × N 任务，恰好一次 |
| `output_queue` 多生产者压力无覆盖 | output_queue.odin | 4 生产者 × 500 条，总数校验 |
| `output_thread` 的 `-m` 计数与 pat_len 回退只被间接覆盖 | worker.odin:112 | 新增 worker_test.odin |
| `--bench` 只有 3 算法 × 单模式 | bench.odin | 分组基准 + 线程伸缩性 |

## 结果（2026-10-07）

- 用例数 **105 → 129**（新增 24），全部通过、0 leak、0 bad free；
  并行与串行（`ODIN_TEST_THREADS=1`）两种执行方式均全绿。
- `--bench` 从"3 算法 × 1 模式 × 100 MiB"扩成 **A 组 10 个 case**（长度分档 1/2/4/16/17/64/128B
  + `-i` + 2/4 模式）+ **B 组 1/2/4/8 线程伸缩**（走完整 `scan_region_parallel` 路径），
  总耗时约 7s，取每档"最快一轮"作为代表值。
- 内建自检 `--test` 从 6 项扩到 11 项。
- README 的测试表、基线数字、bench 说明与测试噪声清单已同步。
- **未改动任何对外可观察行为**：唯一的生产代码改动是 `bench.odin`（基准自身的输出）。

## Open questions
- 无需用户裁决的点：全部为"只加测试与基准、不改生产行为"。
- 遗留（已记录，未处理）：`output_queue_pop` 的出队是 O(队列长度) 整体左移，
  密集命中场景下可能退化。基准用稀疏数据规避，代码未动。

## Resume point
已完成 Phase 0–5。若重置：从 Phase 5 的验证步骤继续。