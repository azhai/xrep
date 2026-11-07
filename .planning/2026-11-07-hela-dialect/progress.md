# progress.md — Hela 方言重构会话日志

## 2026-11-07

- P0：`git checkout -b hela`；Hela 编译器基线构建通过 + 冒烟通过（上游兼容证实）。
- P1/P2：lib 四文件重写（base/task_pool/output_queue/progress），`#+dialect hela` 入场；
  Match_Result/Output_Item/Scan_Task → #explicit；Progress 无锁化。
  lib 严格检查 + 19 单测绿。
- P3：worker/scan 接线。第一次用「每 worker 固定槽」→ app 两个跨分片测试红
  （命中被同槽覆盖）；改为每 worker 独占 dynamic 数组后全绿（见 findings）。
  清理 6 个 unused import（锁消失后的自然结果）。
- P4：140 单测全绿（lib 19 / engine 26 / app 61 / search 34）。
- P5：78 golden PASS；run2 34 PASS；run3 56 PASS；内建自检 OK；
  838 万条稠密 dump 与 main 分支**逐字节一致**（cmp 通过）；
  bench：稠密流式 3.26s→1.66s（1.97x），稀疏/-c 持平；
  TSAN lib/engine/app 三包全绿；
  `-emit-layout` + `--contract`：Progress 两行 owner=workers/renderer、
  Output_Queue done 行 owner=controller、`0 line(s) with conflicting writers`。
- P6：回流 `core:time/tick_nanoseconds`（xrep 此前摸 `Tick._nsec` 私有字段）；
  hela 1072 core tests 全绿。曾误以为 `queue.length` 缺失并开始重写——
  对照后撤销（已存在），xrep 改用现有 API。
- P7：ADR 0010 落盘 `.ai-memory/adr/0010-hela-dialect-concurrency.md`；
  提交 `c8e671a`（分支 hela）。LICENSE 为先前遗留 untracked 文件，未动。

## 复现命令

```sh
cd /opt/repos/xrep
export ODIN_CC=/usr/bin/clang
H=/opt/repos/hela/odin
$H build . -collection:xrep=. -o:speed -linker:lld -out:/tmp/xrep_hela
for pkg in lib engine app search; do $H test $pkg -collection:xrep=. -o:speed; done
tests/run.sh /tmp/xrep_hela && tests/run2.sh /tmp/xrep_hela && tests/run3.sh /tmp/xrep_hela
$H check lib -collection:xrep=. -no-entry-point -emit-layout:json \
    -emit-layout-file:/tmp/xrep_lib_layout.json
/tmp/hela-layout --contract /tmp/xrep_lib_layout.json
```

## 追加：M25 数组元素边界（Hela）

- `lib.Match_List`：每 worker 一个命中列表头，整 cache line（`#align(64)` + padding，
  `#assert(size_of == 64)`）。`match_lists` 从 `[][dynamic][]Match_Result`（40 B 元素，
  相邻 worker 的头必然同线）改为 `[]lib.Match_List`；`worker_data.out_list` → `^lib.Match_List`。
- 行为不变：140 单测 + 内建自检 + 78 golden + run2 34 + run3 56 全过。
- 实测：dense 64 MiB 无可测差异（瓶颈在单线程归并）；微基准证明伪共享本身值 1.4–1.8x。

## 追加：并行归并（ADR 0011）

- `search/merge.odin` 重写：最小堆替代线性扫最小游标（比较键 `(offset, 列表下标)`，
  精确复刻旧的平局顺序）；新增 `lower_bound` / `upper_bound` / `merge_range` /
  `merge_split_starts`，全部是纯函数，无线程依赖。
- `engine/merge.odin` 新增：`merge_ordered_matches_parallel` —— 按全局 rank 切成 p 段，
  每段一个线程，输出直接写进最终数组的已知区间。主线程备好全部缓冲，线程内零分配。
  每分区 ≥ 65536 条才起线程（`MERGE_MIN_PER_PART`），分区数上限 16。
- `app/scan.odin`：接入并行归并；区间过滤从"复制 + 逐条 append"改为
  "二分上下界 + 原地前移"（无过滤时零成本）；新增 `XREP_PROFILE=1` 阶段计时。
- 测试：`search` +3（含与旧算法逐条比对的等价性用例），`engine` +2
  （48 万条 × p=1..8 并行/串行比对、边界情形）。145 单测全过。
- 实测（64 MiB dense，8.39 M 命中）：端到端 0.35 → 0.06 s（4 线程，5.7x）、
  0.34 → 0.05 s（10 线程）；merge 281 → 18 ms；filter 21 → 0 ms。
  1 线程 0.38 → 0.13 s（纯算法 2.9x）。稀疏/中密度无回归。
- 行为不变：`test.sh` + `verify.sh`（78 golden、run2 34、run3 56、护栏）全过；
  74 MB dump `cmp` 相同；`--threads 1..16` 的 dump 逐字节相同。
