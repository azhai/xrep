# ADR 0007：整合数据结构，统一放入 `lib` 包

- 日期：2026-10-24
- 状态：已实施
- 关联：ADR 0006（子目录包）、ADR 0004（命中结果堆分配）、ADR 0005（krep 对齐）

## 背景

ADR 0006 按"职责"把代码拆成 4 个子目录包，分层由编译器强制了，但**数据**仍然
跟着**某个消费者**走：

| 类型 | 原位置 | 实际的消费者 |
| --- | --- | --- |
| `Options` / `List_Mode` / `Parse_Outcome` | `app/cli.odin` | main、scan、walk、selftest、bench |
| `Scan_Options` | `app/scan.odin` | main、scan、bench、测试 |
| `Walk_Options` | `app/walk.odin` | main、walk |
| `Scan_Task` / `Task_Pool` | `engine/task_pool.odin` | scan、worker |
| `Output_Item` / `Output_Queue` | `engine/output_queue.odin` | scan、worker |

后果是"数据住在上层，下层要用就得反向依赖"。当时靠两处妥协绕开：

- `Progress` 是 ADR 0006 里唯一被**下沉**的类型（为了解 common → engine 的环），
  其余类型并没有一起处理；
- 容器（`Task_Pool` / `Output_Queue`）连同操作函数留在 `engine`，于是"容器"这个
  与业务无关的基础设施被钉在了并发层。

同时 `common` 这个名字本身也不准确：它既是"底层类型 + 常量"，又是"进度条函数"，
与 `lib` 相比缺少"这是全工程共享的数据与容器"的语义。

## 决策

### 1. 新建 `lib` 包：全部共享数据结构 + 容器实现都在这一层

```
lib/    package lib    base.odin（常量/共享类型/字节工具）
                       options.odin（Options / Scan_Options / Walk_Options / List_Mode / Parse_Outcome）
                       task_pool.odin（Scan_Task + Task_Pool 及 init/push/pop/destroy）
                       output_queue.odin（Output_Item + Output_Queue 及 init/push/pop/destroy）
                       progress.odin（进度条操作；类型在 base.odin）
```

- 原 `common/` 整体并入 `lib/`（目录删除）。为消除 `common` 这个残留命名，
  `common.odin` → `base.odin`、`common_test.odin` → `base_test.odin`。
- 容器**连操作一起**下沉：容器与其操作是一体的，拆开只会有一半在底层、
  一半在上层，反而更容易长出反向依赖。
- `lib` 不引用任何本工程包，是依赖图的**唯一根**。

### 2. 依赖链收敛为一条

```
main → app → engine → search → lib
```

`engine` 只留真正的并发与 I/O 设施（`worker` / `io_utils`）。

### 3. 「数据」与「行为」的归属判据

写进 `lib/options.odin` 的只有 struct / enum，一行行为代码都没有：

- 解析 → `app/cli.odin`（`parse_args`）
- 扫描编排 → `app/scan.odin`（`scan_file`）
- 目录遍历 → `app/walk.odin`（`walk_expand`）

判据：**被两个以上模块引用的类型，且其行为只在一个模块里** → 类型进 `lib`，
行为留在那个模块。容器例外：操作与类型同属一个抽象，一起进 `lib`。

### 4. 实施手法：机械搬运 + 工具改写，不手写正则

1. `git mv` 保历史（含测试文件随源文件走，保持同包可访问包内符号）。
2. `package` 声明改名。
3. 限定符改写全部走 `tools/odin_qualify.py`（词法感知）：
   - `common.` → `lib.`（一次性脚本，复用工具的 `Source` 屏蔽字符串/注释）；
   - 已搬家的符号身上的旧包前缀 `engine.X` / `app.X` → `lib.X`
     （`qualify` 只处理**裸名**，管不到已带前缀的引用 —— 这是本次补的一步）；
   - `qualify --write` 补裸名前缀并同步 `import "xrep:lib"`。

### 5. 工具与护栏同步

- `tools/odin_qualify.py`：`DEFAULT_PACKAGES` 改 `lib`；selftest 的 fixture 包名
  同步改 `lib`（否则 `sync_imports` 的"删掉未使用 import"断言会因为包名不在
  已知集合里而失败）。28 项自检仍全绿。
- `Makefile deps` 的白名单改 `lib:` / `search:lib` / `engine:lib search` /
  `app:lib search engine`，并打印实际依赖图。
- `test.sh` 的 `PACKAGES` 改 `. ./lib ./search ./engine ./app`。

## 验证

- `./build.sh` 一次通过。
- `./test.sh`：129 个用例全绿、0 条 `+++ leak` / `bad free`
  （逐包 lib 19 / search 24 / engine 25 / app 61；main 包无用例）。
- `./verify.sh`：第 0 层静态护栏（28 项工具自检 + 字面量污染 + 依赖方向）、
  78 条 golden 矩阵、run2 34 条、run3 56 条**全部通过，与整合前逐字节一致**。
- 工具幂等：整合后再跑 `qualify` / `check-literals` 均报"无需改动"/
  "没有污染"。

## 影响

**对外行为零变化** —— 本次只搬类型与常量，没有改任何逻辑；输出文本、退出码、
dump 内容全部由 golden 矩阵锁定。

收益：

1. 依赖图最底层只有一个包，新增消费者不会引出反向依赖。
2. 「数据结构在哪」有了唯一答案：`lib`。上层只有行为。
3. 容器与业务解耦，将来换调度策略（例如改成无锁队列）只动 `lib/task_pool.odin`。
