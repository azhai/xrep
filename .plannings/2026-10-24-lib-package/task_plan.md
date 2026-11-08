# task_plan.md — 整合数据结构，统一放入 lib 包

## 目标

新建 `lib/` 包（`package lib`），收纳**全部共享数据结构 + 常量 + 容器实现**；
现有 `common` 包并入 lib 后删除。app/engine 里的共享类型下沉到 lib。
功能零变化：129 单元用例 + 78/34/56 条 golden 矩阵必须逐字节全绿。

新的依赖方向（单向，无环）：

```
main → app → engine → search → lib
```

（engine 仍依赖 search + lib；app 依赖 engine + search + lib）

## 用户已确认的两个选择

1. **common 归属** = 合并进 lib（类型/常量/s2b/clamp/progress 函数全进 lib，删 common 目录）
2. **容器范围** = 类型 + 操作都进 lib（Task_Pool / Output_Queue 连同 init/push/pop/destroy）

## Phase 1 — git mv 建包 ✅

- `common/` → `lib/`（4 文件：common, common_test, progress, progress_test）
- `engine/task_pool.odin|task_pool_test.odin|output_queue.odin|output_queue_test.odin` → `lib/`

## Phase 2 — 抽出 lib/options.odin ✅

从 app 抽出共享数据定义（这些是"数据"，不是行为）：

| 类型 | 原位置 |
| --- | --- |
| `List_Mode` | app/cli.odin:45 |
| `Options` | app/cli.odin:58 |
| `Parse_Outcome` | app/cli.odin:97 |
| `Scan_Options` | app/scan.odin:36 |
| `Walk_Options` | app/walk.odin:127 |

## Phase 3 — package 声明改 lib ✅

`package common` → `package lib`；搬来的 engine 文件 `package engine` → `package lib`。

## Phase 4 — 限定符重写（用 tools/odin_qualify.py，不手写正则）✅

1. lib 包内剥掉 `common.` 自引用前缀 + 同步删 import
2. `qualify --packages lib search engine app --write`：给 search/engine/app/main
   加 `lib.` 前缀并同步 `import "xrep:lib"`

## Phase 5 — 编译与验收 ✅

`./build.sh` → `./test.sh` → `./verify.sh`（含第 0 层静态护栏）

## Phase 6 — 周边同步 ✅

- `test.sh`：`PACKAGES=(. ./lib ./search ./engine ./app)`
- `Makefile` deps：`lib:` `search:lib` `engine:lib search` `app:lib search engine`
- `tools/odin_qualify.py`：`DEFAULT_PACKAGES` 改 lib；selftest 的 fixture 包名
  `common` → `lib`（否则 import 同步断言会失败）
- `build.sh` / `test.sh` / `tools/guard.sh` 注释里的 common → lib
- README：文件路径表、包结构、`-collection` 命令、静态护栏章节
- 新增 ADR 0007（数据结构整合进 lib）
- `.workbuddy/memory/`：日志 + 契约/约定更新

## 风险与对策

| 风险 | 对策 |
| --- | --- |
| 批量加前缀误伤字符串字面量 | 只用 odin_qualify.py（词法感知）+ verify.sh 第 0 层 check-literals |
| 漏限定导致 Undeclared | 声明提取认 `::`/`:=`/`:` 三种形式（工具已修） |
| 行为被改动 | golden 矩阵 78 条逐字节比对；不改任何逻辑，只搬类型 |
| selftest fixture 与新包名不一致 | 一并改名并跑 `make guard` |
