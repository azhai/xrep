# findings.md — 压测前已确认的事实

## 仓库状态（2026-11-08 09:02）
- `/opt/repos/xrep` 在 `hela` @ cd1ebf2，工作区干净；`main` @ b9aee95 已挂 worktree
  `/private/tmp/xrep_main`（干净）；另有 detached `/private/tmp/xrep_b3` @ 6516f8a。
- `/opt/repos/hela` 在 `design` @ 0885b26，干净；`main` @ 63aac30（fork from odin dev2026-11）。
  现有 `/opt/repos/hela/odin` 是 design 版（5,213,512 B, 08:34 构建），版本
  `dev-2026-11:0885b26`；PATH 上的 `/opt/homebrew/bin/odin` 是另一个 dev-2026-11:9a6991685，
  **不能用来代替两个分支**，必须各自构建。
- `git diff main..hela`：35 文件、+2847/-347；新增 ADR 0010~0013（无锁 MPMC、并行归并、
  count-only、双候选单趟预筛、预读管线、向量归约）。hela 源码带 `#+dialect hela` 且
  `import "core:hela/queue"`，因此**原版 Odin 无法编译 hela 分支**（组合 D 预期失败）。
- `git diff main..design`（编译器）：142 文件 +22045/-30，主要是 `core/hela/*` 与
  src 的 layout/sharing/analysis 扩展；main 分支几乎就是原版 Odin。
- app/bench.odin 在 hela 分支多了 A6（命中密度 × 大小写），且 `scan_region_parallel` 返回
  变成 `(hits, count)` —— 因此 main 的 --bench 少一组，比较时只取共有行。

## 环境
- Apple M4, 10 逻辑核, 16 GiB, arm64; `/usr/bin/clang++` = Apple clang 21;
  `llvm-config` 由 brew `llvm@22` 提供；`/usr/bin/time -l` 可用。
- build.sh 约定：`ODIN_CC=/usr/bin/clang`、`-collection:xrep=.`、`-linker:lld`，
  默认 `-o:size`；历史 Hela 压测用 `-o:speed`。

## P0/P1 实测（09:04–09:07）
- 编译器构建（同样 `CXX=/usr/bin/clang++ LLVM_CONFIG=…llvm@22… ./build_odin.sh release`）：
  | | 原版 main | Hela design |
  | --- | --- | --- |
  | wall | 35.86 s | 36.53 s |
  | maxRSS | 1,443,921,920 B | 1,534,115,840 B |
  | 二进制 | 5,155,400 B | 5,213,512 B (+58,112, +1.13%) |
  | version | `dev-2026-11`（worktree 的 .git 是文件，GIT_SHA 未编入） | 同 |
- xrep 构建（`-o:speed`，同一 ODIN_CC/linker/collection）：
  | 组 | 源码 | 编译器 | 体积 | 编译 wall | maxRSS |
  | --- | --- | --- | --- | --- | --- |
  | A | main | odin-main | 383,408 B | 2.49 s | 335,659,008 |
  | B | hela | odin-design | 400,320 B (+4.4%) | 2.65 s | 350,371,840 |
  | C | main | odin-design | 383,424 B (+16 B) | 2.32 s | 344,539,136 |
  | D | hela | odin-main | — | EXIT=1（`#share(worker)` Syntax Error） | — |
- **C 组只比 A 多 16 字节**：编译器后端对同一份 Odin 源码几乎不产生代码差异，
  因此 B 与 A 的运行时差距主要来自 **xrep 源码改动**，不是编译器 codegen。
- `-o:size` 附加组：A 336,208 B / B 336,832 B（+624 B，+0.19%）；编译 1.61 s / 1.69 s。
- D 组失败点是 `#share` 字段标注（Hela 方言），确认 hela 分支**不可回退**到原版 Odin 编译。

## P2 正确性门禁（09:09–09:11，三组全绿）
- A/B/C 各 5 个包单测全过；`--version` 都是 `xrep 0.3.0`，`--test` 全过。
- 三套行为矩阵各组全过：run.sh（78 条 golden）、run2.sh（34）、run3.sh（56）。
- 端到端 25 个压测场景的**输出多重集** A/B/C 完全一致；2 个 dump 场景逐字节一致。
  4 个场景（`--json` / `-n`）非逐字节相同，是多线程明细顺序（README 已知契约 #7），
  非结果差异。=> 性能数字建立在等价行为上。

## 压测方法学的两次修正（避免假数字）
1. 初次冒烟发现 `-i` + 密集文本时 A/C 的 stdout 混进**进度条中间帧**（慢实现多打几十帧，
   2554 B vs B 的 138 B），被误判为「结果不一致」。改：等价校验剥离进度条并比较输出行多重集，
   计时统一加 `-q` 关掉进度条。
2. `/usr/bin/time` 的 real 只有 10 ms 精度（大量 0.03 s 并列）。改：Python
   `time.perf_counter()` 记 wall，`/usr/bin/time -l` 只提供 user/sys/maxRSS/instructions/cycles。
