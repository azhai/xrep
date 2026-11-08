# xrep：main（Odin 原版） vs hela（Hela 方言）压测对比报告

日期：2026-11-08 09:02–09:58　环境：Apple M4 / 10 逻辑核 / 16 GiB / macOS 26.5 SDK / LLVM 22 / Apple clang 21

## 0. 一句话结论

**端到端真实负载上 hela 分支明显更快（密集命中、多模式、输出密集场景 3.3–17x；`-i` 密集文本这个病态输入上 470–525x），稀疏/无命中场景持平；峰值内存更低（最多 −42%）。差距来自 xrep 源码改动（ADR 0010–0013），不是编译器 codegen——控制组证明换编译器只差 16 字节、端到端 ≈1.00x。代价是 +28% 代码、+4.4% 二进制、强绑定 Hela 方言（不可回退原版 Odin），以及一个只在微基准里出现的 AC 吞吐倒挂（0.5x，已定位为编译产物布局敏感性，端到端无回归）。**

## 1. 方法与隔离设计

| 组 | xrep 源码 | 编译器 | 作用 |
| --- | --- | --- | --- |
| **A** | `main` @ b9aee95 | `hela:main` @ 63aac30（原版 Odin dev-2026-11） | 基线 |
| **B** | `hela` @ cd1ebf2 | `hela:design` @ 0885b26（Hela 方言） | 用户指定的目标组合 |
| **C** | `main` | `hela:design` | **控制组**：只换编译器，隔离 codegen 影响 |
| **D** | `hela` | `hela:main` | 兼容性边界：EXIT=1（`#share(worker)` Syntax Error） |

- 两份编译器用同一 `CXX=/usr/bin/clang++ LLVM_CONFIG=…llvm@22… ./build_odin.sh release` 构建（默认参数会误选 Homebrew LLVM 23，与 Xcode 26.5 SDK 的 libc++ 冲突，已记录）。
- xrep 全部用 `-o:speed -collection:xrep=. -linker:lld ODIN_CC=/usr/bin/clang`；另建 `-o:size` 两组做体积对照。
- 语料固定生成在 `/private/tmp/xrep_compare/corpus/`（1.2 GiB）：sparse 256 MiB（1 hit/64 KiB）、text 256 MiB（`"alpha beta gamma delta epsilon zeta\n"` 36 B 循环）、dense 64 MiB（1 `aaa`/8 B）、nohit 256 MiB、32×8 MiB 目录、4/16/64 模式文件。
- 25 个端到端场景、交错 A/B/C 顺序、2–5 轮取中位数；wall 用 `perf_counter()`（`/usr/bin/time` 只有 10 ms 精度），user/sys/maxRSS/instructions 用 `/usr/bin/time -l`；计时统一 `-q` 关闭进度条。
- 微基准 `--bench`：A/B 各 3 轮、C 2 轮；解析器按 `-- A1…A6 / B` 段落给 case 加前缀（A3 与 A5 原本同名，会混算）。
- 计时前先做**结果等价校验**：25 个场景 A/B/C 输出多重集一致，2 个 `--dump` 场景逐字节一致。

## 2. 构建产物

| 项 | A 原版 | B Hela | 差 |
| --- | --- | --- | --- |
| 编译器构建 wall / maxRSS | 35.86 s / 1.44 GB | 36.53 s / 1.53 GB | +1.9% / +6.2% |
| 编译器二进制 | 5,155,400 B | 5,213,512 B | +58,112 B（+1.13%） |
| xrep `-o:speed` 编译 wall | 2.49 s | 2.65 s | +6% |
| xrep `-o:speed` 二进制 | 383,408 B | 400,320 B | **+16,912 B（+4.4%）** |
| xrep `-o:size` 二进制 | 336,208 B | 336,832 B | +624 B（+0.19%） |
| C 组（main 源码 + Hela 编译器） | 383,424 B | — | **仅 +16 B** |

`__const` 40,632 → 41,928 B；动态依赖相同（Foundation + libSystem）。**同一份源码换编译器只差 16 字节**，是"差距不来自编译器"的第一条硬证据。

## 3. 正确性门禁（三组全绿）

- `--version` 均为 `xrep 0.3.0`，`--test` 全过；逐包单测（`. /lib /search /engine /app`）A/B/C 各 5/5 通过。
- 行为矩阵：78 条 golden + run2 34 条 + run3 56 条断言，三组全绿。
- 25 个压测场景输出多重集一致；4 个 `--json`/`-n` 场景非逐字节相同，是多线程明细顺序（README 已知契约 #7），非结果差异。

