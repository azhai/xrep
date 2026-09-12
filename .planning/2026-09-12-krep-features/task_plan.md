# 任务计划：对齐 krep 核心功能（目录遍历 + 常用 flag）

参考 https://github.com/davidesantangelo/krep 。
用户决策（AskUserQuestion）：
- **范围** = 「核心：目录遍历 + 常用 flag」（不含 POSIX 正则、`.gitignore`、`--algo`、`-s`、`--no-simd`）
- **输出模型** = 「新增行导向模式，偏移输出保留默认」

## 目标
1. 目录遍历层：`-r/--recursive`、`--glob=GLOB`、`--exclude=GLOB`、`--hidden`
2. `-l/-L`（有/无命中的文件）
3. `-n/--line-number`（行号）
4. `-o/--only-matching`
5. `-m/--max-count NUM`（每文件上限）
6. `-t` 短别名 + `--flag=value` 形式 + 布尔短 flag 捆绑（`-rn`）
7. `-e PATTERN`（可重复）/ `-f FILE`（从文件读模式）→ 多模式
8. `--json` / `--jsonl`
9. `--stats`
10. `--color=WHEN`（always/never/auto）；`--no-color` 归一为 never

## 硬约束
- **默认路径逐字节兼容**：单文件 + 无新 flag 时 stdout/stderr/exit code 与改动前完全一致。
- 47 条命令矩阵：只允许 help 文本差异。
- `./test.sh` 基线：全绿 + 0 条 `+++ leak`。
- 任何行为变更 → 写 ADR 0004 + 同步 README + 更新 MEMORY 契约清单。

## 阶段

### P0 计划与基线
- [x] 读 AGENTS.md、krep README、现有 15 个生产文件
- [x] 核查 Odin API（`os.read_directory_by_path` / `os.is_dir` / `os.is_tty`）
- [x] 记录基线二进制到 `/tmp/xrep_krep_before`
- [x] 写 task_plan / findings / progress

### P1 目录遍历层（walk.odin，新文件）
- [ ] `glob_match(pattern, path)` 纯函数：`*`（不跨 `/`）、`**`（跨 `/`）、`?`、反斜杠转义；无 `/` 的模式只比 basename
- [ ] `walk_collect(roots, opts) -> [dynamic]string`：递归展开目录；跳过隐藏项（除非 `--hidden`）；不跟随目录符号链接；应用 `--exclude` / `--glob`
- [ ] 非递归时目录参数 → stderr 报错并跳过（不致命）

### P2 CLI 层（cli.odin）
- [ ] `Options` 新增字段：`recursive/globs/excludes/hidden/line_numbers/only_matching/max_count/json/stats/color_mode/list_files/patterns/pattern_file`
- [ ] `--flag=value` 拆分；短 flag 扩充（`-t -i -c -q -v -h -n -o -l -L -r -m -e -g`）+ 布尔捆绑
- [ ] `-e` 累积到 `patterns`；`-f FILE` 读模式（`-` = stdin）
- [ ] `--color=WHEN` 解析与校验；`--no-color` → never
- [ ] 帮助文本更新（含示例）

### P3 输出层（io_utils.odin / worker.odin / scan.odin）
- [ ] `build_line_index(data) -> []u64`（换行偏移表）；`line_of(index, offset)` 二分
- [ ] 行导向输出：多文件/`-r` 时 `path:line:offset`；单文件默认保持 `match offset: N`
- [ ] `-o` 追加命中字节 hex
- [ ] `-m` 同时约束流式打印与汇总截断
- [ ] `-l/-L` 抑制明细，扫描后按条件打印文件名
- [ ] `--json`：明细 JSON Lines / `--count` 时按文件；字符串转义
- [ ] `--stats` 汇总走 stderr

### P4 多模式（matcher.odin / common.odin）
- [ ] `Match_Ctx.extra: [][]u8`；`Match_Result.pat_len: u32`
- [ ] `multi_match`（按位置遍历模式表），`select_matcher` 感知多模式
- [ ] 单模式路径保持原算法（零性能变化）

### P5 入口编排（main.odin）
- [ ] 目录展开：把 `file_list` 经 `walk_collect` 转成真实文件列表
- [ ] stats 汇总；退出码沿用（dump 失败 → 1）

### P6 测试
- [ ] `walk_test.odin`：glob 正反例、隐藏项、递归/非递归、exclude
- [ ] `cli_test.odin`：新 flag、`=` 形式、短 flag 捆绑、互斥/错误分支
- [ ] `io_utils_test.odin`：行号表与二分边界
- [ ] 既有 77 用例保持全绿

### P7 验证与文档
- [ ] `odin check` / `./build.sh` / `./test.sh`（0 leak）
- [ ] 47 条矩阵回归：仅 help 文本差异
- [ ] 新增行为断言矩阵 `run3.sh`
- [ ] README 系统更新（新 flag、目录遍历、行导向、测试）
- [ ] ADR 0004；MEMORY 契约清单同步
