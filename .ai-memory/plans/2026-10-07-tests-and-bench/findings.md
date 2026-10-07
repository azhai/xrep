# Findings

## 2026-10-07 — xrep 覆盖缺口盘点（Phase 0）
- Learned: 基线 `./test.sh` → 105 用例全绿、0 leak、2.1s（`odin test` 部分 110ms）。
- Source: `/tmp/xrep_baseline.log`
- Implication: 有充足的时间预算给"较重"的测试（几 MiB 缓冲、并发压力），
  只要单个用例控制在百毫秒级。

- Learned: README「测试代码」表格声称 `scan_test.odin` 覆盖 `-l/-L/-m/--json`，
  但该文件 14 个用例里没有任何一个设置 `max_count` / `list_mode` / `json`。
  文档与代码不一致。
- Source: README.md:145 vs scan_test.odin 全文
- Implication: 本轮补上这些用例后文档才成立；若不补，必须改 README。

- Learned: `scan_region_parallel` 在 `quiet=true` 时 `legacy_output(o)` 为 false →
  进度条关闭、输出线程 `silent=true`，因此可以在基准里无噪声地跑。
- Source: scan.odin:258 / scan.odin:278
- Implication: `--bench` 可以直接调 `scan_region_parallel` 测线程伸缩性，stdout 干净。

- Learned: `worker_steal` / `output_thread` 的线程入口都做了
  `context = runtime.default_context()`，命中数组由 matcher 在堆上分配。
- Source: worker.odin:49 / worker.odin:114 / common.odin:99
- Implication: 新写的 `worker_test.odin` 直接起线程是安全的；被测返回值必须
  `delete(x, runtime.default_context().allocator)` 才不会 `bad free`。

- Learned: 输出线程的可观测出口是 `output_data.out_hits`（受 `hit_mu` 保护），
  打印本身不可捕获。
- Source: worker.odin:100-102, 122-127
- Implication: `-m` 计数语义用 `silent=true` + 断言 `out_hits` 测，不依赖 stdout。

- Learned: Odin `defer` 是块作用域（README 已记录）。
- Implication: 测试里凡"函数末尾才释放"的资源，`defer` 必须写在函数体顶层；
  `if err == nil { defer delete(data) }` 这种写法是安全的（delete 只是丢指针），
  但 `defer os.remove(path)` 放在 `if` 里会立刻删文件 —— 不要这么写。

## Errors logged
- 详见 `progress.md` 的「尝试与失败记录」（defer 块作用域导致的 use-after-free、
  worker 列表的 bad free、三处期望值写错、Odin fmt 数字宽度补 0）。

## 2026-10-07 — 测试范围的刻意边界
- Learned: `odin test` **默认并行**跑用例，而输出层写的是**进程级 stdout**。
- Implication: 任何"捕获 fd 1 再断言输出文本"的测试都会与并行跑的其它用例互相
  污染，属于用不可靠的断言换覆盖面。故单测只断言返回值 / 落盘内容 / 统计累加 /
  队列与偏移；输出文本交给 README「行为验收矩阵」的外部命令矩阵。
  已写进 README 与 `scan_test.odin` 文件头，别再重复这个讨论。

## 2026-10-07 — bench 的口径选择
- Learned: `output_queue_pop` 的出队是"O(队列长度) 整体左移"。
- Implication: B 组（线程伸缩）刻意用稀疏数据（每 64 KiB 一处命中），
  否则密集命中会让出队的 O(n²) 主导吞吐、掩盖线程伸缩本身。
  密集命中下的队列行为是**另一个尚未处理的话题**，本次未改生产代码。
- Learned: `fmt` 对**数字**宽度的默认填充是 `'0'` 而非空格（`%9.2f` → `001355.42`）；
  右对齐要用空格标志 `% 9.2f`（' ' 紧跟 `%`）。