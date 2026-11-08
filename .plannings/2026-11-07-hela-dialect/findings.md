# findings.md — Hela 方言重构

## 事实

- **Hela 编译器零改动可编译 xrep**：`/opt/repos/hela/odin build . -collection:xrep=.` 一次通过。
  方言按定义处文件判定，未标注文件（search/ 算法层）无需任何处理。
- **`hela/queue.Queue` 接口**：`init(q, capacity2^n, allocator) -> bool`、`push -> bool`（满 false）、
  `pop -> (v, ok)`（空 false）、`push_batch/pop_batch`、`length()`（游标差近似，诊断用）。
  已有 `length()`——本次重构最初以为缺、差点重复实现，**先查现有接口再动手**。
- **`time.Tick` 是 struct{ _nsec: i64 }**：外部取纳秒只能摸私有字段；已回流
  `time.tick_nanoseconds(Tick) -> i64`（hela 侧 additive，1072 core tests 全绿）。
- **Odin 的 `make([]T, len, cap)` 三参形式不存在**（只有 make_slice(T, len)）；
  `delete(dynamic_array)` 不接受 allocator 参数（backing 自带分配器记录）。
- **`sync.atomic_compare_exchange_*`**：expected 是值参数，返回 `(exchanged, current)`，
  内存序枚举是 `.Acq_Rel`（带下划线）。

## 踩坑

- **每 worker 一槽（固定切片）是错误设计**：worker 会抢到多个任务，槽被覆盖 →
  丢命中（`hits_a expected 1 got 0`）。正确形态是每 worker 独占 dynamic 数组、
  逐任务 append，归并时摊平。shared-nothing 的「独占」指**所有权**，不是固定槽位。
- **xrep 是 4 空格缩进风格**：Hela 回归的 `-vet-tabs`/`-strict-style` 是 Hela 仓库内部
  标准，对 xrep 只用 `-vet -disallow-do`，不要把风格门禁强加给外部项目。
- **Bash 里 `grep 'a\|b'`** 在本机是 ripgrep 语义（`\|` 为字面量）→ 用 `grep -E` 或 Grep 工具。

## 缺口（回流/后备）

- 已回流：`core:time/tick_nanoseconds`。
- 已回流（M24 落地，Hela 仓库）：`#+analysis sharing` 的跨类型盲区已补——`worker_data`
  的实证变成了 `check_struct_sharing` 的嵌套拍平阶段（跨字段 pair 报 False sharing）。
- 已落地（M25，本仓库）：`match_lists` 的 40 B `[dynamic]` 头换成 `lib.Match_List`
  （`#align(64)` + 尾 padding，`#assert` 钉住 64 B）。**dense 场景实测无可测差异**：
  瓶颈不是 append 伪共享而是单线程 `merge_ordered_matches`（64 MiB 纯扫描 0.01 s，
  高命中 0.36 s 中几乎全是 8.4M 条 K 路归并 + 区间过滤，1→8 线程无扩展）。
  独立微基准（`hela/tests/hela/array_share`）证明该伪共享值 1.4–1.8x，所以改动保留。
- 已落地（ADR 0011，本仓库）：**并行归并**。线性扫描 → 最小堆（N·K → N·log K），
  单线程 → 按全局 rank 精确切分的 p 路并行。dense 端到端 0.35 s → 0.06 s（5.7x），
  merge 段 281 ms → 18 ms（15.6x），filter 段 21 ms → 0（无过滤时零成本）。
  输出与旧实现**逐字节相同**，且与 `--threads` 无关。伪共享改动至此才真正兑现：
  现在 merge 与扫描都已是带宽受限，append 阶段不再是可忽略的小段。
- 后备：稠密 `-c`（no_stream）模式 FIFO 局部性比 LIFO 慢 ~6%（噪声边缘），
  流式路径 1.97x 收益远大于此。

## 并行归并（ADR 0011）的四个实测结论

1. **82% 的时间在一段串行代码里**：dense 64 MiB 分解为 workers 34.5 ms /
   merge 281.3 ms / filter 21.3 ms。M25 的负面结论正是从这里来的：伪共享的改动在
   dense 下无可测收益，因为时间几乎全在这段串行归并里。
2. **算法与并行度是两个独立正交的收益**：1 线程 0.38 → 0.13 s 是纯算法（2.9x），
   4 线程 0.13 → 0.06 s 是纯并行（2.2x），乘起来 5.7x。只做其中一半，
   另一半会成为新的天花板。
3. **"输出与分区数无关"必须靠切分算法保证，不能靠事后排序**：全局 rank 由数据决定
   （二分边界值 + 按列表下标补足平局），所以 `--threads 1/2/3/5/7/10/16` 的 dump
   逐字节相同。若改成线程各自 append 到共享数组，确定性和负载均衡会同时消失。
4. **有序输出上的区间过滤是一个连续区间**：`--after/--before` 只需二分出上下界
   再原地前移，不必逐条判断 + 重新 append。旧实现每次都复制一遍（dense 下 21 ms），
   新实现在无过滤时是 0。

## 并行归并的踩坑

- **Odin 的过程参数不可赋值**：`heap_down` 里 `i = small` 直接编译失败，
  要落一个局部副本（Hela 里同样如此）。
- **线程内不要分配**：`odin test` 主线程分配器是 `mem.Tracking_Allocator`（无锁 map），
  多线程同时分配会 SIGBUS（ADR 0003 的旧账）。归并线程的所有缓冲都由主线程备好，
  线程里只写内存。
- **`make([]T, n)` 会清零**：134 MB 的置零是 7–10 ms 纯浪费，
  用 `runtime.non_zero_make_slice`（每个位置反正都会被写满）。
- **zsh 不对未加引号的变量做词分割**：`cmd $opt` 里 `opt="--after 1 --before 2"`
  会成**一个**参数，于是选项被静默忽略、对比测试"全都通过"。测 CLI 边界条件时
  必须显式传参或 `"$@"`。
- **`defer` 是块作用域**：写在 `for` 体里每轮结束就执行（这一点与预期一致），
  但只 `delete` 外层数组而忘记内层切片 → `odin test` 的内存追踪会报 leak。
