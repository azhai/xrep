# ADR 0001: main.odin 按职责拆分，并引入两处可测试性缝隙

## Status
Accepted

## Context

`main.odin` 单文件 966 行，同时包含：入口编排、命令行解析、匹配算法与选择表、
泛型切片工具、多路归并、四个并发设施（任务池 / arena 池 / 输出队列 / 进度条）、
两个线程主体、文件 I/O 与 dump、单文件扫描编排、内建自检、微基准。

由此带来三个具体问题：

1. **无法单独测试任何逻辑**：`parse_args` 直接调用 `os.exit`；上下文窗口的
   边界算术与 hex 渲染耦合在同一个会写 stdout 的函数里；扫描编排与并发设施
   混在一起，无法在不启动线程的情况下断言核心判定。
2. **改动风险高**：任何一处编辑都在 966 行的同一作用域内，符号可见性无法约束
   依赖方向（底层设施可以反向调用上层编排）。
3. **认知成本高**：新人（含后续 agent）需要通读全文才能定位"进程退出策略在哪"
   "算法选择表在哪"。

约束：**运行行为必须与拆分前完全一致**，包括输出文本、退出码与既有怪异行为
（见 README "已知行为与限制"）。

## Decision

1. 按职责拆为 15 个生产文件，依赖单向：
   `main` → 编排（`cli`/`scan`/`selftest`/`bench`）→ 设施（`*_pool`/`output_queue`/
   `progress`/`worker`/`io_utils`）→ 算法与工具（`matcher`/`merge`/`slice_utils`）→ `common`。
   拆分只做移动与加注释，函数名、签名、字段名、默认值、输出文本、退出码一律不变。
2. **缝隙一 — CLI 解析**：`parse_args` 从"解析 + 退出"改为纯解析，返回
   `(Options, Parse_Outcome, message)`；`os.exit` 策略上移到 `main`。
   `--help` 的"即时退出"语义用 `.Help` 三态保留。
3. **缝隙二 — 上下文窗口算术**：把 `print_context` 内的起点/终点夹取抽为纯函数
   `context_range(file_len, offset, pat_len, ctx)`，`print_context` 改为调用它，
   hex 渲染逻辑不动。
4. 新增 `*_test.odin` 覆盖各核心模块与上述两处缝隙；新增 `test.sh` 固化
   `ODIN_CC` / `-linker:lld` / `ODIN_TEST_TRACK_MEMORY=false` 三个必需参数。

## Consequences

**变得更容易**：CLI 的 10 个用例（含全部错误分支与 `--help` 即时性）与
`context_range` 的全部边界现在可确定性单测；依赖方向由文件边界约束；
定位"某能力在哪"由文件名直接给出；新增算法只需改 `alg_table` 一行。

**变得更难**：跨文件阅读比单文件内滚动多一步跳转；`_test.odin` 在当前 Odin
版本会被普通构建一并编译，测试代码必须始终保持可编译。

**接受的取舍（ceiling）**：

- 不修改任何既有怪异行为（分片重叠窗口重复命中、`--limit` 丢前 2 条、
  `--no-color` 为 no-op、`bndm_match` 委托 `naive_match`）。它们是兼容性契约的一部分，
  已在 README 显式记录；如需修正应另开 ADR 并同步更新行为矩阵。
- 测试运行器的内存追踪被关闭（`test.sh` 内置）。追踪分配器不适配被测代码的
  worker 线程并发分配，开启会产生偶发 SIGBUS 与误导性 leak 告警；
  被测代码的进程生命周期分配泄漏是既有设计，不在本次范围。
- 行为等价性的证据是"47 条命令 × (stdout, stderr, exit code) 的零差异 diff"，
  不是"功能正确性证明"。它证明的是**重构未改变可观察行为**，不证明原实现无缺陷。

## Verification（记录实际验证到的范围）

- `./build.sh` 成功；`odin check .` 无告警。
- `diff -r base new` 为空（47 条命令 × 3 类产物）。
- `./test.sh`：59/59 单元测试通过 + 内建自检全绿；另以按名隔离方式
  验证 cli / matcher / scan 三组可独立运行。
- `./xrep --bench` 正常输出三种算法的吞吐量。