## 4. 端到端压测（中位数，单位 s）

| 场景族 | 代表场景 | A | B | C | B/A |
| --- | --- | --- | --- | --- | --- |
| 稀疏 256 MiB，`-t` 1/2/4/8/10 | S03 `-t4` | 0.0419 | 0.0418 | 0.0425 | 1.00x |
| 无命中 256 MiB | S06 | 0.0422 | 0.0421 | 0.0424 | 1.00x |
| **`-i` 密集文本 256 MiB** | S07 `-t4` | **28.9671** | **0.0552** | 29.2014 | **524.8x** |
| 同上 `-t8` | S08 | 24.3484 | 0.0518 | 24.2953 | 469.6x |
| 密集文本（区分大小写） | S09/S10 | 0.9534 / 0.9826 | 0.0551 / 0.0564 | ≈A | 17.3x / 17.4x |
| dense 64 MiB `-c` | S11/S12/S13 | 0.3848 / 0.3427 / 0.3366 | 0.0873 / 0.0541 / 0.0483 | ≈A | 4.41x / 6.34x / 6.97x |
| 32 文件 `-r`（暖缓存） | S14/S15/S16 | 0.0643 / 0.0427 / 0.0435 | 0.0481 / 0.0340 / 0.0335 | ≈A | 1.34x / 1.26x / 1.30x |
| 多模式 4/16/64 `-c` | S17/S18/S19 | 0.3171 / 0.5220 / 0.5085 | 0.0672 / 0.1473 / 0.1407 | ≈A | 4.72x / 3.54x / 3.61x |
| 输出/行号密集 | S20/S21/S23/S25 | 0.0191 / 0.0185 / 0.0690 / 0.0688 | 0.0145 / 0.0141 / 0.0210 / 0.0213 | ≈A | 1.32x / 1.31x / **3.29x** / 3.23x |
| 落盘 | S22 稀疏 / S24 dense 64 MiB | 0.0422 / 0.5977 | 0.0415 / 0.3089 | ≈A | 1.02x / 1.94x |

- **C/A 全程 0.99–1.07x**：所有端到端差距都由源码改动带来。
- 方差很小（典型 stdev < 1%，dense dump 3%）；`-i` 病态场景 A 两次 28.86/29.07 s，B 0.0549/0.0555 s。
- 525x 不是通用加速比：它是 main 分支 `min(index_byte(a), index_byte(b))` 在"每 36 B 一次命中"分布上的 O(n²) 退化（ADR 0012/0013 已记载），属于修掉已知缺陷；真实稀疏/无命中场景两边一样快。
- 只用 `-c` 会偏袒 B 的 count-only 快路径，故补了 `-n` / `--json` / `--dump` 强制走完整归并+输出，B 仍有 1.94–3.29x。

### 内存（maxRSS 中位数）

| 场景 | A | B | C | 变化 |
| --- | --- | --- | --- | --- |
| sparse 256 MiB | 262.3 MB | 262.5 MB | 262.3 MB | 持平 |
| `-i` text 256 MiB | 628.4 MB | 406.8 MB | 634.2 MB | **−35%** |
| dense 64 MiB `-c` | 616.2 MB | 355.0 MB | 614.3 MB | **−42%** |
| dense 64 MiB `--dump` | 613.3 MB | 482.7 MB | 612.4 MB | −21% |
| text 64 MiB `-n` | 164.9 MB | 106.3 MB | 163.5 MB | −36% |

`--bench` 进程峰值相反：A 4.08–4.75 GiB、B 5.91–6.10 GiB、C 5.91 GiB（C 与 B 接近，提示与编译器相关；样本少，不作定论）。

## 5. 内建微基准 `--bench`（MB/s，按段分组，多轮中位数）

