xrep
-----

Odin 语言写的 grep，复刻自 krep 。

多线程（工作窃取任务池）二进制模式搜索：按模式长度自动选择匹配算法，
命中偏移可过滤、可着色展示上下文、可落盘为 dump 文件；
并已对齐 krep 的主要用法：**目录递归遍历（`-r`）**、glob 过滤/排除、
多模式（`-e`/`-f`）、行号与行导向输出（`-n`）、只列文件名（`-l`/`-L`）、
命中字节（`-o`）、每文件上限（`-m`）、JSON Lines（`--json`）与运行统计（`--stats`）。

当前版本 `0.3.0`。

---

## 构建

```bash
./build.sh              # 产出 ./xrep
OPT=speed ./build.sh    # 可选优化级别: -o:none|minimal|size|speed（默认 size）
OUT=xrep2 ./build.sh    # 自定义输出名
```

`build.sh` 会强制 `ODIN_CC=/usr/bin/clang` 并加 `-linker:lld` 与
`-collection:xrep=.`（源码是子目录包，兄弟包靠 collection 互相引用，见下节）。
原因：本机 PATH 里的 `clang` 可能被 Android NDK 的 x86_64 clang 抢先占用，
导致 Odin 链接阶段报 `unknown file type *.o`。手工编译时请自行带上同样参数。

等价的手工命令：

```bash
ODIN_CC=/usr/bin/clang odin build . -collection:xrep=. -o:size -linker:lld -out:xrep
```

## 交叉编译

`Makefile` 负责把 xrep 编到其它平台，产物落在 `dist/`：

```bash
make               # 全部主流 + 扩展平台（默认 = all）
make main          # 五大主流：darwin x2 / linux amd64+arm64 / windows amd64
make host          # 只编当前机器平台
make extra         # linux 386 / arm / riscv64，freebsd amd64+arm64
make musl          # Linux 静态变体（musl，不依赖目标机 glibc 版本）
make universal     # macOS universal2（arm64 + amd64 用 lipo 合并）
make check         # 用 file(1) 核对每个产物的真实格式
make list          # 打印平台表
make guard         # 静态护栏：重构工具自检 + 字面量污染检测 + 包依赖方向
make clean         # 清掉 dist/ 与 .build/
```

产物命名 `xrep-<os>-<arch>`（Windows 带 `.exe`）。

### 为什么需要 zig

Odin 的原生链接器在本机只能链接**本机平台**和 `darwin_amd64`（走 macOS SDK）；
对 `linux_*` / `windows_*` 会直接报
`Linking for cross compilation for this platform is not yet supported`。

因此 Makefile 分两条路：

| 路线 | 覆盖 | 做法 |
| --- | --- | --- |
| A | `darwin_arm64` / `darwin_amd64` | odin 原生链接（`-linker:lld`），不需要 zig |
| B | 其余全部平台 | odin 只编译（`-build-mode:obj`），再用 `zig cc -target <triple>` 链接 |

zig 自带各平台 libc 与 Windows 导入库，因此不需要 sysroot，也不需要真的
Windows SDK（Makefile 只给一个空目录应付 odin 的 `-windows-sdk-root` 检查）。

### 两个 Windows 特异补丁

Odin 产出的 COFF 目标文件会引用两个 mingw 未提供的符号，Makefile 已处理，
改动链接方式时别漏掉：

- `BCryptGenRandom` —— Odin runtime 的随机源 → 加 `-lbcrypt`。
- `_fltused` —— MSVC 的浮点使用标记，mingw 无定义 → Makefile 现编译一个
  空符号垫片 `int _fltused = 0x9875;` 一起链接。

### 平台表

| 短名 | odin target | zig triple |
| --- | --- | --- |
| `darwin-arm64` | `darwin_arm64` | （原生链接） |
| `darwin-amd64` | `darwin_amd64` | （原生链接） |
| `linux-amd64` | `linux_amd64` | `x86_64-linux-gnu` |
| `linux-arm64` | `linux_arm64` | `aarch64-linux-gnu` |
| `windows-amd64` | `windows_amd64` | `x86_64-windows-gnu` |
| `linux-386` | `linux_i386` | `x86-linux-gnu` |
| `linux-arm` | `linux_arm32` | `arm-linux-gnueabihf` |
| `linux-riscv64` | `linux_riscv64` | `riscv64-linux-gnu` |
| `freebsd-amd64` | `freebsd_amd64` | `x86_64-freebsd-none` |
| `freebsd-arm64` | `freebsd_arm64` | `aarch64-freebsd-none` |
| `linux-amd64-musl` | `linux_amd64` | `x86_64-linux-musl`（静态） |
| `linux-arm64-musl` | `linux_arm64` | `aarch64-linux-musl`（静态） |

### 已知限制

- **`windows_i386` 不提供**：Odin 对 i386 Windows 会关掉 TLS，但生成的
  `__tls_index` 与 mingw 的 `tlssup.obj` 冲突（duplicate symbol）。
- **wasm 目标不提供**：与本次拆分无关，是 Odin 上游自身的编译错误——
  `wasi_wasm32` 挂在 `core/terminal/internal_os.odin` 的 `_fini_terminal` 未声明，
  `js_wasm32` 挂在 `core:testing` 的 `log.do_level_header` 未声明。等上游修复后再加。
  （拆分前是同一个错误，不是新引入的。）
- **版本匹配**：已在 odin `dev-2026-10`、zig `0.17.0` 上验证。zig 0.17 起
  i386 的架构名是 `x86`（旧名 `i386` 会报 unknown architecture）。
- **验证深度**：所有产物均通过 `file(1)` 格式核对，darwin 产物实际运行过
  `--version` / `--test`；非本机平台只做到"链接成功 + 格式正确"，未在真机执行。

## 用法

```bash
./xrep <模式> [文件/目录...] [标志]
```

位置参数说明：默认第一个非空位置参数是**模式**，其余是**输入路径**。
一旦用了 `-e/--pattern` 或 `-f/--file`，**所有**位置参数都被当作输入路径
（不再消费模式位），因此 `xrep -e foo -e bar dir1 dir2` 是合法的。

### 匹配

