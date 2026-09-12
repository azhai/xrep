# task_plan — 可选修复项 + 新增 flag（2026-09-12）

来源：用户给出的「现有代码可优化清单」，要求"不改动 --dump-prefix / --quiet 功能，完全兼容"，
并给出推荐优先级 5 项。

## 阶段 0：核实前提（先做，避免按错误前提动手）✅

- [x] 核实无 mmap → 清单性能#1 不适用
- [x] 核实无 SIMD → 清单性能#4 不适用
- [x] 实测 `--limit N` 对 dump/count 无影响（只影响 pretty 汇总行）
- [x] 实测 `--dump-prefix` 相对路径必然失败（`out_./sample.bin.txt` → Not_Exist）
- [x] 实测 `--threads 0` = 静默 0 命中；`--threads 100000` = 挂死（16s 超时）
- [x] 实测 dump 落盘失败时退出码仍为 0

## 阶段 1：向用户确认契约项（清单与"完全兼容"自相矛盾）✅

- [x] `--dump-prefix` → **直接清洗**（接受行为变更）
- [x] `--limit` drop-2 → **保持现状**（保留契约，改为加测试钉死）
- [x] 范围 → 推荐 5 项 + 易用性

## 阶段 2：实现 ✅

- [x] `sanitize_dump_name` 文件名清洗（`io_utils.odin`）
- [x] `clamp_thread_count` + `max_threads_for_machine`（`common.odin` / `cli.odin` / `main.odin`）
- [x] 空文件快速跳过（`scan.odin`）
- [x] dump 失败 → 非零退出码（`scan_file` 返回 `dump_ok`，`main` 决定 exit）
- [x] `--skip-empty` / `--dump-append` / `--max-size N` / `-v|--version`
- [x] 多文件汇总统计行
- [x] 硬编码常量抽取到 `common.odin`
- [x] `scan_file` 改收 `Scan_Options` 结构体（避免参数膨胀）

## 阶段 3：测试 ✅

- [x] `io_utils_test`：sanitize（绝对/相对/Windows 保留字符/UTF-8/空串）、`file_size_of`、dump 追加
- [x] `cli_test`：新 flag 解析、`--max-size` 错误分支、`--version` 即时性、线程数不在解析层夹取
- [x] `common_test`：`clamp_thread_count` 边界、常量不变量
- [x] `scan_test`：dump-prefix 清洗、相对路径回归、`--dump-append`、`--skip-empty`、`--max-size`、
      空文件快速跳过、落盘失败上报、线程数 0 的新语义
- [x] 77/77 通过 + 内建自检全绿

## 阶段 4：验证 ✅

- [x] 原 47 条矩阵 vs 改动前：差异仅 5 个 help 文本文件（预期）
- [x] 新增 27 条断言矩阵全通过
- [x] `odin check .` 无告警 + `./build.sh` exit 0

## 阶段 5：文档 ✅

- [x] README：新 flag 表、退出码、汇总行、契约/变更分类、defer 警示、测试表 77
- [x] ADR 0002
- [x] MEMORY.md 契约清单更新 + 技能 `odin-test-and-refactor` 增补
