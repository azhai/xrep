# 调研记录：krep 功能对齐

## krep 的完整 flag 清单（摘自 README）
`-i/--ignore-case`, `-c/--count`, `-o/--only-matching`, `-n/--line-number`,
`-A/-B/-C NUM`, `-l/-L`, `-q/--quiet`, `-e PATTERN`, `-f FILE`, `-m NUM`,
`-E`(POSIX ERE), `-F`(fixed), `-r/--recursive`, `--glob=`, `--exclude=`,
`--hidden`, `--gitignore`, `--algo=`, `-t/--threads=`, `-s STRING`,
`-w/--word-regexp`, `--json/--jsonl`, `--stats`, `--color[=WHEN]`,
`--no-simd`, `-v/--version`, `-h/--help`

## xrep 架构要点（影响实现方式）
- **模型是字节偏移**，不是行。命中即 `Match_Result{offset}`，输出 `match offset: N` + 可选 hex 上下文。
- 扫描链路：`main` → `scan_file` → `scan_region_parallel`（切 2MiB 分片入 Task_Pool
  → N 个 `worker_steal` → `Output_Queue` → 单个 `output_thread` 流式打印
  → 分片结果 `merge_ordered_matches` 归并）。
- `worker_steal` 的 `output_thread` 是**唯一打印者**，串行保证不交错。新增输出格式必须落在这里。
- 全局表：`lower_table` 走 `@(init) proc "contextless"`；`alg_table` 是编译期常量数组。
- 线程入口必须 `context = runtime.default_context()`（ADR 0003）。
- `matcher` 不得写 `context.allocator`，显式传 `mem.arena_allocator(arena)`。

## Odin API 核查结果
| 需要 | 可用 API |
| --- | --- |
| 列目录 | `os.read_directory_by_path(path, -1, context.allocator) -> ([]os.File_Info, os.Error)` |
| 判目录 | `os.is_dir(path)` / `os.is_directory(path)`（内部用 temp allocator，不泄漏） |
| 判文件 | `os.is_file(path)` |
| File_Info | `fullpath` / `name` / `size: i64` / `type: File_Type{Regular,Directory,Symlink,...}` |
| 判 TTY | `os.is_tty(f)`（`--color=auto` 用）；也可 `terminal.is_terminal` |
| 存在性 | `os.exists(path)`（**不要用 `os.stat(path, context.allocator)`**，会 clone 路径并泄漏） |
| 字符串 | `strings.contains / has_prefix / last_index_byte` |
| 无 `os2.walk` | 本机 Odin 无 `core:os/os2`，目录递归须自己写（故新增 walk.odin） |

## 设计决策
1. **glob 语义**：`*` 不跨 `/`，`**` 跨 `/`，`?` 单字符（非 `/`），`\` 转义；
   模式不含 `/` 时只与 basename 比较（`--glob='*.bin'` 能命中任意深度的 `.bin`）。
2. **兼容性红线**：单文件 + 无新 flag → 走原路径，输出逐字节不变。
   行号/路径前缀仅在「多文件 || `-r` || `-n`」时启用。
3. **`-m` 实现取舍**：流式打印与汇总都用同一个上限截断；
   **不做**提前中止扫描（krep 会）。理由：worker 已按分片入队，
   提前中止要引入跨线程取消协议，收益仅是不必要的 I/O；
   记 `ponytail:` 标注该上限。
4. **`-q`**：krep 语义是"仅退出码"，xrep 既有 `--quiet` 是"不打 stdout（dump 与 stderr 错误保留）"。
   取交集：`-q` 作为 `--quiet` 的短别名，不引入第二种语义。
5. **`-f FILE`**：模式来源为文件时，空行与非空行都算模式？——按 grep：每个非空行一个模式；
   注释掉的空行跳过。文件不存在 → 参数错误退出 1。
6. **`-e` 与位置模式**：给了 `-e` 时位置参数不再当模式（全部当文件），与 grep 一致。
7. **多模式匹配算法**：不做 Aho-Corasick（工作量大收益小），用按位置遍历模式表的
   `multi_match`；单模式仍走 `alg_table` 选定的原算法，性能零回退。

## 待确认的技术风险
- `merge_ordered_matches` 需稳定排序 + 多模式时同一 offset 可能重复（不同模式命中同一处）→
  保留重复（与既有"重叠窗口重复上报"契约一致），README 记录。
- 行号表 `[]u64` 内存 = 换行数 × 8B；仅在实际需要行号时构建。
