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