| 标志 | 说明 |
| --- | --- |
| `-i`, `--ignore-case` | 大小写不敏感匹配 |
| `-e`, `--pattern P` | 追加一个模式（可重复 → 多模式） |
| `-f`, `--file F` | 从 F 逐行读取模式（空行忽略） |
| `--after N` | 只保留偏移 ≥ N（接受 `0x` 十六进制） |
| `--before N` | 只保留偏移 ≤ N（接受 `0x` 十六进制） |
| `-m`, `--max-count N` | 每文件最多报告 N 条（`0` = 不限） |
| `--limit N` | 限制 pretty 汇总条数（`0` = 不限制；不影响 `--count`/`--dump`） |

### 检索范围

| 标志 | 说明 |
| --- | --- |
| `-r`, `--recursive` | 递归搜索目录（不传 `-r` 时目录会被拒绝并提示） |
| `-g`, `--glob G` | 只扫描匹配 G 的文件（可重复；`*` 不跨 `/`，`**` 跨 `/`，`?` 单字符） |
| `--exclude G` | 跳过匹配 G 的文件或目录（可重复） |
| `--hidden` | 收录隐藏文件/目录（默认跳过 `.` 开头项） |
| `--max-size N` | 跳过大于 N 字节的文件（读入前先探测大小，不会先 OOM） |
| `-t`, `--threads N` | worker 线程数（默认 4；**自动夹到 `1 .. 逻辑核心数×4`**） |

### 输出

| 标志 | 说明 |
| --- | --- |
| `-c`, `--count` | 只输出每文件命中总数 |
| `-n`, `--line-number` | 附带 1-based 行号 |
| `-o`, `--only-matching` | 额外以 hex 打印命中到的字节 |
| `-l`, `--files-with-matches` | 只列有命中的文件名 |
| `-L`, `--files-without-match` | 只列没有命中的文件名 |
| `--context N` | 每条命中额外以 hex 展示前后各 N 字节，命中字节红色高亮 |
| `--offset-hex` | 偏移以十六进制打印 |
| `--json`, `--jsonl` | 每行一个 JSON 对象（JSON Lines） |
| `--color WHEN` | `always` \| `never` \| `auto`（默认 `always`；`auto` 按 stdout 是否 TTY 判定） |
| `--stats` | 扫描结束后把汇总统计写 **stderr** |
| `-q`, `--quiet` | 静默：不输出统计与进度，仅保留 dump 与 stderr 错误 |

### 落盘与其它

| 标志 | 说明 |
| --- | --- |
| `--dump FILE` | 把（过滤后的）所有命中偏移写入单个文件 |
| `--dump-prefix P` | 按文件分别落盘到 `P{清洗后的文件名}.txt`（见"已知行为"） |
| `--dump-append` | dump 改为追加写（默认覆盖） |
| `--skip-empty` | 命中 0 条时不产出 dump 文件（默认会产出空文件） |
| `--no-color` | 已接受但**无效果**（见"已知行为"；请用 `--color never`） |
| `--test` | 运行随二进制分发的内建自检 |
| `--bench` | 运行微基准：A 组匹配算法吞吐（模式长度 / 大小写 / 多模式），B 组端到端并行扫描的 1/2/4/8 线程伸缩 |
| `-v`, `--version` | 打印版本并立即退出（其后的参数不再解析） |
| `-h`, `--help` | 打印帮助并立即退出（其后的参数不再解析） |

短标志可捆绑（`-rn` = `-r -n`），带值的短标志可直接相连（`-t8`、`-m10`）。
长标志支持 `--threads=8` 等号形式。

### 输出模型：偏移导向 vs 行导向

- **单文件且不带 `-n`/`-o`/`-m`/`--json`/`-l`/`-L`** → 沿用历史格式
  `match offset: N` + `=== <file>: N results ===`，逐字节兼容（回归护栏）。
- **多文件或 `-r`** → 行导向 `path:line:offset`；加了 `-n` 但单文件时为 `line:offset`。
- `--count` / `-l` / `-L` / `--quiet` 只输出结论行（不打命中明细）；
  `--json` 时命中明细每行一个 JSON 对象。
- 部分噪声输出（进度条）只在"传统偏移导向"模式下开启，避免破坏管道消费。

### 退出码与汇总

退出码：`0` 正常完成（含"文件不存在"这类已报告但不致命的错误）；
`1` 参数错误，或**任一 dump 落盘失败**。

多文件扫描完成后会多打印一行 `Scanned N files, total hits: M`（受 `--quiet`
抑制；单文件时不打印）。`--stats` 的统计行固定写 stderr，**不受 `--quiet` 抑制**。

## 包结构（子目录即 package）

源码按职责拆成 4 个子目录包，依赖方向**严格单向**：

```
main.odin              package main    入口编排（根目录唯一的生产文件）
├── app/               package app     CLI 解析与扫描编排
│   ├── cli.odin       └── 依赖 lib / engine / search
│   ├── scan.odin
│   ├── walk.odin
│   ├── selftest.odin
│   └── bench.odin
├── engine/            package engine   并发与 I/O 设施
│   ├── worker.odin    └── 依赖 lib / search
│   └── io_utils.odin
├── search/            package search   匹配算法与归并
│   ├── matcher.odin   └── 仅依赖 lib
│   ├── merge.odin
│   └── slice_utils.odin
└── lib/               package lib      **全部共享数据结构 + 容器**（不依赖任何本工程包）
    ├── base.odin          常量、共享类型、字节工具
    ├── options.odin       Options / Scan_Options / Walk_Options / List_Mode / Parse_Outcome
    ├── task_pool.odin     Scan_Task + Task_Pool（含 init/push/pop/destroy）
    ├── output_queue.odin  Output_Item + Output_Queue（含 init/push/pop/destroy）
    └── progress.odin      进度条操作（类型在 base.odin）
```

跨包引用一律带包名限定：`lib.Match_Ctx`、`search.select_matcher(...)`、
`engine.scan_region_parallel(...)`、`app.parse_args(...)`。测试文件与源文件同包，
可以直接访问本包符号（无需限定）。