| case | A | B | C | B/A | 归因 |
| --- | --- | --- | --- | --- | --- |
| A1 单模式 1B/2B/4B/16B/17B/64B/128B | 29,270 … 3,866 | ≈A | ≈A | 0.98–1.03x | 主 SIMD 路径无差异 |
| A2 `4B -i` | 12,011 | **17,565** | 11,902 | **1.46x** | 源码：双候选单趟 + 向量归约 |
| A3 `4 pat multi_match` | 1,425 | 1,787 | 1,826 | 1.25x | **编译器**（C 同 1.28x） |
| A5 `4/16/64 pat multi_match` | 1,879 / 1,876 / 1,870 | 2,465 / 2,499 / 2,497 | 2,509 / 2,436 / 2,499 | 1.31–1.34x | **编译器**（C 同 1.30–1.34x） |
| A3/A5 `multi_ac` 全档 | 292–581 | 159–322 | 310–581 | **0.49–0.56x** | 见 §5.1 |
| A4 `uniform bndm_match` | 5,123 | 7,670 | 7,687 | 1.50x | **编译器**（C 同 1.50x） |
| A4 `zeros memchr/bndm` | 754 / 756 | 1,046 / 1,043 | 825 / 837 | 1.38x | 编译器 1.11x + 源码 |
| B 组 1/2/4/8 线程 | 58,658 / 69,272 / 72,525 / 91,971 | 59,041 / 65,776 / 89,636 / 95,238 | ≈A 或略高 | 1.01 / 0.95 / 1.24 / 1.04x | 波动 |
| A6（8 个 case） | — | 238–68,670 | — | — | **仅 hela 分支有** |

`--bench` 总耗时：A 25–26 s、B 33–35 s、C 25 s（B 多 A6 一组且 AC 档更慢）。

### 5.1 唯一稳定负面差异：`multi_ac` 只有基线一半

归因链（全部为本次实测）：

1. C 组（main 源码 + Hela 编译器）`multi_ac` 与 A 一致（0.99–1.06x）→ **不是编译器 codegen**。
2. `search/ac.odin` 两分支逐字节相同；独立程序（只链 `lib`+`search`，100 MiB 数据、16 模式）A/B/C 全为 ~356 MB/s → **AC 算法本身没退化**。
3. 差距只在**完整二进制**里出现：精简 `run_bench` 到只剩一个 AC case 仍复现 A/C 355、B 195 MB/s → 不是前面各组的运行时残留。
4. 文件级二分：把 hela 的 `lib/base.odin`+`lib/progress.odin` 引入 main 树即掉到 194；换 `search/*` 无影响。
5. 逐项排除：`Progress` 结构/对齐/原子标注/时钟/栈堆、`Match_Result #explicit`、`Match_List`/`#assert`、`progress_add` 调用点与空实现、`#+dialect hela` 标注、import 集合、10 种数据地址偏移（0…4160 B）全部仍 ~194 MB/s。
6. **结论**：这是编译产物的代码/数据布局敏感性——无关文件内容改变了 LLVM 对 AC 热循环的优化决策，不是 AC 算法回归，也不是可稳定复现的产品缺陷。**真实端到端路径**（S18/S19，16/64 模式、确实走 AC）B 快 3.54–3.61x，补测 3.59x；count-only 与并行归并掩盖了微循环差距。
7. 处理：**不改产品代码**（无可靠修复点，盲改会破坏 A/B 可比性）；把 `--bench` 的 AC 绝对值标为"不可跨二进制直接比较的口径"，建议后续用独立微基准或 perf counter 复核。

## 6. 非性能维度

| 维度 | main | hela |
| --- | --- | --- |
| 生产 `.odin` | 17 文件 / 3,862 行 | 20 文件 / 4,938 行（**+27.9%**） |
| 测试 `.odin` | 13 文件 / 4,085 行 | 16 文件 / 4,727 行（+15.7%） |
| 分支 diff | — | 35 文件，+2,847 / −347（ADR 0010–0013） |
| `sync.Mutex` / `mutex_*` | 11 / 22 | 5 / 13 |
| `sync.Cond` / `cond_*` | 1 / 4 | 3 / 8 |
| `atomic_*` | 0 | **30** |
| `core:hela/queue` | 0 | 8 |
| `#+dialect hela` / `#share` / `#align(64)` | 0 / 0 / 0 | 13 / 6 / 4 |

**Hela 编译器独有的静态能力（本次实测，原版 Odin 不支持）**：

- `-emit-layout:json` 导出 `lib` 包布局清单（27,261 B，含 `layout_hash`、`cache_line`、逐字段偏移）；原版报 `Unknown flag: 'emit-layout'`。
- `hela-layout --contract`：3 个类型、**0 行 writer 冲突**、1 个 `shared field without #atomic` 提示。后者是**设计提示**（源码 `hints` 只统计"带 `#share` 但未标 `#atomic`"的字段），这里指 `Match_List.list`——每 worker 独占，本就不该原子化；硬指标是 0 conflicts。
- `#+analysis sharing` 负例实测：编译器报 `False sharing: 'tail' … 'head' both live in cache line 0` 并给出修复建议；原版对 `#+dialect hela` / `#share` 直接 Syntax Error。
- `core/hela/*` 28 个新库（queue / flow / io / exec / layout / pattern …）、`layout_hash_of`、TSAN 门控（本次未跑，历史记录全绿）。

