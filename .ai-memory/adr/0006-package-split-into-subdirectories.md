# ADR 0006：按职责拆分为子目录包（main / app / engine / search / common）

- 日期：2026-10-21
- 状态：已实施
- 关联：ADR 0001（模块拆分与缝隙）、ADR 0004（命中结果堆分配）、ADR 0005（krep 对齐）

## 背景

ADR 0001 把 `main.odin` 单文件拆成了 15 个**平铺在根目录**的文件，职责清楚了，
但目录仍然只有一个层级：26 个 `.odin`（含测试）挤在仓库根。问题：

1. 分层只存在于注释和文档里，编译器不知道 —— 谁能引用谁全靠自觉。
2. `git status` / 编辑器文件树里看不出"底层 / 上层"，新代码放错层不会被拦。
3. 根目录同时是 `package main`，任何新增文件都进同一个命名空间。

目标：让**目录结构本身**表达分层，并由编译器强制单向依赖。

## 决策

### 1. 四个子目录包（目录名即包名）

```
main.odin              package main    入口编排（根目录唯一的生产文件）
app/                   package app     CLI 解析与扫描编排：cli / scan / walk / selftest / bench
engine/                package engine   并发与 I/O 设施：task_pool / output_queue / worker / io_utils
search/                package search   匹配算法与归并：matcher / merge / slice_utils
common/                package common   类型、常量、进度条状态机：common / progress
```

依赖严格单向：`main → app → engine → search → common`。
跨包引用一律带包名限定：`common.Match_Ctx`、`search.select_matcher(...)`、
`engine.scan_region_parallel(...)`、`app.parse_args(...)`。
测试文件与源文件同包（`search/matcher_test.odin` 是 `package search`），
因此可以直接访问本包符号，不需要限定。

### 2. 兄弟包用 collection 引用，不用 `../`

Odin 的 `import` 路径是**相对源文件所在目录**解析的：
`search/matcher.odin` 里写 `import "common"` 会去找 `search/common`，直接报
`Path does not exist`。两条出路：

| 方式 | 写法 | 代价 |
| --- | --- | --- |
| 相对路径 | `import "../common"` | 构建命令不变；深层嵌套时 `../../x` 很难看 |
| **collection（采用）** | `import "xrep:common"` + `-collection:xrep=.` | import 干净；三个构建脚本各加一个 flag |

选 collection。`build.sh` / `test.sh` / `Makefile` 都已加好
（Makefile 用 `-collection:xrep=$(CURDIR)`，避免 `make -C` 时解析错位）。

### 3. `Progress` 类型下沉到 common（解开环）

`common.odin` 的 `Match_Fn` 签名是
`proc(data: []u8, ctx: Match_Ctx, progress: ^Progress)`，
而 `Progress` 原定义在 `progress.odin`（按原分层属于 engine）。
若照原样拆，common 就得 import engine，而 engine 依赖 search、search 依赖 common
——成环。

处置：**整个进度条模块下沉到 `common/progress.odin`**（类型 + 五个函数 +
`PROGRESS_MIN_INTERVAL` 已在 common）。理由：

- `Progress` 与 `Match_Fn` 的签名耦合，本来就该同层；
- 它是"数据 + 状态机"，不含 I/O 之外的上层概念，放底层不违和；
- 另一条路（把 `Match_Fn` 上移到 search）会让 search 反向成为 engine 的依赖上游，
  同样别扭。

### 4. 测试改为逐包执行

`odin test` 一次只接受一个路径：`odin test .` 只跑 main 包，
子包的 `*_test.odin` **不会执行**（实测输出 `No tests to run.`）；
`odin test . common algo` 会报 `Invalid flag`。
因此 `test.sh` 改为循环：`.`、`./common`、`./search`、`./engine`、`./app`。

用例数分布：common 10 / search 24 / engine 34 / app 61 = **129**（与拆分前一致）。
新增包必须同步加进 `test.sh` 的 `PACKAGES`，否则用例会被静默跳过。

### 5. 反向依赖有自动护栏

`make deps` 打印实际依赖图，并按白名单校验
（`common: 无`、`search: common`、`engine: common+search`、`app: common+engine+search`），
出现跨层/反向引用即报错退出。

## 后果

### 正面

- 编译器强制单向依赖：底层想引用上层会直接编译失败，不用靠 review 抓。
- 子包的 `*_test.odin` **不再进入产品构建**（实测：在子包测试文件里注入
  未定义符号后 `odin build .` 仍成功）。因此 `core:testing` 不再链进 `xrep`，
  生产代码里已无任何非测试文件 `import "core:testing"`。
- 目录树本身即是文档。

### 负面 / 注意

- 跨包引用变啰嗦（`common.Match_Ctx` 而非 `Match_Ctx`）。这是"分层真实"的代价，
  也是它的证据。
- 三个构建入口都必须带 `-collection:xrep=.`，忘了会报 `Path does not exist`。
- 测试必须逐包跑，少跑一个包不会报错、只会少跑用例（已用 `make deps` + 
  test.sh 的 `PACKAGES` 显式化来降低风险）。