**数据结构集中在 `lib`（ADR 0007）**：所有跨模块流转的类型（匹配上下文/结果、
选项、任务、输出项、进度条）与运行期常量都在 `lib`，各包只保留行为代码。
于是依赖图的最底层只有一个包，新增消费者不会引出反向依赖。

三个必须知道的 Odin 包机制（详见 ADR 0006）：

1. **一个目录 = 一个 package**，子目录是独立包，不能隐式共享符号。
2. **`import` 路径相对源文件所在目录解析**。`search/matcher.odin` 里写
   `import "lib"` 会去找 `search/lib`。因此兄弟包一律用 collection：
   `import "xrep:lib"`，构建时带 `-collection:xrep=.`（build.sh/test.sh/Makefile
   已经加好，手工编译别漏）。
3. **`odin test` 一次只接受一个路径**。`odin test .` 只跑 main 包，子包的
   `*_test.odin` 不会执行。所以 `test.sh` 逐包跑：`.`、`./lib`、`./search`、
   `./engine`、`./app`。新增包时记得加进 `test.sh` 的 `PACKAGES`。

反向依赖有自动护栏：`make deps` 打印依赖图，并在出现跨层/反向引用时报错退出
（已并入 `make guard` / `verify.sh` 第 0 层，见下文「静态护栏」）。

### 生产代码（16 个文件，约 2600 行含注释）

| 文件 | 职责 |
| --- | --- |
| `main.odin` | 入口编排：解析参数 → **夹取线程数** → 分派子命令 → **目录展开（`walk_expand`）** → 逐文件扫描 → **汇总统计 → 释放 `file_list`/`Options` → 决定退出码**。全局表初始化已移出（见 `lib`/`matcher`） |
| `lib/base.odin` | **运行期常量**（分片大小/重叠窗口/进度刷新间隔/线程上限/版本号）、`lower_table`（**`@(init)` 启动时自动填充**）、`clamp_thread_count`、共享类型（`Progress`/`Match_Ctx`/`Match_Result`/`Match_Fn`/`Algorithm_Entry`/`Color_Mode`/`Run_Stats`）、`s2b` |
| `lib/options.odin` | **纯数据**：`Options`（CLI 解析结果）、`Scan_Options`（一次扫描的选项）、`Walk_Options`（目录遍历选项）、`List_Mode`、`Parse_Outcome`。无行为代码 —— 解析在 `app/cli.odin`，编排在 `app/scan.odin`，遍历在 `app/walk.odin`（ADR 0007） |
| `lib/task_pool.odin` | 扫描任务池：`Scan_Task` + Mutex 保护的动态数组，含 `init/push/pop/destroy`，供 worker 抢占 |
| `lib/output_queue.odin` | 生产者/消费者输出队列：`Output_Item` + `Output_Queue`，Mutex + Cond，`done` 标志驱动消费者退出。**内部是环形缓冲**（head/count 游标，O(1) 出队；ADR 0008） |
| `lib/progress.odin` | 进度条操作（`\r` 原地刷新 + 限流，`--quiet` 或非传统输出模式时整体关闭）；类型定义在 `base.odin` |
| `app/cli.odin` | `parse_args`（纯解析，不含退出策略；`file_list` **按需分配、调用方负责 `options_destroy`**）、`normalize_args`（`--k=v`、`-t8`、`-rn` 归一化）、短标志别名、`read_pattern_file`、`max_threads_for_machine`、`print_help`/`print_version` |
| `search/matcher.odin` | `single_match`（SIMD 跳跃 + 密集段就地消费）/ `memchr_match`（首字节 SIMD 预筛 + 倒序验证）/ `naive_match`（兜底）/ `bndm_match`（2..16 入口，委托 `memchr_match`）/ **`multi_match`（多模式，首字节 256 位图预筛）**，以及**编译期常量**的算法选择表 `alg_table` + `select_matcher` + `select_matcher_for`。命中数组用 `context.allocator` 分配、**所有权归调用方**（见 ADR 0004；算法分层见 ADR 0008） |
| `app/walk.odin` | 目录遍历与 glob：`glob_match`/`walk_dir`/`walk_expand`/`walk_free`（递归、隐藏文件、glob、exclude 的选项类型是 `lib.Walk_Options`） |
| `search/merge.odin` | `merge_ordered_matches`：多分片命中列表的多路有序归并（游标临时缓冲用后即释放） |
| `search/slice_utils.odin` | 泛型切片工具：map / fold / filter / take / drop / sort |
| `engine/worker.odin` | `worker_steal`（扫描线程）与 `output_thread`（唯一打印线程，含 JSON/行导向/`-o`/`-m` 分支）；**线程入口先归一化 `context`**；打印与 dump 均**攒批写出**（64 KiB 阈值）；silent 模式（`-q/-c/-l/-L` 且无 `-m`）跳过实时输出队列（ADR 0008） |
| `engine/io_utils.odin` | `read_file_data`、`file_size_of`（--max-size 探测）、`context_range`、`print_context`、`sanitize_dump_name`、`dump_matches`（覆盖/追加、**攒批**）、**`build_line_index`（SIMD 单次遍历）/`line_of`、`json_escape`、`print_hex_bytes`、`resolve_color`** |
| `app/scan.odin` | `scan_file` 单文件编排（`--max-size` 拦截 → 空文件快速跳过 → 并行扫描 → 过滤 → `-l/-L`/`--count`/`--json`/统计 → 落盘）与 `scan_region_parallel`（**归并后释放各分片命中数组**）；选项类型 `lib.Scan_Options` 见 `lib/options.odin` |
| `app/selftest.odin` | 内建自检 `run_tests`（`--test`），随二进制分发 |
| `app/bench.odin` | 微基准 `run_bench`（`--bench`）：A 组算法吞吐 + B 组端到端线程伸缩 |

> `arena_pool.odin` 已在 ADR 0004 中删除（arena 定长，无法承载无界的命中结果集）。

### 工具代码（`tools/`，非 Odin）

