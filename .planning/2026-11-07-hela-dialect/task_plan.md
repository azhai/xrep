# task_plan.md — Hela 方言重构（分支 hela）

## 目标

在 `hela` 分支上，把 xrep 的并发骨架从「Mutex + Cond + 手写环形缓冲」迁移到
Hela 方言与 `core:hela/*` 无锁标准库，给热数据结构写上编译器验证的布局契约；
重构中发现的 Hela 语言 / 标准库缺口回流到 `/opt/repos/hela`。

原则：行为不变（golden 逐字节不变），并发结构换血（消灭 4 把 Mutex / 1 把 Cond）。

## 基线（已验证）

- Hela 编译器（`/opt/repos/hela/odin`）直接构建 xrep 成功，冒烟通过 —— 上游兼容无问题。
- `Match_Result` / `Output_Item` / `Scan_Task` 均为 16 B（u64 + u32 + 4 pad）。
- `out_hits` 只有 output_thread 读写，`hit_mu` 是历史冗余锁。
- `hela/queue.Queue($T)`：无锁 Vyukov MPMC，`init/push/pop`，满返回 false、空返回 false。

## 阶段

- [x] P0 建分支、基线构建、摸清并发结构
- [x] P1 lib 容器 Hela 化：task_pool → hela/queue；output_queue → hela/queue + #atomic done；消灭 Mutex+Cond
- [x] P2 lib 类型 Hela 化：Match_Result / Output_Item / Scan_Task → `#explicit` 16 B；Progress → 无锁（atomic scanned + 渲染权 exchange）
- [x] P3 engine/app 接线：worker 命中列表改每 worker 独占槽（shared-nothing，删 list_mu）；out_hits 本地化（删 hit_mu）；scan 传精确队列容量
- [x] P4 测试同步：task_pool_test LIFO→FIFO（有意变更，注释解释）；output_queue / progress / worker 测试适配；`odin test` 全绿
- [x] P5 门禁与验证：Hela 编译器构建 + 冒烟 + tests/run.sh golden diff 为空 + tests/run2.sh + -emit-layout 导出 lib 清单 + hela-layout --contract 0 conflicts + --hashes 布局基线
- [x] P6 回流 hela：记录语言/标准库缺口，能当轮落实的落实进 /opt/repos/hela
- [x] P7 提交分支、progress.md 收尾、记忆同步

## 恢复点

P6 完成：Hela 侧新增 `core:hela/flow`（M23）与 `hela-layout --stable` 对无方言清单的
拒绝不适用（xrep 清单无 target 字段 → 用 `--contract` / `--hashes`，不用 `--stable`）。
剩余：P7 提交与记忆。