3. 只用 `-c` 会只测到 B 的 count-only 快路径（ADR 0012），故补 `-n` / `--json` / `--dump`
   的重载场景，强制两边都走完整归并 + 输出管线。

## 冒烟（1 轮，仅用于发现量级，不作为结论）
- `-i` + 256 MiB 真实文本分布（每 36 B 一个 `z`）：A 28.78 s、C 28.81 s、B 0.05 s。
  A/C 是 ADR 0012 记载的 `min(index_byte(a), index_byte(b))` 在密集命中下 O(n²) 退化；
  **这是病态输入上的已知缺陷，不是通用加速比**，报告必须单独标注。
- dense 64 MiB `-c`：A 0.33–0.39 s vs B 0.04–0.08 s（与 ADR 0011 的 5.7x 同量级）。
- `--bench` 单跑 A 耗时 26.42 s、maxRSS 3,367,813,120 B（约 3.1 GiB，合成 100 MiB 数据 × 多轮）。

## 历史数据（文档记载，非本次实测，只用于交叉印证）
- ADR 0010：稠密流式 3.26 s → 1.66 s（1.97x），TSAN 全绿。
- ADR 0011：dense 64 MiB 0.35 → 0.06 s（5.7x）；merge 281 → 18 ms。
- ADR 0013：256 MiB 端到端 -i 76.78 → 43.73 ms（1.76x）；32×4.5 MiB 冷读 1.17x / 暖 1.31x。
- README --bench 示例（main 分支）：A1 1B 24.5 GB/s、128B 3.66 GB/s、A3 64 pat AC 134.7 MB/s。

## 最终实测结论（09:58 定稿）
- **控制组 C 是本次最关键的设计**：C/A 端到端 0.99–1.07x、二进制仅 +16 B，
  证明 A→B 的全部端到端差距来自 xrep 源码（ADR 0010–0013），不是 Hela 编译器 codegen。
  但编译器在个别微循环上确实有收益：A3/A5 multi_match 与 A4 bndm 上 C 与 B 同为
  1.24–1.50x（同一份 main 源码，只换编译器就变快）。
- 端到端 B/A：稀疏/无命中 1.00–1.07x；多文件暖缓存 1.26–1.34x；
  密集 `-c` 3.5–17.4x；输出密集 1.31–3.29x；dense dump 1.94x；
  `-i` 密集文本 470–525x（main 的 O(n²) 已知缺陷，非通用加速比）。
  maxRSS 在密集场景 −21…−42%。
- **micro `multi_ac` 0.49–0.56x 的归因**：12 组诊断实验证明不是编译器（C=1.00x）、
  不是 AC 源码（两分支逐字节相同；独立程序 A/B/C 都 356 MB/s）、不是 Progress /
  Match_Result / Match_List / 方言标注 / import / progress_add / 数据地址偏移
  （10 个偏移全 194 MB/s）。只与"完整二进制中 lib/progress.odin 的内容"相关 →
  **编译产物布局敏感性**；端到端多模式（真实走 AC）B 快 3.54–3.61x，补测 3.59x。
  判定非产品缺陷，不改产品代码（无可可靠修复点，且改了会破坏 A/B 可比性）。
- `--contract` 的 `1 shared field without #atomic` 是提示计数（源码 `hints`），
  指 `Match_List.list`（每 worker 独占、不该原子化）；硬指标 `0 conflicting writers`。
- **Hela 独有的静态能力**（原版不支持）：`-emit-layout:json`（27 KB 清单 + layout_hash）、
  `hela-layout --contract`（3 类型 / 0 冲突）、`#+analysis sharing` 编译期报伪共享、
  `#+dialect hela` / `#explicit` / `#atomic` + `#share`、`core/hela/*` 28 个库。
- 兼容性边界：hela 源码不能被原版 Odin 编译（D 组 `#share` Syntax Error）；
  main 源码两个编译器都能编。冷读无法测（`purge` 需 root）。

## 修复与补测（回应用户追加要求）
1. 等价校验被进度条帧污染 → 剥离进度条 + 输出行多重集，25/25 通过。
2. `/usr/bin/time` 10 ms 精度 → `perf_counter()` 记 wall。
3. 计时加 `-q`，消除"慢实现多打进度条帧"的不公平。
4. 补 `-n` / `--json` / `--dump` 重载场景，避免只测到 B 的 count-only 快路径。
5. **解析器把 A3 与 A5 同名 case 混算** → 按段落加前缀，重解析 8 份输出。
6. 补测：A/B/C 各 1 轮新 `--bench`（26.44 / 35.36 / 25.37 s）+ 6 场景 × 5 轮端到端
   （S12 6.24x、S17 4.90x、S18/S19 3.59x、S23 3.33x、S03 1.03x），与首轮一致。