| 文件 | 职责 |
| --- | --- |
| `tools/odin_qualify.py` | **包级重构工具**（Python 3.8+ 标准库）。`qualify` 加包名前缀并同步 `import "xrep:..."`、`strip-self` 去掉自引用前缀、`symbols` 打印各包声明、`check-literals` 字面量护栏、`selftest` 28 项内置回归。词法感知：字符串 / raw string / 字符字面量 / 行注释 / 块注释全部屏蔽后才替换。详见 ADR 0006 |
| `tools/guard.sh` | 静态护栏：工具自检 → 字面量污染检测 → `make deps`。`verify.sh` 的第 0 层，也可 `make guard` 单独跑 |
| `tools/literal_allowlist.txt` | 字面量检测的白名单（当前为空；只有**有意**在文本里写 `包名.符号名` 才需要加行） |

### 测试代码（12 个文件，129 个用例）

| 测试文件 | 覆盖目标 | 用例数 |
| --- | --- | --- |
| `engine/io_utils_test.odin` | `context_range` 全部边界、文件读取成功/失败、`file_size_of`、`sanitize_dump_name`（绝对/相对/Windows 保留字符/UTF-8/空串）、dump 各形态、**行号表与 `line_of` 二分、`json_escape`、`hex_digit`、`resolve_color`、`print_hex_bytes` 边界** | 21 |
| `app/cli_test.odin` | 参数解析：默认值、位置参数分配、全部长短标志、**`--k=v` 等号形式、短标志捆绑、多模式、`-f`、`--color`、遍历/输出开关**、错误分支、`--help`/`--version` 即时性 | 24 |
| `app/scan_test.odin` | 端到端扫描：计数、线程数一致性、区间过滤、`--limit` 契约语义、dump 与 dump-prefix 清洗、`--dump-append`/`--skip-empty`/`--max-size`/空文件快速跳过/落盘失败上报、跨分片归并有序、文件缺失、`-l/-L`、`-m` 截断、多模式端到端、**`Run_Stats` 四条计数各自的累加规则**、`legacy_output` / `line_index_needed` 真值表、**分片重叠窗口的重复上报契约** | 21 |
| `search/matcher_test.odin` | 算法选择表边界（1/2/16/17/64/65/0、区间外回退）、重叠命中、大小写、空模式、NUL 字节、算法间一致性、多模式 `multi_match` 与 `select_matcher_for` 分派、稠密命中不被截断（ADR 0004 回归）、**差分测试（8 种模式 × 大小写两态 × 三条实现路径，对照 `core:strings` 参考实现）**、**多模式 = 单模式多重集并集**、**各算法向 `Progress` 上报的字节数** | 13 |
| `app/walk_test.odin` | glob 语义（`*` 不跨 `/`、`**` 跨 `/`、`?`、转义、basename 规则）、递归/非递归、隐藏文件、exclude、按后缀过滤、空输入、**不可读目录的容错**、**`strip_dot_slash`/`join_path`/`walk_hidden`/`walk_excluded`/`walk_glob_ok` 纯函数** | 16 |
| `lib/progress_test.odin` | 初始化字段、禁用时不累加 `scanned`、启用时累加与限流、`total=0` 渲染短路 | 5 |
| `search/slice_utils_test.odin` | map/fold/filter/take/drop/sort 的空切片、n=0、n=len、n>len、重复键等边界 | 5 |
| `lib/base_test.odin` | `lower_table` 填充规则（含非字母透传）、`s2b` 零拷贝、`clamp_thread_count` 边界、常量不变量、**`ctx_pattern_count`/`ctx_pattern_at` 模式表访问器** | 5 |
| `search/merge_test.odin` | 空列表集合、单列表、三路交错、空条目、重复偏移、总长度不变量、**8 路随机分片的多重集与升序校验**、**全同偏移的极限形态** | 6 |
| `lib/output_queue_test.odin` | FIFO、`done` 后立即返回、重复 `set_done`、单生产者/单消费者并发往返、**4 生产者 × 250 条的总数与每生产者 FIFO 校验** | 5 |
| `lib/task_pool_test.odin` | 空池出队、LIFO 顺序、取空后可复用、**4 线程抢 200 任务：每个任务恰好被弹出一次** | 4 |
| `engine/worker_test.odin` | **命中偏移从分片相对改写为文件绝对**（`--after/--before`/`--dump`/行号都依赖它）、多任务产出多分片列表、空任务池立即退出、多模式分派确实走 `multi_match`、**输出线程的 `-m` 计数契约与 done 退出** | 4 |

> 用例数合计 129；`arena_pool_test.odin` 已随 ADR 0004 删除（6 个用例）。
> 逐包分布：lib 19、search 24、engine 25、app 61（`odin test` 一次只跑一个包，
> 见上节）。新增子目录包时，记得把路径加进 `test.sh` 的 `PACKAGES`。

### 关于"没有输出文本断言"

输出线程与汇总行都写**进程级 stdout**，而 `odin test` 默认**并行**跑用例 ——
捕获或重定向 fd 1 会与其它用例互相污染，属于用不可靠的断言换覆盖面。
因此 `*_test.odin` 只断言**返回值、落盘文件内容、统计累加、队列与偏移**这些
无歧义的可观察量；输出文本（`match offset:` / `path:line:offset` / JSON 字段 /
颜色码）由下节的外部命令矩阵把关。


## 测试

```bash
./test.sh                 # 单元测试（含内存泄漏检查）+ 内建自检，一条命令跑完
./verify.sh               # 完整验收：上面这些 + 三套行为验收矩阵（见下节）
```

等价的手工命令（注意与 `build.sh` 相同的链接器 + collection 修正）。
源码已拆成子目录包，`odin test` 一次只跑一个包，所以逐个来：

```bash
for p in . ./lib ./search ./engine ./app; do
  ODIN_CC=/usr/bin/clang odin test "$p" -collection:xrep=. -linker:lld
done
```

只跑某个用例、或做单线程排查（用例在哪个包就测哪个包）：

```bash
ODIN_CC=/usr/bin/clang odin test ./app -collection:xrep=. -linker:lld \
  -define:ODIN_TEST_NAMES=main.test_parse_args_defaults
ODIN_CC=/usr/bin/clang odin test ./app -collection:xrep=. -linker:lld \
  -define:ODIN_TEST_THREADS=1                                    # 串行执行
```

