# task_plan.md — xrep main(Odin原版) vs hela(Hela方言) 压测对比

日期：2026-11-08　环境：Apple M4 / 10 逻辑核 / 16 GiB / macOS / LLVM 22

## 目标
1. `xrep:main` 用 `hela:main`（原版 Odin dev-2026-11）编译。
2. `xrep:hela` 用 `hela:design`（Hela 方言）编译。
3. 在当前机器做全方位压测并比较差距，且把「代码改动」与「编译器改动」两个变量隔开。

## 隔离设计（关键）
| 组 | 源码 | 编译器 | 作用 |
| --- | --- | --- | --- |
| A | xrep main | odin-main | 基线 |
| B | xrep hela | odin-design | 目标（用户要求的组合） |
| C | xrep main | odin-design | 控制组：只换编译器，隔离编译器后端差异 |
| D | xrep hela | odin-main | 兼容性边界（预期失败：#+dialect hela / core:hela/queue） |

## 阶段
- [x] P0 准备：worktree（hela main + design detach）、编译两份 Odin 编译器（同为 release）
- [x] P1 构建：A/B/C 三组 xrep（-o:speed 主测，-o:size 附加），记录编译耗时/体积/hash；D 记录失败原因
- [x] P2 正确性门禁：--test、test.sh、verify.sh（golden/run2/run3）、A/B 输出逐字节一致
- [x] P3 内建微基准 --bench：A/B/C 各 2~3 轮，解析 A1~A6 + B 组
- [x] P4 端到端压测：固定语料（sparse/text/dense/multi-file/no-hit），场景矩阵 × 线程数 × 模式数，
      交错多轮取中位数，采集 wall/user/sys/maxRSS，并校验命中结果一致
- [x] P5 非性能维度：Hela 静态能力（layout/contract/sharing/TSAN）、代码规模、并发原语、
      编译器自身构建成本与体积
- [x] P6 汇总报告：`/private/tmp/xrep_compare/report.md` + 复现脚本，写回 workspace memory
- [x] P7 追加（用户要求「发现问题立即修复补测」）：修解析器 label 混算、查清 AC 0.5x 与
      --contract hint、重跑 --bench 与 6 场景端到端补测，结论写入报告 §5.1 / §7

## 方法学（防自欺）
- 两组二进制用**同一优化级别、同一 LLVM/链接器、同一份语料、同一命令**。
- 每轮 A/B 交错执行，抵消机器热漂移；报告最小值/中位数/方差，不挑好看的单次。
- 计时（**实测中已修正，以此为准**）：wall 用 Python `time.perf_counter()`——`/usr/bin/time` 只有
  10 ms 精度，短场景全是 `0.03 s` 无法分辨；user/sys/maxRSS/instructions/cycles 仍用
  `/usr/bin/time -l`；计时命令统一追加 `-q` 关闭进度条，避免慢实现多刷帧造成不公平。输出重定向到 /dev/null 或文件。
- 大文件语料先生成并复用；冷/暖缓存分别标注，冷读用 `purge` 不可用时明确说明未清缓存
  （本机 `purge` 报 `Operation not permitted`，故所有多文件场景均为暖 page cache，冷读未验证）。
- 每个压测场景先校验两边 `--count`/`--dump` 一致，性能数字只对等价结果成立：输出按**行多重集**比较，
  先剥离进度条中间帧；`--dump` 逐字节比较；`-i` 大语料改用小语料等价副本校验。
- **不能只测 `-c`**：B 有 count-only 快路径（ADR 0012），必须补 `-n` / `--json` / `--dump`
  覆盖完整输出路径，否则结论偏袒 B。
- `--bench` 解析按 `-- A1…A6 / B` 段落加前缀：A3（稠密）与 A5（无命中）同名 case 会混算中位数。
- 结论区分「实测」「文档记载」「未验证」，不把 ADR 里的历史数字当本次实测。
