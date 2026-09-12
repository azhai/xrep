# ADR 0004 — 命中结果改用堆分配，移除 Arena_Pool

- 状态：已接受（Accepted）
- 日期：2026-09-12
- 关联：ADR 0003（线程上下文与分配器卫生）、ADR 0001（模块拆分与能力缝隙）、
  README「并发与内存约定」「已知行为与限制」

## 背景

本轮目标是对齐 krep 的功能（目录遍历 `-r`、`-l/-L`、`-n`、`-o`、`-m`、`-e/-f`、
`--json`、`--stats`、`--color` 等）。为支持 `-o`（打印命中字节）与多模式
（`-e a -e b` 命中不同长度的模式），`Match_Result` 增加了一个字段：

```odin
Match_Result :: struct {
    offset:  u64,
    pat_len: u32,   // 本轮新增
}
```

结构体因此从 **8 字节变为 16 字节**（`u64` 对齐把 12 字节撑到 16）。

这本身是必要且无害的改动，但它把此前一直存在的一个**隐蔽缺陷**从"只在极端输入下
触发"推到了"普通输入就能触发"。

### 缺陷本体：定长 arena + 动态数组扩容 = 静默丢命中

`matcher` 的命中数组一直由**定长 arena**（`Arena_Pool`，块大小 `ARENA_BLOCK_SIZE`
= 16 MiB）承载：

```odin
results := make([dynamic]Match_Result, 0, 64, mem.arena_allocator(arena))
```

Odin 的 `[dynamic]` 扩容是**按 2 倍**做的，而一次扩容需要"旧缓冲 + 新缓冲"
**同时在场**（arena 从不回收旧块，`arena_free_all` 只在归还时把 `offset` 置 0）。
于是峰值占用 ≈ **最终容量的 2 倍**。一旦峰值超过 16 MiB，底层分配失败 ——
而 Odin 的 `append` 在分配失败时**不 panic、不报错、不回滚**，只是不再增长。

表现出来就是：**扫描照常完成、进程正常退出、退出码 0、命中却被悄悄丢弃。**

### 证据（本轮实测）

| 输入 | HEAD（16 B 结构，16 MiB arena） | 期望值 | 结论 |
| --- | --- | --- | --- |
| `dense.bin`（2.5 MiB，`test` 每 4 字节） | 655364 | 655360 唯一 + 4 条分片重叠重复 | 丢 4 条（正好是重叠窗口） |
| `all_a.bin`（2.5 MiB 全 `a`，模式 `a`） | **1572864** | 2621440 唯一 + 16 条重叠重复 | **丢 40%** |

`all_a.bin` 这一行说明缺陷**并非本轮引入**：把 `ARENA_BLOCK_SIZE` 临时放大到
128 MiB 后，两个二进制都给出 655364 / 2621456 的（正确）结果，HEAD 的 1572864
纯粹是容量上限造成的截断。本轮之所以显形，只是因为结构体变大、临界点前移。

### 附带发现的泄漏

`worker_steal` 原本把命中"深拷贝到堆"再挂进汇总列表：

```odin
stable := make([]Match_Result, len(matches))   // 堆
copy(stable, matches)
append(w.out_list, stable)
```

而 `scan_region_parallel` 只 `delete(match_lists)`（外层 dynamic 数组），
**内层切片从未被释放** —— 每分片泄漏一次，且**不可见于 `odin test` 的泄漏统计**：
worker 用的是归一化后的进程默认堆分配器（ADR 0003），不是测试的
`Tracking_Allocator`，所以这些分配根本没被记录。

## 决策

**命中结果不再由 arena 承载，改为用调用时的 `context.allocator` 分配；所有权交给
调用方；`Arena_Pool` 与 arena 辅助函数整体移除。**

```odin
// matcher.odin
Match_Fn :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result
results := make([dynamic]Match_Result, 0, MATCH_INITIAL_CAP)   // 无容量上限
```

worker 直接接手该切片（不再深拷贝），`scan_region_parallel` 在归并后统一释放：

```odin
// scan.odin — 归并读内容，不接管所有权，故必须在这里释放
for lst in match_lists {
    if lst != nil {
        delete(lst, runtime.default_context().allocator)
    }
}
```

### 为什么是堆，而不是"把 arena 调大"

arena 是**定长**的，而命中数是输入的函数、**没有上界**。按最坏情况估算需要
`2 × 2 MiB × 16 B = 64 MiB` 块（单模式），多模式还要再乘模式数。
调大只是把临界点往后推，缺陷依旧存在，且每 worker 常驻数十 MiB。
结论：**arena 这种"批量释放、定长"的分配器在语义上就不适合承载无界结果集。**

### 分配器一致性契约（容易踩，务必遵守）

数组用**调用时的** `context.allocator` 分配。worker 入口会
`context = runtime.default_context()`（ADR 0003），因此 worker 分配的是
"进程默认堆"内存。**跨线程释放时必须显式传入同一分配器**：

```odin
delete(slice, runtime.default_context().allocator)
```

否则在 `odin test` 下，main 线程的 `context.allocator` 是 `Tracking_Allocator`，
用它去 free 一个堆指针会直接报 `+++ bad free`（本轮已实测到该报错并修正）。

Odin 的默认堆分配器 `free` 只依赖指针（指针前存着原始 malloc 指针），
**不使用 size**，因此"以 `len` 释放 `cap > len` 的动态数组"是安全的。

## 后果

**收益**

- 容量上限消失：命中不再可能被静默丢弃（`all_a.bin` 从 1572864 回到 2621456）。
- 每分片的分配操作从 **3 次变成 1 次**：原先 = arena 分配（结果）
  + 堆分配（`stable`）+ `memcpy`；现在 = 堆分配（结果）。拷贝也一并消失。
- 修复了每分片一次的隐蔽泄漏（内层切片现已被释放）。
- 少一个模块（`arena_pool.odin`）与两个常量/辅助函数（`ARENA_BLOCK_SIZE`、
  `arena_make`/`arena_free`），职责更集中。

**代价 / 边界**

- 命中结果的分配与释放跨越两个线程（worker 分配，main 释放），
  依赖上面那条"分配器一致性契约"。已写进 `matcher.odin` 与 `scan.odin` 的注释。
- 若将来把 worker 的结果路径改成"分配方释放"，可去掉这条契约。

**未改变（刻意保留）**

- 分片重叠窗口 `[分片边界, 边界 + CHUNK_OVERLAP)` 的命中仍会被相邻任务各报一次
  （README「已知行为与限制」#2）。本 ADR 修的是"丢命中"，**不是**"去重"：
  `dense.bin` 的 655364 与 HEAD 逐字节一致，正是这一契约被保留的证据。
- 单模式路径的算法选择与 `--limit` 语义均未触碰。

## 验证

| 项目 | 结果 |
| --- | --- |
| `dense.bin`（`test --count`） | 655364，与 HEAD **逐字节一致** |
| `all_a.bin`（`a --count`） | 2621456（正确），HEAD 为 1572864 |
| `big.bin`（`test --count --threads 4`） | 7 / 7，与 HEAD 一致 |
| 47 条命令矩阵（stdout/stderr/exit code） | `diff -r` 仅 5 处 help/usage 文本差异，无功能差异 |
| run2（既有行为验收） | 27 PASS / 0 FAIL |
| run3（krep 对齐功能验收） | 43 PASS / 0 FAIL |
| `odin test .`（内存追踪开启） | 105 用例全绿，0 leak、0 bad free |
| 新增回归用例 | `test_dense_results_not_truncated`（60 万条稠密命中；旧实现会被截断到 524288） |