> 用例名的包前缀恒为 `main.`（`ODIN_TEST_NAMES` 的语法如此），与源码所在的
> `xrep:` 包无关，别写成 `app.test_parse_args_defaults`。

其它入口：

```bash
./xrep --test             # 进程内自检（slice 工具 + 匹配 + 归并 + glob + JSON 转义 + 清洗）
./xrep --bench            # 微基准（耗时约 7s，见下节）
tests/run.sh ./xrep       # 只跑历史命令 golden 矩阵（可加 --update / TESTS_FILTER）
```

### 微基准（`--bench`，约 7s）

两组测量，全部在内存里的合成数据上跑，不落盘：

- **A 组 · 匹配算法吞吐**（100 MiB 周期数据，每档 5 轮取**最快一轮**）：
  按模式长度分档 1B / 2B / 4B / 16B / 17B / 64B / 128B —— 正好覆盖 `alg_table`
  的每一档与表外回退；再加 `-i`（大小写不敏感）与 2/4 模式（`multi_match`）。
  每个 case 都经 `select_matcher_for` 分派，因此打印的算法名就是实际执行的那个，
  顺带验证了长度分派。
- **B 组 · 端到端线程伸缩**（64 MiB 稀疏数据，每档 3 轮取最快一轮）：
  直接跑 `scan_region_parallel` —— 任务池 + worker + 输出队列 + 归并的完整路径，
  报告 1/2/4/8 线程的吞吐与相对加速比。单看 A 组只说明"算法有多快"，
  B 组才说明"多线程有没有用"。

本机（10 逻辑核）实测输出示例（ADR 0008 之后）：

```
-- A1. single pattern, case sensitive --
  1B       single_match   22972.66 MB/s
  4B       bndm_match     34118.05 MB/s
 17B      memchr_match   17129.15 MB/s
128B      memchr_match    3709.47 MB/s
-- A3. multi pattern (-e / -f) --
  2 pat    multi_match     1502.47 MB/s
  4 pat    multi_match     1219.02 MB/s
-- B. end-to-end scan_region_parallel (pattern 'test', 1 hit / 65536 B) --
  1 thread(s)        64581.23 MB/s   1.00x
  8 thread(s)        95808.38 MB/s   1.48x
```

口径说明：A 组取"最快一轮"是因为别的负载与调度抖动只会让结果变慢，
不会让它变快。B 组的加速比**看起来变低了是正常现象**：匹配本身已经快到
不再是瓶颈（1 线程就有 60+ GB/s），剩下的是内存带宽与线程同步 ——
衡量多线程价值要看绝对吞吐，而不要只看倍数。

### 基线：129 用例全绿、0 内存泄漏

内存追踪**保持开启**（`test.sh` 不再传 `ODIN_TEST_TRACK_MEMORY=false`）。
基线就是"全绿且没有任何 `+++ leak` 告警"——因此**看到 leak 就是真问题**，
不是噪声。写测试时请遵守"谁分配谁释放"：

- `merge_ordered_matches(...)` 的返回值、`parse_args(...)` 的 `Options.file_list`
  （用 `options_destroy(&opts)` 一次释放）、`os.read_entire_file(...)` 的缓冲、
  `slice_map`/`slice_filter` 的结果、**`single_match`/`naive_match`/`bndm_match`/
  `multi_match` 的返回值**都由调用方 `delete`；`os.stat` 返回的 `File_Info`
  需 `file_info_delete`。只判存在性时用 `os.exists(path)`，它不分配。
- 自建线程的入口必须先 `context = runtime.default_context()`（见下节）。
- **worker 线程产出的东西，内外两层都要用默认分配器释放**：
  命中数组是 matcher 在 worker 线程里分配的，而分片列表的 dynamic 数组是被
  worker 的 `append` **首次扩容**出来的 —— 那里 context 已是 default_context，
  所以外层也在默认堆上。两层都用 `delete(x, runtime.default_context().allocator)`，
  否则主线程的追踪分配器会去 free 堆指针，报 `+++ bad free`（见
  `worker_test.odin` 的 `free_match_lists`）。
- **`defer` 是块作用域**：`if` / `for` 体内的 `defer` 会在该块结束时立即执行。
  凡是"离开该块后还要用"的值（例如作为参考数据的 `strings.to_lower` 结果），
  `defer` 必须写在函数体顶层，或改用显式 `delete` 收尾 —— 提前 free 会让断言
  读到已释放内存，表现为"参考实现莫名其妙少报一半命中"。
- 测试构造字符串请用 `fmt.aprintf` 而非 `fmt.tprintf`：后者来自临时分配器，
  再手工 `delete` 会变成"释放了不该释放的指针"。

### 行为验收矩阵（非单元测试，仓库内 `tests/`）

`odin test` 覆盖函数级行为；**对外可观察行为**另外用三套命令矩阵把关。
它们原先只存在于 `/tmp/xrep_verify/`（临时目录，现已消失），**已重建到仓库里**：

```bash
./verify.sh              # 一条命令跑完：单元测试 + 内建自检 + 三套矩阵
./verify.sh --update     # 重新生成 golden（**仅在有意改行为时**）
TESTS_FILTER=dump ./verify.sh   # 只跑名字含 dump 的命令
```

| 脚本 | 内容 | 规模 |
| --- | --- | --- |
| `tests/run.sh <bin> [outdir]` | 历史命令 **golden 矩阵**：全部旧标志组合、错误路径、多线程、dump、`--test`/`--help`、分片重叠窗口契约。每条采集 stdout / stderr / 退出码 / **它产出的所有文件**，与 `tests/golden/<name>.txt` 逐字节比对 | 78 条命令 |
| `tests/run2.sh <bin>` | ADR 0002 那批新增/变更行为的**断言**（版本、线程夹取、dump-prefix 清洗、dump 失败退出码、skip-empty、dump-append、max-size、多文件汇总、空文件、参数互斥） | 34 条断言 |
| `tests/run3.sh <bin>` | krep 对齐功能的**断言**（`-r`、glob/exclude/hidden、`-l/-L`、`-n`、`-o`、`-m`、`-e/-f`、`--json`、`--stats`、`--color`、短标志捆绑、单文件默认输出回归护栏） | 56 条断言 |
| `tests/lib.sh` | run2/run3 共用的断言小工具（`eq`/`has`/`hasnt`/`file_eq`/`exists`/`missing`/`run`） | — |
| `tests/fixtures/` | 矩阵用的固定输入（文本、空文件、目录树含隐藏项、`-f` 模式文件） | — |

