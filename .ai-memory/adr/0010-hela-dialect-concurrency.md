# ADR 0010 — 并发骨架迁移 Hela 方言与 core:hela 无锁标准库

日期：2026-11-07　分支：`hela`　状态：已实施

## 背景

xrep 的并发骨架是 2026-09 形态：`Task_Pool`（Mutex + LIFO 动态数组）、`Output_Queue`
（Mutex + Cond + 手写环形缓冲）、`Progress`（Mutex）、`list_mu` / `hit_mu` 两把汇总锁。
Hela（`/opt/repos/hela`，Odin fork）提供了一组用布局契约约束的无锁容器
（`core:hela/queue` 等）与编译器验证的并发声明（`#+dialect hela` / `#explicit` /
`#atomic` / `#share` / `#+analysis sharing`）。

本 ADR 记录把并发骨架换血、行为不变（golden 逐字节一致）的迁移。

## 决定

1. **文件级方言**：只有改动到的文件加 `#+dialect hela`（search/ 算法层不动）。
   Hela 的方言判定在定义处文件，未标注文件照常编译——迁移可以逐文件推进。
2. **Task_Pool → `core:hela/queue.Queue(Scan_Task)`**：无锁 Vyukov MPMC 替代
   Mutex+LIFO。顺序 LIFO→FIFO 是**有意变更**（对正确性无影响，跨分片顺序由
   merge 恢复）；容量改为启动时按分片数向上取 2 的幂（`pool_capacity_for`），
   push 的返回值被调用方 fail-fast 检查。
3. **Output_Queue → `queue.Queue(Output_Item)` + `#atomic #share(controller) done`**：
   删除 Mutex/Cond/手写环形缓冲。消费者从 cond_wait 改为空转自旋（打印远慢于扫描，
   队列鲜少长期为空；批次有限，最坏多烧一个核）。队列**有界**（4096 槽）：满时
   push 自旋重试 = 反压，替代旧版的无界扩容（稠密命中下旧版会堆积数百 MB）。
4. **Progress 无锁化**：`scanned` 用 `atomic_add`（`#share(workers)`）；渲染权用
   `last_render_ns` 的 CAS 抢占（`#share(renderer)`）——并发下恰有一个线程渲染，
   无撕裂。两行各自独占 cache line，由 `--contract` 显示、`0 conflicts` 断言。
5. **汇总锁全删**：命中列表改每 worker **独占** dynamic 数组（一个 worker 可能抢到
   多个任务，逐任务 append 自己的数组；归并时摊平）；`hit_mu` 被证明只保护一个
   单线程读写的计数——计数改本地累加、退出前写回。
6. **热数据结构逐字节声明**：`Match_Result` / `Output_Item` / `Scan_Task` →
   `struct #explicit`（16 B，padding 显式命名）；布局清单（`-emit-layout`）+
   `hela-layout --contract` 成为回归门禁。

## 结果

- 行为：140 单测 + 78 golden + run2 34 + run3 56 + 内建自检全部通过；
  838 万条稠密命中的 dump 输出与旧版**逐字节一致**。
- 性能（64 MiB、每 8 B 一命中、838 万条流式输出）：旧版 ~3.26 s → 新版 ~1.66 s
  （**1.97x**）。稀疏命中（1 hit/64 KiB）与 `-c` 计数模式持平（瓶颈在 SIMD 扫描，
  队列不在热路径）。
- 并发：TSAN 下 lib/engine/app 三个包全绿，无 data race。
- 布局门禁：`--contract` 报 `0 line(s) with conflicting writers`；`done` 行
  owner=controller，`scanned`/`last_render_ns` 行 owner=workers/renderer。

## 回流

- `core:time` 增加 `tick_nanoseconds(Tick) -> i64`：重构需要单调纳秒读数喂给
  `#atomic u64` 字段，此前只能摸 `Tick._nsec` 私有字段或 transmute。

## 后备（未做，记录在案）

- `#+analysis sharing` 仍是单 struct 内的检查：`worker_data` 持有多个共享结构的
  指针（out_q / tp / progress），跨类型的行归属是盲区。这正是 Hela 侧
  「`#share` 跨类型分析」候选的实证案例。
- 稠密 `-c` 模式（no_stream）下新版略慢 ~6%（LIFO→FIFO 的局部性差异），
  在噪声边缘；流式路径的 2x 收益远大于此。
