# Task Plan: 拆分 main.odin 为模块化结构 + 单元测试 + 中文注释 + README

## Goal
main.odin（966 行）按职责拆分为多文件模块，二进制行为与拆分前**逐字节一致**；
核心模块配套 `*_test.odin` 单元测试；关键逻辑补中文注释；README 反映新结构。

## Phases
- [x] 0. 基线固化 — 构建成功；47 条命令的行为矩阵存于 `/tmp/xrep_verify/base`（stdout/stderr/exit code 三份）
- [x] 1. 模块划分 — 15 个生产文件 + 11 个测试文件；符号零改动（仅移动），新增中文注释
- [x] 2. 行为等价验证 — `run.sh` 对照 base/new，全部 47 用例零差异（拆分后、加测试后各验一次）
- [x] 3. 单元测试 — 11 个 `*_test.odin`，59 用例；`./test.sh` 全绿；三组按名隔离运行通过
- [x] 4. 内建 `--test` 与 `--bench` 冒烟 — 输出与基线一致
- [x] 5. README 同步 — 文件结构 / 模块职责 / 测试运行方式 / 已知行为
- [x] 6. Verify — `./build.sh` + `odin check .` + `./test.sh` + `diff -r base new` 全部通过

## 模块划分（职责单一，依赖单向）
| 文件 | 职责 |
| --- | --- |
| `main.odin` | 仅入口编排：init → 解析 → 子命令分派 → 扫描 → 退出 |
| `cli.odin` | `Options` / `Parse_Outcome` / `parse_args` / `print_help` |
| `common.odin` | 全局常量、共享类型、arena 生命周期、`s2b`、lower 表 |
| `slice_utils.odin` | map/fold/filter/take/drop/sort |
| `matcher.odin` | single/naive/bndm + 算法选择表 |
| `merge.odin` | 多路有序归并 |
| `task_pool.odin` / `arena_pool.odin` / `output_queue.odin` / `progress.odin` | 并发基础设施 |
| `worker.odin` | worker 与输出线程 |
| `io_utils.odin` | 文件读取、上下文打印、dump 写出 |
| `scan.odin` | 单文件扫描编排（线程/任务/过滤/输出） |
| `selftest.odin` / `bench.odin` | 内建 `--test` / `--bench` |

## Open questions
- `--no-color` 是 no-op（颜色恒为 true）→ 保持原样，仅加注释，不改行为。
- `scan_file` 中 `slice_drop(filtered, 2)` 丢弃前 2 条仅影响 pretty 输出，dump/count 不受影响 → 属既有行为，保留并注释。
- 分片重叠窗口（边界 +16 字节）内的命中会被重复上报 → 实测基线与新二进制一致，属既有行为，写入 README「已知行为」。
- `/tmp` 探针结论：`odin test` 与 `odin build` 同样需要 `ODIN_CC=/usr/bin/clang` + `-linker:lld` → 已加 `test.sh`。
- 测试运行器内存追踪与 worker 线程并发分配不兼容（偶发 SIGBUS）→ `test.sh` 内置 `ODIN_TEST_TRACK_MEMORY=false`，理由见 ADR 0001。

## Resume point
全部阶段完成。如需继续：`cd /opt/repos/xrep && ./test.sh`；
行为等价性复核：`cd /tmp/xrep_verify && ./run.sh /opt/repos/xrep/xrep new && diff -r base new`。