**两套机制的分工**：`run.sh` 是"逐字节快照"（golden 不知道对错，只报**变化**）；
`run2.sh`/`run3.sh` 每条都有明确对错，行为被无意改坏时**直接指名道姓**。

**改动行为的纪律**：

- 等价重构 → `run.sh` 的 `diff` 必须为空；
- 有意改行为 → 用 `./verify.sh --update` 重新生成 golden，并在 commit 里
  **逐条解释每一处 diff**（`git diff tests/golden/` 会精确指出变了哪几条命令）。

**golden 的性质**：它记录的是**当前 HEAD 的行为**（重构早已合入，"改动前"的基线
已无从取得），因此是一张"现状快照"，不是"重构前后等价"的证明。

### 静态护栏（第 0 层，`tools/guard.sh`）

矩阵能抓住"行为变了"，但有一类问题它发现得**太晚**：拆包时用脚本批量给符号加
包名前缀，一旦误伤**字符串字面量**，输出文本就被静默改坏，要等 78 条命令跑完
才知道。为此在 `verify.sh` 最前面加了一层成本极低的检查：

```bash
./verify.sh        # 自动包含第 0 层
make guard         # 或单独跑这一层
```

| 检查 | 拦什么 |
| --- | --- |
| `odin_qualify.py selftest` | 工具自身的 28 项回归：字符串 / raw string / 注释 / 结构体字段 / 字面量字段 / proc 参数名 / 成员访问 / **切片语法** / **局部变量撞名** 都不得被误改，并断言"旧错误做法确实会改坏"（证明用例有区分度） |
| `odin_qualify.py check-literals` | 扫描全部 `.odin`：字符串里出现 `<包>.<该包已知符号>` 即报错。判别式设计——`"xrep GET app.log"` 不会误报，`"OK search.slice_map"` 会被抓 |
| `make deps` | 包依赖方向单向（`main → app → engine → search → lib`），出现反向/跨层引用即失败 |

误报需要放行时，往 `tools/literal_allowlist.txt` 加一行正则（当前为空）。
改动背景与复现测试见 ADR 0006。

**写新命令时的三条可复现性前提**（违反任何一条都会让 golden 变成噪声源）：

1. 全部用**相对路径**（cwd = 仓库根）；脚本会把绝对路径归一化为 `@OUT@` / `@REPO@`。
2. **不要**把 `--stats` / `--bench` 放进 `run.sh`：它们打印计时值（`%.2f ms`）。
   计时类断言放 `run3.sh` 做字段级检查。
3. fixture 保持小（< 2 MiB）：单分片 → 单 worker 产出 → 打印顺序确定；
   且耗时远低于进度条的 200 ms 刷新间隔 → 不会插入带百分比的中间帧。
   唯一例外是 `chunk-straddle-*` / `chunk-boundary-*` 两条（分片重叠窗口契约）
   —— 它们**故意**跨分片，因此用 `-c` + `--dump` 把输出压成"结论行 + 归并后的
   dump"两段确定的文本；2 MiB 的输入由脚本在临时目录现造，不进仓库。

### 关于测试输出的噪声（均为预期行为，非失败）

- 错误路径用例（文件不存在、dump 目录不可达、`--max-size` 跳过、**目录不可读**）
  会向 stderr 打印预期内的信息；`print_context` 冒烟用例会向 stdout 打印几行 hex。
- **`-l` / `-L` / `--json` 的输出用例会向 stdout 打印文件名或 JSON 行**：这两个开关
  只抑制明细，汇总/结论行照打（既有语义），因此用例里的 `quiet=true` 并不能完全静默。
- 测试文件（`*_test.odin`）在当前 Odin 版本下会一并被 `odin build .` 编译
  （但 `@(test)` 不会被调用，不影响运行行为），因此测试代码必须始终可编译。

### 两个会让 `./xrep` "凭空消失"的陷阱

- **`odin test .` 会删掉仓库里的 `./xrep`**：它编译测试产物时占用了同名路径，
  结束时清理。这就是 `test.sh` 把"内建自检"排在 `./build.sh` **之后**的原因。
  手工调试时若遇到 `./xrep: No such file or directory`，重新 `./build.sh` 即可。
- **`odin test` 不执行 `main`**：所以任何"藏在 main 里的初始化"在测试中都不可见。
  全局表因此改为 `@(init)` 自动填充 / 编译期常量，与 main 无关（见"并发与内存约定"）。

> **Odin `defer` 是块作用域**：写在 `if`/`for` 体内的 `defer` 会在该块结束时
> 立即执行，而不是等函数返回。曾经因此写出 `if ... { defer delete(buf) }`，
> 导致 buf 在使用前被释放（表现为 dump 写出一堆垃圾偏移）。凡是"函数末尾才
> 该释放"的资源，`defer` 必须写在函数体顶层。

## 并发与内存约定（改代码前必读）

这几条是踩过坑后固化下来的规则，违反任意一条都会产生**偶发但真实**的错误。

1. **线程入口必须归一化上下文。** Odin 创建线程时会复制创建者的 `context`，
   子线程因此默认继承调用方的分配器。生产环境下 main 的分配器就是堆分配器，
   继承与不继承等价；但在 `odin test` 下，运行器装的是 `mem.Tracking_Allocator`，
   它内部是一个**无锁 map**，被多个线程并发分配会写坏其数据结构——表现是
   **偶发 SIGBUS（退出码 138）** 以及一大批误导性的 leak 告警。
   因此 `worker_steal` / `output_thread`（以及测试里自建线程的入口）第一件事都是
   `context = runtime.default_context()`。**新增线程时照做。**

2. **匹配算法不得写 `context.allocator`。** 该赋值会**永久**改写当前线程的分配器
   （proc 返回也不还原），使调用方后续所有 `make`/`append` 都落到意想不到的地方。
   命中数组改为用 `context.allocator` 分配——**读它是可以的，写它不行**。

