# 调查发现 — 测试崩溃与泄漏（2026-09-12）

## 现象数据
| 实验 | 结果 |
| --- | --- |
| `./test.sh`（内部关追踪） | exit 0，77/77 |
| 裸 `odin test .`（默认 10 线程 + 追踪开启）×5 | 4 次 exit 138（SIGBUS） |
| 裸跑、`ODIN_TEST_THREADS=1` ×5 | 5/5 通过 |
| 各组测试按名隔离（slice / output_queue / scan） | 全通过 |

→ 崩溃与**runner 线程数**和**追踪器**同时相关，与单个用例无关。

## 根因
- `core/mem/tracking_allocator.odin`：`Tracking_Allocator` 内部为
  `allocation_map: map[rawptr]Tracking_Allocator_Entry`，**无锁** → 非线程安全。
- `core/thread/thread.odin`：创建线程会复制创建者的 `context`（含 `allocator`）。
- 两者相乘：runner 多线程并发 + 用例内 worker 线程继承追踪分配器 → 并发写同一 map。

## 顺带发现的真实缺陷
1. `matcher.odin:20/42` 写 `context.allocator = mem.arena_allocator(arena)`：永久劫持。
   独立探针确认 `make` 之后的目标地址落在 `arena.data` 范围内。
   → `worker_steal` 的 `stable`（注释说"拷贝到堆"）实际在 arena；
   `output_queue_push` 的 `append` 同理，可能把共享队列底层数组迁进 arena。
2. `merge.odin` 的 `ptrs` / `non_empty` 从不释放 → 生产代码泄漏。
3. 测试侧：`merge_test` 未释放归并结果；`slice_utils_test` 未释放 map/filter 结果；
   `scan_test` 用 `os.stat(path, context.allocator)` 只判存在性（会 clone 路径 + 需
   `file_info_delete`，leak 报在 `strings.clone_to_cstring`）。
4. 另一个"机制性"问题：全局表依赖 `main` 初始化，而 `odin test` 不执行 `main`，
   于是每个用例都得自己补（13 处），漏掉会让大小写不敏感匹配把全部字节视为相等。

## 已排除的可能
- 不是某个测试用例自身写坏内存（各组隔离均通过）。
- 不是泄漏导致的崩溃（崩溃发生在 runner 报告阶段，且串行时无崩溃）。
- 不是 arena 复用覆盖导致的 dump 内容错误：用 dense/asym 两个高命中构造验证，
  dump 行数与偏移完全正确（含契约内的 4 处边界重复）。
