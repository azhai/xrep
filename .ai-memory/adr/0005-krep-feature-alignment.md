# ADR 0005 — 对齐 krep 的核心功能（目录遍历 / 常用 flag / 行导向输出）

- 状态：已接受（Accepted）
- 日期：2026-09-12
- 关联：ADR 0001（模块拆分与能力缝隙）、ADR 0002（可选修复项）、
  ADR 0004（命中结果堆分配）、README「用法」「已知行为与限制」

## 背景

需求：参考 [krep](https://github.com/davidesantangelo/krep) 补齐主要功能，
其中最有价值的是 `-r`（递归搜索目录）。xrep 此前只能接收"文件列表"，
连"这是不是目录"都不判断。

krep 是行导向的 grep 类工具（输出 `文件:行号:行内容`），而 xrep 是**偏移导向**的
二进制搜索器（输出 `match offset: N`）。两者输出模型不同，需要先定边界。

## 范围决策

| 维度 | 决策 | 理由 |
| --- | --- | --- |
| 功能范围 | **核心**：目录遍历 + 常用 flag（`-r`、glob、exclude、hidden、`-l/-L`、`-n`、`-o`、`-m`、`--json`、`--stats`、`--color`、`-e/-f` 多模式、短标志别名） | 覆盖日常用法；不引入重型依赖 |
| 输出模型 | **新增行导向模式，偏移输出保持默认** | 单文件默认调用必须逐字节兼容（回归护栏） |
| 明确不做 | POSIX 正则、`.gitignore` 解析、`--algo` 选择、`-s`、`--no-simd` | 与"最小可用实现"冲突；正则尤其会拖入整套自动机 |

## 决策

### 1. 目录遍历放在新模块 `walk.odin`（能力缝隙）

`main` 先把"输入路径列表"展开为"文件列表"，再交给既有的逐文件扫描路径：

```
main → walk_expand(paths, Walk_Options) → []string → scan_file(...)
```

- `walk_expand` 负责：判断路径是文件还是目录、递归与否、隐藏项、glob/exclude 过滤。
- 展开结果由 `walk_free` 释放（与 `Options.file_list` 的所有权链一致）。
- glob 自实现（`glob_match`/`glob_match_here`）：`*` 不跨 `/`、`**` 跨 `/`、
  `?` 匹配单个非 `/` 字符、`\` 转义；模式不含 `/` 时只与 **basename** 比对。
  **不引入正则引擎**：需求里没有正则，用它换来的复杂度不值得。

`scan_file` / `scan_region_parallel` 因此不需要知道"目录"这件事，
保持了单向依赖与零改动面。

### 2. 输出格式由"是否多文件"决定，而不是由新 flag 决定

```
多文件 / -r          → path:line:offset
单文件 + -n          → line:offset
其余（含单文件默认）  → match offset: N     （逐字节兼容 HEAD）
```

"多文件"本身就是"必须带文件名"的充分信号，无需用户再记一个 flag；
`show_path := recursive || len(files) > 1`，在 `main` 算一次。

进度条只在"传统偏移模式"下开启：它用 `\r` 原地刷新写 stdout，
混进 `path:line:offset` / JSON 会破坏管道消费。

### 3. `-m/--max-count` 同时约束"计数"与"打印"

两条路径（输出线程的流式打印、归并后的汇总/落盘）都截断到 N 条，保证
`--count` 与明细条数一致。取的是**流式到达顺序**的前 N 条 —— 多分片时任务完成
顺序与偏移顺序可能不同，因此未必是"偏移最小的 N 条"；这是刻意的取舍
（要按偏移取前 N 条就得等全部结果归并完，牺牲流式输出）。

### 4. `Match_Result` 增加 `pat_len`（本轮唯一的结构体变更）

`-o` 需要知道"命中到的是哪一段字节"，多模式下不同模式的长度不同，
因此命中结果必须自带长度。该字段的引入**顺带暴露了一个既有缺陷**，
其修复单独立项为 ADR 0004（命中结果从定长 arena 改为堆分配）。

### 5. 唯一的有意行为变更：`--no-color` 真正生效

- 原实现：接受 `--no-color` 但 `use_color` 恒为 `true`（README 曾把它登记为"契约"）。
- 现在：新增三态 `--color=always|never|auto`，`--no-color` 是 `--color never` 的别名，
  默认 `always`，`auto` 按 stdout 是否 TTY 判定。

这是**用户能明显感知的行为变化**：原来 `--no-color` 毫无作用，现在会真的去掉 ANSI 转义。
之所以在本轮改：引入 `--color` 后"恒为彩色"不再自洽，保留旧行为会变成"有 `--color never`
却独独 `--no-color` 无效"的更奇怪状态。47 条历史命令矩阵未覆盖 `--no-color`
（这也是为什么该矩阵 `diff` 仍只有 help 文本差异）。

## 后果

- 新增模块 1 个（`walk.odin`）、新增测试文件 1 个（`walk_test.odin`，11 个用例）；
  测试总数 77 → 105（含 ADR 0004 的 5 个新用例，扣除删除的 7 个 arena 用例）。
- `cli.odin` 明显变复杂：`Options` 字段增多、新增 `normalize_args`
  （`--k=v`、`-t8`、`-rn` 捆绑归一化）与 `options_destroy`（统一释放所有动态字段）。
  这是"flag 变多"的必然代价，用集中释放换取"不再逐个 delete"。
- 单文件默认输出保持逐字节兼容；多文件输出**是新增的**，不构成回归。

## 验证

| 项目 | 结果 |
| --- | --- |
| `run3.sh`（krep 对齐功能断言） | 43 PASS / 0 FAIL |
| `run.sh` 47 条历史命令 | `diff -r` 仅 help/usage 文本差异 |
| `run2.sh`（ADR 0002 行为） | 27 PASS / 0 FAIL |
| `odin test .` | 105 用例全绿，0 leak、0 bad free |
| 单文件默认输出 | `match offset: N` + `=== file: N results ===`，与 HEAD 一致 |
