# ADR 0003 — 线程上下文归一化与分配器卫生

- 状态：已接受（Accepted）
- 日期：2026-09-12
- 关联：ADR 0001（模块拆分与能力缝隙）、ADR 0002（可选修复项）、
  README「测试」「并发与内存约定」

## 背景

上一轮（ADR 0002）收尾时，测试是靠在 `test.sh` 里传
`-define:ODIN_TEST_TRACK_MEMORY=false` **关闭内存追踪**才稳定通过的，理由写着
"测试运行器的追踪分配器不适配跨线程并发分配"。这是一个**压制症状**的做法，
代价是：任何真实的泄漏都不再被发现，而且裸跑 `odin test .` 会直接崩。

本轮先复现，再定位到根因，然后把压制手段去掉。

### 复现

```
裸跑 odin test .（默认 10 线程 runner，内存追踪默认开启）：8 次里 4 次退出码 138（SIGBUS）
串行 runner（ODIN_TEST_THREADS=1）+ 追踪开启：5/5 通过
默认 runner + 追踪关闭：稳定通过
```

对照这组数据可以确定：崩溃与**测试运行器线程数**和**追踪器**同时相关，
与单个用例无关（各测试组单独跑都过）。

### 根因

`core:mem.Tracking_Allocator` 的内部状态是
`allocation_map: map[rawptr]Tracking_Allocator_Entry` —— **一个无锁 map**。
它本身不是线程安全的。

而 Odin 创建线程时会**复制创建者的 `context`**，因此被测代码里的
`worker_steal` / `output_thread` 会继承测试运行器安装的追踪分配器。
`odin test` 默认用 10 个 runner 线程并发跑用例，此时"某个用例的 worker 线程"
与"另一个用例的主线程"会同时向同一个无锁 map 写入 → 结构损坏 → SIGBUS。

这同时解释了为什么会产生"大量误导性 leak 告警"：损坏的 map 让释放记录对不上。

## 决策

### 1. spawn 出的线程一律不继承调用方的分配器

`worker_steal` 与 `output_thread` 的**第一件事**：

```odin
context = runtime.default_context()
```

生产环境下 main 的分配器就是堆分配器，继承与不继承等价，因此**行为不变**；
测试环境下则切断了与追踪分配器的共享。测试里自建的线程
（`output_queue_test.odin` 的 producer）同样处理。

> 备选方案：在 `thread.create_and_start_with_data` 传 `init_context`。两者等价，
> 但"写在被调起的线程入口"更不容易漏 —— 谁被调起，谁负责自己的上下文。

### 2. 匹配算法不再改写 `context.allocator`

`single_match` / `naive_match` 原先写 `context.allocator = mem.arena_allocator(arena)`。
这是**全局副作用**：该线程的分配器被永久改写，proc 返回也不还原。后果：

- `worker_steal` 里注释声称"拷贝到堆上"的 `stable := make([]Match_Result, n)`
  实际上落进了 arena（已用独立探针确认 `make` 的目标地址落在 `arena.data` 之内）；
- `output_queue_push` 的 `append` 也会走这条路，可能把共享队列的底层数组
  迁进某个会被 reset 的 arena；
- `arena_pool_put` 的 `append(&p.free_list, a)` 同理。

改为把 arena 分配器**显式**传给每一次分配：

```odin
results := make([dynamic]Match_Result, 0, 64, mem.arena_allocator(arena))
```

设计意图（结果数组从 arena 批量分配）保持不变，副作用消失。已在
matcher.odin 文件头写明"不得改 `context.allocator`"及其原因。

> **后续（ADR 0004，2026-09-12）**：本节"用 arena 承载命中数组"的**设计意图**
> 本身已被推翻 —— arena 定长，而命中数无上界，超容量时 `append` 会静默丢命中
> （实测 `all_a.bin` 丢失 40%）。现在命中数组改用 `context.allocator`（进程默认堆）
> 分配，`Arena_Pool` 已删除。本节"不得改 `context.allocator`"这条**约束仍然有效**
> （改写线程分配器始终是错的），只是结果数组不再需要 arena 参数。

### 3. `merge_ordered_matches` 的临时缓冲用后即释放

`ptrs` / `non_empty` 是每次归并都会分配的临时数组（长度 = 线程数），原先从不释放，
是生产代码里**真实的泄漏**。补 `defer delete(...)`。
返回的 `out` 仍由调用方拥有，不在函数内释放。

### 4. 全局表初始化改 `@(init)` / 编译期常量

原先 `lower_table` / `alg_table` 依赖 `main` 调用初始化函数，而
**`odin test` 不执行 `main`**，于是每个扫描类用例都得自己调一次
`scan_init_globals()`；漏掉的后果很隐蔽：`lower_table` 全 0 会让大小写不敏感匹配
把所有字节视为相等（曾得到 29 命中而非 3）。

- `lower_table: [256]u8` + `@(init) init_lower_table :: proc "contextless" ()`
  —— 定长数组、纯算术，不需要分配器，正好满足 `@(init)` 的 contextless 约束。
- `alg_table` 改为**编译期常量数组**（含匹配函数指针），不再需要初始化，
  也不再占堆内存。随之删除 `init_alg_table`、`scan_init_globals` 及其 13 处调用。

### 5. `cli.file_list` 惰性分配 + 明确所有权

`parse_args` 原先无条件 `make([dynamic]string)`，且从未释放（生产是进程级，
测试里则被追踪器报为泄漏）。改为按需分配（首次 `append` 时由 Odin 自动分配），
并在 `Options` 字段与函数注释里写明**调用方负责 delete**；`main` 在文件循环结束后
显式归还，测试在用例内 `defer delete(...)`。

### 6. `test.sh` 恢复内存追踪

根因既已修掉，就不再需要关掉追踪。基线是 **77 用例全绿、0 条 `+++ leak`**，
因此"看到 leak 就是真问题"。测试侧的分配也随之补齐释放：
`merge_test` 释放归并结果、`slice_utils_test` 释放 map/filter 结果、
`scan_test` 用不分配的 `os.exists` 替代 `os.stat`。

## 影响与验证

**对外可观察行为零变化。** 47 条命令矩阵（全部标志组合、错误路径、多线程、
dump、`--test`/`--help`）的 stdout / stderr / 退出码，以及 dump 文件内容，
与改动前 `diff -r` **完全为空**。

验证命令与结果：

```
./build.sh / odin check .                          → exit 0 / 无告警
裸跑 odin test .（默认线程 + 追踪开启，10 次）      → 10/10 通过，0 leak
./test.sh                                          → 77/77 + 内建自检全绿，exit 0
47 条命令矩阵 vs 改动前                             → 0 差异
新增行为矩阵（27 条断言）                            → PASS=27 FAIL=0
多分片正确性（5 MiB 稀疏 / 2.5 MiB 高密度 dump）      → 行数与偏移逐个正确，仅契约内的边界重复
```

## 记录：两个遗留的"环境陷阱"

1. **`odin test .` 会删除仓库里的 `./xrep`**：它编译测试产物时占用同名路径并在
   结束时清理。所以 `test.sh` 必须"先 `odin test`，后 `build.sh` + `./xrep --test`"。
   本轮排查中曾因这个现象误判为"二进制被误删"。
2. **`core:mem` 的 `Arena` 是"只 reset、不还内存"**（`arena_free_all` 仅置
   `offset = 0`）。任何指向 arena 的数据都必须在下一次复用前深拷贝出去；
   本轮已把这条写进 README「并发与内存约定」与 `worker.odin` 注释。