3. **命中数组无容量上限（ADR 0004）。** 命中结果**不再**由定长 arena 承载：
   arena 装不下时 Odin 的 `append` 会**静默失败**，表现为"命中被悄悄丢弃"
   （实测 `all_a.bin` 丢失 40%）。现在由 `matcher` 在堆上分配，
   **所有权归调用方**：`worker_steal` 接手后交给汇总列表，
   `scan_region_parallel` 在归并之后逐个 `delete`。
   释放跨线程时**必须显式指定同一分配器**：

   ```odin
   delete(lst, runtime.default_context().allocator)
   ```

   因为 worker 分配的是"进程默认堆"内存，而 `main` 线程在 `odin test` 下的
   `context.allocator` 是追踪分配器——不显式指定就会报 `+++ bad free`。

4. **全局表用 `@(init)` / 编译期常量，不要依赖 main。** `lower_table` 是
   `[256]u8` 定长数组、纯算术填充，用 `@(init) ... proc "contextless"` 在进程启动时
   填好；`alg_table` 直接是编译期常量数组。这样 main 与 `odin test` 走同一条启动
   路径，"测试忘了初始化全局表"这个问题从根上消失（曾因此让大小写不敏感匹配把
   所有字节都视为相等，得出 29 命中而非 3 的误判）。

## 模块拆分与兼容性验证

`main.odin` 原先 966 行单文件，现按职责拆为 15 个生产文件 + 11 个测试文件。
拆分原则是**只移动与加注释，不改语义**：所有函数名、签名、字段名、默认值、
输出文本、退出码均保持原样（后续的 krep 对齐改动是在拆分之后单独进行的）。

行为等价性用命令矩阵验证：47 条命令（含全部标志组合、错误路径、多线程、
dump、`--test`/`--help`）各采集 stdout、stderr、退出码三份产物，
拆分前后 `diff -r` 结果为空。

拆分中仅引入两处"可测试性缝隙"，均由上述矩阵覆盖，行为不变：

1. `parse_args` 不再内嵌 `os.exit`，改为返回 `(Options, Parse_Outcome, message)`，
   退出策略留在 `main`。`--help` 的"即时退出"语义用 `.Help` 三态保持
   （`--threads abc --help` 仍以 1 退出）。收益：24 个 CLI 用例可覆盖全部错误分支。
2. `print_context` 的窗口夹取算术抽为纯函数 `context_range(file_len, offset, pat_len, ctx)`
   并被其复用；hex 渲染逻辑未动。收益：边界算术可单测。

### 决策记录（ADR）

- `ADR 0001`（`.ai-memory/adr/0001-module-split-and-seams.md`）：单文件拆分为模块，
  并引入上述两处可测试性缝隙。
- `ADR 0002`（`.ai-memory/adr/0002-optional-fixes-and-dump-prefix-sanitization.md`）：
  新增 4 个 flag、线程数夹取、空文件快速跳过、dump 失败非零退出、常量抽取，
  以及 `--dump-prefix` 文件名清洗这一**唯一的有意行为变更**。
- `ADR 0003`（`.ai-memory/adr/0003-thread-context-and-allocator-hygiene.md`）：
  线程上下文归一化、`merge` 临时缓冲释放、全局表改 `@(init)`/常量、
  `cli.file_list` 惰性分配与所有权。对外可观察行为零变化。
- `ADR 0004`（`.ai-memory/adr/0004-match-results-on-heap.md`）：**命中结果改用堆分配**。
  `Match_Result` 因 `-o`/多模式增加 `pat_len` 字段（8 → 16 字节），
  暴露出"定长 arena + 动态数组 2 倍扩容 → 超容量静默丢命中"的既有缺陷
  （实测 `all_a.bin` 丢失 40% 命中）。命中数组改由堆承载、所有权交给调用方，
  `Arena_Pool` 整体删除；同时修复了"内层命中切片从不释放"的隐蔽泄漏。
  47 条命令矩阵仍只有 help 文本差异。
- `ADR 0005`（`.ai-memory/adr/0005-krep-feature-alignment.md`）：**对齐 krep** ——
  新增 `walk.odin`（目录遍历 + 自实现 glob）、行导向输出、多模式 `multi_match`、
  `-l/-L`/`-n`/`-o`/`-m`/`--json`/`--stats`/`--color`/短标志别名与 `normalize_args`。
  同时记录了本轮**唯一的有意行为变更**：`--no-color` 从"无效"变为真正生效。
- `ADR 0006`（`.ai-memory/adr/0006-package-split-into-subdirectories.md`）：
  **把根目录平铺的 26 个 `.odin` 拆成 4 个子目录包**
  （`app`/`engine`/`search`/`common`），让目录结构本身表达分层、由编译器强制
  单向依赖。跨包引用统一加包名限定；兄弟包用 `-collection:xrep=.` 引用；
  `Progress` 下沉到 common 以解开 common→engine 的环；`odin test` 改为逐包跑。
  **对外行为零变化**：129 个用例、78 条 golden 矩阵、run2/run3 全部与拆分前一致。
- `ADR 0007`（`.ai-memory/adr/0007-consolidate-data-structures-into-lib.md`）：
  **把散落各包的共享数据结构整合进 `lib` 包**。原 `common` 整体并入 `lib` 后删除；
  `app` 的 `Options`/`Scan_Options`/`Walk_Options`/`List_Mode`/`Parse_Outcome`
  与 `engine` 的 `Scan_Task`/`Task_Pool`/`Output_Item`/`Output_Queue`（含操作）
  一并下沉。于是依赖图只有一条链 `main → app → engine → search → lib`，
  最底层只有 `lib` 一个包 —— 新增消费者不会再引出反向依赖。
  **对外行为零变化**：129 个用例（逐包 lib 19 / search 24 / engine 25 / app 61）
  与三套行为矩阵全部与整合前一致。