## 验证

- `./verify.sh` 全绿：129 个单元用例（逐包）、内建自检、
  78 条历史命令 golden 矩阵、run2 34 条、run3 56 条断言。
- `make deps`：依赖方向单向，无反向引用。
- `make`（10 个交叉平台）全部构建成功，`make check` 格式正确。
- golden 矩阵与拆分前**逐字节一致**（拆分前二进制另存为基线对跑）。
- **复现测试**（见下节）：只用 `tools/odin_qualify.py` + 机械搬运，从 git HEAD
  重新走一遍拆分，产物一次编译通过且 `./verify.sh` 全绿——
  证明拆分过程本身是可重复、可验证的，而不是一次性手工操作。

## 迁移中踩到的两个坑（别的 Odin 项目也会遇到）

1. **字符串字面量会被批量替换误伤。** 用正则加包名前缀时，
   `fmt.println("OK slice_map")` 里的 `slice_map` 会被改成 `"OK search.slice_map"`，
   直接破坏 golden。同理，去掉包内自引用前缀时
   `"xrep GET app.log --json --stats"` 里的 `app.` 会被当成自引用删掉，变成
   `"xrep GET log --json --stats"`。**替换脚本必须跳过字符串与整行注释。**
2. **顶层全局变量不在 `Name ::` 形式里。** `lower_table: [256]u8` 用的是 `:`，
   只用 `::` 抓符号表会漏掉它，编译时报 `Undeclared name: lower_table`。
   抓声明要同时匹配 `::` 与 `:`。

## 两个坑的修复：`tools/odin_qualify.py` + 静态护栏

上面两条是**方法论缺陷**，不是一次性事故——只要再批量改一次就会复发。因此没有
停留在"下次小心"，而是把正确做法固化成工具和常驻检查。

### 工具（`tools/odin_qualify.py`，Python 3.8+ 标准库）

| 子命令 | 作用 |
| --- | --- |
| `qualify` | 加包名前缀，并按实际用到的前缀同步 `import "xrep:..."`（默认 dry-run 打 diff，`--write` 落盘） |
| `strip-self` | 去掉本包自引用前缀 |
| `symbols` | 打印各包顶层声明（供人核对） |
| `check-literals` | 护栏：字符串里出现 `<包>.<该包已知符号>` 即报错 |
| `selftest` | 28 项内置回归，含"旧错误做法确实会改坏"的反向断言 |

两条坑各自的修复点：

- **坑 1 → 词法感知。** 先把源码切成「非 code 区间」：双引号字符串、反引号
  raw string、字符字面量、`//` 行注释、`/* */` 块注释全部按区间屏蔽，替换只作用
  于 code。字符串里的内容根本不会进入替换函数，物理上改不到。
- **坑 2 → 声明提取认三种形式。** `name ::` / `name :=` / `name :`（非 `::`），
  且要求行首是 code、花括号深度为 0（否则 struct 字段会混进来）。

安全取向是不对称的：**过度限定会静默改坏数据，漏限定只会在编译期大声报错**。
所以凡有歧义一律不动——成员访问之后、`@(attr)` 内、`#directive` 之后、
`package`/`import` 之后、Odin 关键字、`context`，以及花括号/圆括号内的
`ident:` / `ident =`（结构体字段、字面量字段、proc 参数名）。

### 复现测试又抓出两个真 bug

写完之后做了一次终审：**只用这个工具 + 机械搬运，从 git HEAD 重新复现整个拆分**，
再跑完整验收。结果第一版工具编译不过，暴露了两个 selftest 没覆盖的问题：

1. **保护按"名字"记录会连累同名的其它用法。** `data_b[b + CHUNK_OVERLAP:]`
   是**切片**，那里的冒号被当成字段分隔符，于是 `CHUNK_OVERLAP` 整个名字被保护，
   同一文件里 `fmt.aprintf(..., CHUNK_OVERLAP)` 这种正常用法也跳过了限定。
   改成**按位置**保护，并且方括号内的冒号不算字段分隔。
2. **局部变量与包全局同名会被误加前缀。** `main.odin` 里有 `scan_opts := ...`
   （局部）撞上 app 包的全局 `scan_opts`，被改成 `app.scan_opts`。
   增加"局部变量名"收集，只在真的撞名时才按名字保护。

修完之后复现成功：从 HEAD 出发，`qualify --write` 之后一次编译通过，
`./verify.sh` 全绿（129 单元用例 + 78 golden **与拆分前逐字节一致** + 34 + 56）。
这两个用例都已进 selftest，标注为"复现测试抓到的 bug"。

### 常驻护栏

- `tools/guard.sh`：工具自检 → 字面量污染检测 → `make deps` 包依赖方向。
- 已接为 `verify.sh` 的第 0 层（`make guard` 也可单独跑）。
- 判别式设计让误报率极低：只有点号后面的名字**确实是某包的顶层声明**时才报警，
  所以帮助文本里的 `"xrep GET app.log"` 不会误报。确需放行时往
  `tools/literal_allowlist.txt` 加正则（当前为空）。

