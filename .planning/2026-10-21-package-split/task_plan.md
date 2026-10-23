# task_plan.md — 按职责把根目录 .odin 拆到子目录包

## 目标

把 `/opt/repos/xrep/*.odin`（单 package main，26 个文件）拆成 4 个子目录包，
依赖方向单向：`main → app → engine → search → common`。功能零变化。

## Phase 0 — 可行性探测 ✅

结论（`/tmp/odinpkg`、`/tmp/pkg3`、`/tmp/pkg5` 实测）：

1. Odin 一个目录 = 一个 package，子目录是独立包。
2. **`import` 路径相对源文件所在目录**：`algo/matcher.odin` 里写 `import "common"`
   会去找 `algo/common` → 失败。所以兄弟包要么 `../common`，要么用 collection。
3. **collection 可用**：`odin build . -collection:xrep=.` + `import "xrep:common"`，
   `-collection:xrep=.` 相对路径有效。
4. **子包 `*_test.odin` 不再进入产品构建**（注入未定义符号后 `odin build .` 仍成功）。
   这是额外收益：现在单包结构下所有 `*_test.odin` 都被编进 `xrep`。
5. `odin test` 一次只接受一个路径 → 子包测试必须逐包跑。
6. `import l "lib"` 别名语法可用；`X :: l.X`（类型/proc 本地别名）也可用。

## Phase 1 — 解开 common → engine 的反向依赖 ✅

`common.odin:105` 的 `Match_Fn` 签名用了 `Progress`，而 `Progress` 定义在
`progress.odin`（将归入 engine）→ 循环。
处置：把 `Progress` 结构体定义移到 `common.odin`，`progress.odin` 只留 5 个函数。

## Phase 2 — git mv 分组 ✅

| 目录 | package | 文件 |
| --- | --- | --- |
| （根） | main | `main.odin` |
| `common/` | common | common |
| `search/` | search | matcher, merge, slice_utils |
| `engine/` | engine | task_pool, output_queue, progress, worker, io_utils |
| `app/` | app | cli, scan, walk, selftest, bench |

测试文件随源文件走（同包，可访问包内符号）。

## Phase 3 — package / import / 限定符 ✅

1. 改每文件的 `package main` → 对应包名（root 保持 main）。
2. 脚本生成「符号 → 包」映射，对非本包文件把独立引用改成 `pkg.Symbol`。
3. 按替换结果自动补 import；用编译器报的 unused/undefined 收尾。

## Phase 4 — 构建脚本 ✅

`build.sh` / `test.sh` / `Makefile` 三处加 `-collection:xrep=.`；
`test.sh` 改为逐包 `odin test`（根 + 4 个子包），用例总数须仍为 105。

## Phase 5 — 验证 ✅

- `./build.sh` 通过
- `./test.sh`：105 用例全绿、0 leak、0 bad free
- 47 条历史命令矩阵 vs 拆分前二进制：只许 help 文本差异
- `run2.sh` 27/27、`run3.sh` 43/43
- `make check` 交叉编译仍全绿（顺带试 wasm 目标是否因 `_test` 不再编入而可用）

## Phase 6 — 文档 ✅

- ADR 0006（包拆分）
- README「文件结构」重写 + 新增「包结构」小节
- `.workbuddy/memory/MEMORY.md` 同步
