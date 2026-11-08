# progress.md — 按模式/操作优化（ADR 0008）

## 基线（优化前，`./xrep --bench` + 8 MiB 稠密输入）

| 指标 | 值 |
| --- | --- |
| 1B / 4B / 16B | 1844 / 1286 / 1200 MB/s |
| 17B / 64B / 128B | 1190 / 1039 / 880 MB/s |
| 4B -i | 1207 MB/s |
| 多模式 2 / 4 | 442 / 226 MB/s |
| 端到端 1 / 8 线程 | 1292 / 7142 MB/s |
| 打印 1M 行 | 8.20 s |
| dump 1M 条 | 1.17 s |
| `--count` 1M 命中 | 0.39 s（`-m` 强制走队列测得） |

## 实施（每步都跑 test.sh；末尾跑 verify.sh）

| 步骤 | 改动 | 结果 |
| --- | --- | --- |
| P1 | matcher：SIMD 预筛（`alt_case`/`find_byte`/`match_rest`）、`single_match` 两段式、新增 `memchr_match`、`bndm_match` 改委托、alg_table 17..4096 → memchr | 编译通过；bench 各项 4～27× |
| P1b | `bench.odin` 的 `alg_name` 加 `memchr_match`（否则打印 "?"） | OK |
| P1c | `test_select_matcher_boundaries` 断言更新（17/64/4096 → memchr；4097 → naive） | 24 用例仍全绿 |
| P2 | `multi_match` 首字节 256 位图 | 2.7× / 4.5× |
| P3 | `Output_Queue` 环形缓冲 | A/B：打印 1M 行 8.20 s → 0.75 s |
| P4 | silent 且无 `-m` → `worker_data.no_stream` 不入队 | `--count` 1M：0.39 → 0.026 s |
| P5 | 打印/dump 攒批（64 KiB）+ `build_line_index` SIMD 一次遍历 | 打印 0.75 → 0.38 s；dump 1.17 → 0.063 s |

## A/B 方法（可复用）

P3 的收益是**临时把 pop 改回左移实现重编译**测出来的（8.196s vs 0.751s），
不是估算。改回前先 `cp lib/output_queue.odin /tmp/*.bak`。

## 验证

- `./test.sh`：129 用例全绿、0 leak。
- `./verify.sh`：护栏 28 项 + golden 78 + run2 34 + run3 56 全绿，
  **输出文本与优化前逐字节一致**。
- dump 产物 `cmp` 与优化前一致；打印行数一致。
- 工具幂等：`qualify` 无需改动、`check-literals` 无污染、`make deps` 方向正确。

## 文档

README（bench 数字、契约 #4、文件表三处）、新增 ADR 0008、
`.workbuddy/memory/2026-10-24.md`、MEMORY.md 新增「性能分档」约定段。
