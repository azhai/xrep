# progress.md — 执行日志

## 09:02 探索
- `git status` 两仓库均干净；读取 AGENTS.md / README.md / build.sh / test.sh / verify.sh /
  build_odin.sh / Makefile / .planning 历史记录 / ADR 0013。
- 机器：Apple M4 / 10 核 / 16 GiB；LLVM 22；已有 design 版 odin 但不能假定与 main 同构建参数。
- 决策：用 git worktree 隔离编译器源码，两份编译器都用同一 `build_odin.sh release` 构建；
  设计 A/B/C/D 四组以隔离「代码」与「编译器」两个变量。

## 09:05 失败 1（两个编译器同时、同一原因）
- 命令：`./build_odin.sh release`（无显式 env）→ EXIT=1，20 errors：
  `SDK .../c++/v1/string.h: unknown type name 'size_t'`、`math.h: FP_NAN/FP_ZERO 未声明`、
  `gb.h: memset 未声明`。
- 根因：脚本自动挑中 `/opt/homebrew/opt/llvm/bin/clang++`（LLVM 23）+ llvm 23 include，
  与 Xcode 26.5 SDK 的 libc++ 不匹配。`command -v llvm-config` 在本机不存在，但 brew 循环
  命中了 `llvm`（23）而非 `llvm@22`。
- 修法（来自仓库 `.workbuddy/memory/MEMORY.md` 与 `.plannings/hela/README.md`）：
  `CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release`。
  既有 `/opt/repos/hela/odin` 链接的正是 `@rpath` → `/opt/homebrew/opt/llvm@22/lib/libLLVM.dylib` (22.1.8)。
- **不重试原命令**，改为显式 env 重建。

## 09:06–09:11 构建与门禁
- 两编译器 release 构建 EXIT=0（35.86 s / 36.53 s）。`build_xrep.sh` 六组：
  A/B/C/D(speed) + A/B(size)；D EXIT=1（`#share` 语法）。
- `verify_groups.sh`：三组各 5 包单测、78 golden、run2 34、run3 56 全绿（1m24s）。

## 09:11–09:27 压测
- `gen_corpus.py` 生成 1.2 GiB 语料；`bench_e2e.py` 25 场景（4m51s）、
  `bench_micro.sh` 5 次 --bench（2m22s）、`bench_parse.py` 解析；全程无并发命令干扰计时。
- 等价校验 25/25；发现并修正进度条噪声、time 精度、-q、非计数场景、label 混算 5 处方法问题。

## 09:28–09:45 问题定位（AC 0.5x）
- 12 组诊断实验（diag_variants / variants2 / attrs / dialect / last / final / offsets）：
  独立程序 356 MB/s、完整二进制 B 194 vs A/C 355；C 组排除编译器；
  逐项排除 Progress/Match_Result/Match_List/方言标注/import/progress_add/地址偏移。
  结论：编译产物布局敏感性，非算法回归；端到端多模式 B 快 3.5–4.7x。
- `--contract` 的 1 hint 查源码确认为提示计数（0 conflicts 才是硬指标），非缺陷。

## 09:45–09:58 修复补测与报告
- 修 `bench_parse.py`：按 A1…A6/B 段落给 case 加前缀，A3/A5 不再混算。
- 新增 A/B/C 各 1 轮 --bench（26.44 / 35.36 / 25.37 s）+ 6 场景 × 5 轮端到端补测，
  关键结论与首轮一致（S12 6.24x、S18/S19 3.59x、S03 1.03x）。
- 产出 `report.md`（workspace + /private/tmp 各一份）。

## 09:59–10:00 收尾校验
- 核对四份工作区文件 + memory + /private/tmp 产物均存在；两份 `report.md` `diff` 无差异（13,895 B）。
- 补修 `task_plan.md` 方法学：原写「计时一律用 /usr/bin/time -l」与实测不符，
  回写为 wall 用 `perf_counter()`、`time -l` 只取 user/sys/RSS、统一 `-q`；
  并补记 purge 权限失败（冷读未验证）、必须覆盖 `-n`/`--json`/`--dump`、A3/A5 段落前缀三条。
- 归档内部任务 #1–#7；#7 描述改为如实结论（不改产品代码，布局敏感性 + hint 语义），
  避免日后被误读成「已修复产品代码」。产品源码全程零改动。