**其它**：

- 兼容性：hela 源码**不能**用原版 Odin 编译（D 组）；main 源码两个编译器都能编。
- 预读管线（B 独有）：`XREP_NO_READAHEAD=1` 自身 A/B 实测 on 0.0286 s vs off 0.0399 s = **1.40x**（暖缓存）；A 无此开关。
- 冷读未验证：`purge` 需要 root（`Operation not permitted`），所有多文件场景都是 page cache 暖态。

## 7. 修复与补测记录（本轮）

| # | 发现的问题 | 修复 | 补测结果 |
| --- | --- | --- | --- |
| 1 | `-i` 慢实现的进度条中间帧混入 stdout，被误判为"结果不一致" | 等价校验剥离进度条帧并比较输出行多重集 | 25/25 场景等价，2 个 dump 逐字节一致 |
| 2 | `/usr/bin/time` real 只有 10 ms 精度，短场景全是 0.03 s | wall 改用 `perf_counter()` | 0.04 s 级场景可分辨，stdev < 1% |
| 3 | 进度条帧数随实现速度变化，计时不公平 | 计时统一加 `-q` | 重跑全矩阵 |
| 4 | 只测 `-c` 只覆盖 B 的 count-only 快路径 | 补 `-n` / `--json` / `--dump` 重载场景 | B 在完整输出路径仍 1.94–3.29x |
| 5 | **微基准解析器把 A3（稠密）与 A5（无命中）同名 case 混算中位数** | 按 `-- A1…A6/B` 段落给 case 加前缀 | 重解析 8 份输出；新增 A/B/C 各 1 轮 `--bench`（26.44 / 35.36 / 25.37 s），结论稳定 |
| 6 | 代表性端到端结论需要复核 | 6 场景各 5 轮交错重跑 | S03 1.03x、S12 6.24x、S17 4.90x、S18 3.59x、S19 3.59x、S23 3.33x，与首轮一致 |

**查清后判定为非缺陷、不改代码**：`--contract` 的 1 个 hint（设计提示，0 conflicts）；`multi_ac` 0.5x（编译产物布局敏感性，端到端无回归，无可靠修复点）。

## 8. 结论与取舍

1. **收益**：密集命中 / 多模式 / 输出密集端到端 3.3–17x，峰值内存 −21…−42%，`-i` 病态输入上修掉 O(n²) 退化；行为完全等价（全门禁 + 输出等价）。
2. **归因**：差距来自源码（无锁 MPMC、并行归并、count-only、双候选单趟预筛、预读管线），**不是编译器**；C 组端到端 ≈1.00x、二进制仅 +16 B。编译器 codegen 只在个别微循环（multi_match / bndm）给同一份 main 源码带来 1.1–1.5x。
3. **代价**：+27.9% 生产代码、+4.4% 二进制、编译时间 +6%、`--bench` 峰值内存更高、强绑定 Hela 方言（不可回退原版 Odin）、微基准 AC 档倒挂 0.5x。
4. **未验证 / 风险**：冷读（purge 需 root）、TSAN（本次未跑，历史记录全绿）、`--bench` 绝对值跨二进制可比性、微基准轮间波动（A3/A5 个别档 ±30%）。

## 9. 复现

```bash
# 编译器（两份，必须显式指定 Apple clang + LLVM 22）
cd /private/tmp/hela_main   && CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release
cd /private/tmp/hela_design && CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release

# 构建 / 门禁 / 压测
/private/tmp/xrep_compare/build_xrep.sh
/private/tmp/xrep_compare/verify_groups.sh
python3 /private/tmp/xrep_compare/gen_corpus.py
python3 /private/tmp/xrep_compare/bench_e2e.py       # 25 场景，results.csv / summary.json
/private/tmp/xrep_compare/bench_micro.sh
python3 /private/tmp/xrep_compare/bench_parse.py     # 修复后的分段解析
python3 /private/tmp/xrep_compare/e2e_recheck.py     # 修复后补测
```

产物：`/private/tmp/xrep_compare/`（bin/、corpus/、logs/、results.csv、summary.json、equivalence.json、logs/micro_summary_fixed.txt、recheck_summary.json、各诊断脚本 `diag_*.py`）。计划与发现：`.plannings/compare-2026-11-08/{task_plan,findings,progress}.md`。
