# progress.md — lib 整合执行日志

## 2026-10-24

### 决策（用户确认）

1. common 归属 = **合并进 lib**（删除 common 目录）
2. 容器范围 = **类型 + 操作都进 lib**

### 执行

| 步骤 | 命令 / 动作 | 结果 |
| --- | --- | --- |
| 建包 | `git mv common lib` + `git mv engine/{task_pool,output_queue}*.odin lib/` | OK |
| 抽类型 | 新建 `lib/options.odin`（Options/Scan_Options/Walk_Options/List_Mode/Parse_Outcome） | OK |
| package | python 改 lib/\*.odin 首行为 `package lib` | OK |
| 改名 | 一次性脚本 `/tmp/rename_common_to_lib.py`（复用工具 Source，词法感知） | 16 文件 |
| 前缀 | `qualify --packages lib search engine app --write` | 11 文件 |
| 补一步 | `/tmp/retarget_to_lib.py engine` 再 `app` | 各 1 文件 |

### 踩到的坑（新）

**`qualify` 只处理裸名，管不到"已带旧包前缀"的引用。**
`app/scan.odin` 里原本就是 `engine.task_pool_push(&tp, engine.Scan_Task{...})`
（`Scan_Task` 那时属于 engine）。类型搬到 lib 后，这些引用仍是 `engine.` 前缀，
qualify 认为"点号后是成员访问"而跳过 → 编译报
`'Scan_Task' is not declared by 'engine'`。
处置：按"lib 的声明集"做一次 `engine.X` / `app.X` → `lib.X` 的词法感知改写。
**结论：符号搬家 ≠ 加前缀，两种改写都要跑。**

### 验证

- `./build.sh` 一次通过
- `./test.sh`：129 用例全绿，0 leak；逐包 lib 19 / search 24 / engine 25 / app 61
- `./verify.sh`：护栏 28 项 + golden 78 + run2 34 + run3 56 全绿

### 同步改动

`test.sh`（PACKAGES）、`Makefile`（deps 白名单 + VERSION grep 路径 + 注释）、
`build.sh` / `tools/guard.sh`（注释）、`tools/odin_qualify.py`
（DEFAULT_PACKAGES + selftest fixture 包名改 lib）、`tests/run.sh`（注释）、
README（包结构树 / 文件表 / 测试表 / 命令示例 / ADR 清单）、新增 ADR 0007。
