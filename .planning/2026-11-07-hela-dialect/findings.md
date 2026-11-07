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
- 后备：`#+analysis sharing` 仍是单 struct 内检查——`worker_data` 持有多个共享结构指针
  的跨类型行归属是盲区（Hela 下一步候选 #1 的实证）；稠密 `-c`（no_stream）模式
  FIFO 局部性比 LIFO 慢 ~6%（噪声边缘），流式路径 1.97x 收益远大于此。