- `ADR 0008`（`.ai-memory/adr/0008-mode-aware-algorithm-and-data-layout.md`）：
  **按「模式长度」分层算法、按「操作模式」裁剪工作**。匹配侧统一用
  `core:bytes.index_byte`（core 的 SIMD 实现）做首字节预筛，新增 `memchr_match`
  （预筛 + 倒序验证）接管 2..4096 字节，多模式加首字节 256 位位图；操作侧
  `-q/-c/-l/-L`（且无 `-m`）跳过输出队列、打印与 dump 攒批写出（64 KiB）；
  数据结构侧 `Output_Queue` 改为环形缓冲（O(1) 出队）。
  **对外行为零变化**：golden 矩阵与 dump 产物均逐字节一致，只有耗时变化。



## 已知行为与限制

标注「契约」的为**原实现既有语义**，刻意保留；标注「变更」的为 ADR 明确修改过的
行为（标注对应的 ADR 编号）。

1. 「变更 ADR 0005」`--no-color` 现在**真正生效**（等价于 `--color never`）。
   颜色默认是 `--color always`；`--color auto` 按 stdout 是否 TTY 判定。
   原实现接受 `--no-color` 却恒为彩色（`use_color` 恒 `true`），且没有 `--color`。
   **2026-10-10 修正**：进度条此前绕过 `--color` —— `scan.odin` 里
   `progress_init` 的实参写成了 `(p, total, true, progress_on)`，而形参是
   `(p, total, use_color, enabled)`，于是 `use_color` 被写死为 `true`：
   `--color never` 下命中高亮不染色了，进度条那一行的 ANSI 绿色转义却仍在往
   stdout 吐（重定向到文件或管道时可见）。现已改为传 `o.use_color`，
   由 `tests/run3.sh` 的"整段输出无 ANSI"断言锁住。
2. 「契约」**分片重叠窗口内的命中会重复上报**。每个任务向后多扫 16 字节
   （`CHUNK_OVERLAP`）以避免切断跨分片匹配，导致偏移落在
   `[分片边界, 分片边界+16)` 的命中被两个任务各报一次（`--dump` 与 `--count`
   中可见重复行）。列表按偏移升序，重复项相邻，暂未做去重。
   **ADR 0004 只修了"丢命中"，没有改这一条**；`dense.bin` 的计数与 HEAD 逐字节一致。
3. 「契约」`--limit N` 只截断 pretty **汇总行**，且截断前会先丢弃前 2 条命中；
   `--count` 与 `--dump` 使用完整结果集。注意命中明细是由输出线程流式打印的，
   本身不受 `--limit` 限制。本项**未修改**（保留原语义）。
4. 「契约」`bndm_match`（2..16 字节模式）**仍未实现**位并行算法：ADR 0008 之后它
   委托 `memchr_match`（SIMD 预筛 + 倒序验证），**结果与朴素扫描完全一致**，
   只是更快。17..4096 字节同样走 `memchr_match`；表外（>4096）回退 `naive_match`。
5. 「变更 ADR 0002」`--dump-prefix P` 展开为 `P{sanitized(path)}.txt`：文件名中的路径分隔符
   （`/` `\`）与 Windows 保留字符（`: * ? " < > |`）被替换为 `_`，长度不变。
   因此不再需要预先创建与输入路径同构的目录层级（原行为会生成
   `out_./data/file.bin.txt` 并写入失败）。注意 `P` 本身**不参与清洗**，
   若 `P` 含目录分隔符，其目录仍需存在。
6. 「契约」进度条关闭（`--quiet`）时 `scanned` 不累加，进度条不显示任何百分比。
7. 「契约」命中明细由单一输出线程按队列顺序打印，多线程下明细的先后取决于调度，
   与 `--dump` 中按偏移有序的结果不同。
8. 「变更 ADR 0002」`--threads N` 会被夹到 `1 .. 逻辑核心数×4`。原先 `0` 表示"不起 worker"，
   结果是**静默 0 命中**；超大值（如 `100000`）会创建上千线程并挂死。
9. 「变更 ADR 0002」任一 dump 落盘失败时进程以 `1` 退出（原先只打 stderr、退出码仍为 0）。
10. 「变更 ADR 0002」`--max-size` 跳过的文件不输出任何 stdout 统计（它不是"0 命中"而是
    "未扫描"，打印 `0 hits` 会误导）；跳过原因固定写 stderr，且**不受 `--quiet`
    抑制** —— `--quiet` 的语义是"不闲聊"，而"请求的工作没做"必须仍然可见。
11. 「契约」空文件仍会创建空的 dump 文件（便于脚本判断"已执行过"）；
    若需跳过，用 `--skip-empty`。

### krep 对齐新增行为（ADR 0005）

- **目录需显式 `-r`**：不带 `-r` 时目录会被拒绝，stderr 提示
  `is a directory (use -r to search recursively)`，**退出码仍为 0**、无 stdout 输出。
- **`-r` 默认跳过隐藏项**（`.` 开头）；`--hidden` 收录。
- **glob 语义**：`*` 不跨 `/`，`**` 跨 `/`，`?` 匹配单个非 `/` 字符，`\` 转义；
  模式中不含 `/` 时只与 **basename** 比对（同 gitignore/grep 直觉）。
- **行导向输出**：多文件或 `-r` → `path:line:offset`；单文件 + `-n` → `line:offset`；
  其余保持历史 `match offset: N`。**单文件默认调用逐字节兼容**（回归护栏）。
- **`-m/--max-count N` 同时约束计数与打印**：第 N+1 条起既不计数也不打印，取的是
  "流式到达顺序"的前 N 条 —— 多分片时任务完成顺序可能与偏移顺序不同，
  因此**未必是偏移最小的 N 条**。汇总与落盘路径会另行把结果截断到 N 条。
- **多模式同一偏移多次命中会各报一条**（不去重），与第 2 条的"重叠重复"语义一致。
- **`-l` / `-L` 互斥**：两者共用同一个 list 模式字段，**后写的生效**
  （`-l -L` 等价于 `-L`）。
- **`--stats` 固定写 stderr**，格式
  `stats: N files scanned, M with matches, K skipped, B bytes, H hits, T ms`；
  其中 `T ms` 为耗时、**不确定**，断言时请只匹配前面的字段。
- **`--json` 的字段**：`{"file","line","offset","len"}`；
  加 `-o` 时追加 `"match":"<命中字节的 hex>"`。所有值均为非负整数或字符串。

