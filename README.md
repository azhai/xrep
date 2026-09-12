xrep
-----

Odin 语言写的 grep，复刻自 krep 。

多线程（工作窃取任务池）二进制模式搜索：按模式长度自动选择匹配算法，
命中偏移可过滤、可着色展示上下文、可落盘为 dump 文件。

---

## 构建

```bash
./build.sh              # 产出 ./xrep
OPT=speed ./build.sh    # 可选优化级别: -o:none|minimal|size|speed（默认 size）
OUT=xrep2 ./build.sh    # 自定义输出名
```

`build.sh` 会强制 `ODIN_CC=/usr/bin/clang` 并加 `-linker:lld`。
原因：本机 PATH 里的 `clang` 可能被 Android NDK 的 x86_64 clang 抢先占用，
导致 Odin 链接阶段报 `unknown file type *.o`。手工编译时请自行带上同样参数。

## 用法

```bash
./xrep <模式> [文件...] [标志]
```

| 标志 | 说明 |
| --- | --- |
| `--threads N` | worker 线程数（默认 4；**自动夹到 `1 .. 逻辑核心数×4`**） |
| `--ignore-case` | 大小写不敏感匹配 |
| `--limit N` | 限制 pretty 汇总条数（`0` = 不限制；不影响 `--count`/`--dump`） |
| `--after N` | 只保留偏移 ≥ N（接受 `0x` 十六进制） |
| `--before N` | 只保留偏移 ≤ N（接受 `0x` 十六进制） |
| `--context N` | 每条命中额外以 hex 展示前后各 N 字节，命中字节红色高亮 |
| `--count` | 只输出命中总数 |
| `--offset-hex` | 偏移以十六进制打印 |
| `--dump FILE` | 把（过滤后的）所有命中偏移写入单个文件 |
| `--dump-prefix P` | 按文件分别落盘到 `P{清洗后的文件名}.txt`（见"已知行为"） |
| `--dump-append` | dump 改为追加写（默认覆盖） |
| `--skip-empty` | 命中 0 条时不产出 dump 文件（默认会产出空文件） |
| `--max-size N` | 跳过大于 N 字节的文件（读入前先探测大小，不会先 OOM） |
| `--quiet` | 静默：不输出统计与进度，仅保留 dump 与 stderr 错误 |
| `--no-color` | 已接受但**无效果**（颜色恒为开；见"已知行为"） |
| `--test` | 运行随二进制分发的内建自检 |
| `--bench` | 运行匹配算法微基准（100 MiB 合成数据） |
| `-v`, `--version` | 打印版本并立即退出（其后的参数不再解析） |
| `-h`, `--help` | 打印帮助并立即退出（其后的参数不再解析） |

退出码：`0` 正常完成（含"文件不存在"这类已报告但不致命的错误）；
`1` 参数错误，或**任一 dump 落盘失败**。

多文件扫描完成后会多打印一行 `Scanned N files, total hits: M`（受 `--quiet`
抑制；单文件时不打印）。

## 文件结构

### 生产代码（15 个文件，约 1650 行含注释）

依赖方向单向：`main` → 编排模块（`cli`/`scan`/`selftest`/`bench`）→ 并发与 I/O 设施
（`task_pool`/`arena_pool`/`output_queue`/`progress`/`worker`/`io_utils`）→
算法与工具（`matcher`/`merge`/`slice_utils`）→ `common`。底层模块不反向引用上层。

| 文件 | 职责 |
| --- | --- |
| `main.odin` | 入口编排：解析参数 → **夹取线程数** → 分派子命令 → 遍历文件扫描 → **汇总统计 → 归还 `file_list` → 决定退出码**。全局表初始化已移出（见 `common`/`matcher`） |
| `cli.odin` | `Options`（18 个字段）、`parse_args`（纯解析，不含退出策略；`file_list` **按需分配、调用方负责 delete**）、`max_threads_for_machine`、`print_help`/`print_version` |
| `common.odin` | **运行期常量**（分片大小/重叠窗口/arena 容量/进度刷新间隔/线程上限/版本号）、`lower_table`（**`@(init)` 启动时自动填充**）、`clamp_thread_count`、共享类型（`Match_Ctx`/`Match_Result`/`Match_Fn`/`Algorithm_Entry`）、arena 生命周期辅助、`s2b` |
| `matcher.odin` | `single_match` / `naive_match` / `bndm_match`，以及**编译期常量**的算法选择表 `alg_table` 与 `select_matcher`。分配一律**显式**指定 arena 分配器 |
| `merge.odin` | `merge_ordered_matches`：多分片命中列表的多路有序归并（游标临时缓冲用后即释放） |
| `slice_utils.odin` | 泛型切片工具：map / fold / filter / take / drop / sort |
| `task_pool.odin` | 扫描任务池（`Scan_Task` + Mutex 保护的动态数组，供 worker 抢占） |
| `arena_pool.odin` | arena 对象池：借出即 reset，归还复用，避免每分片重复分配 16 MiB |
| `output_queue.odin` | 生产者/消费者输出队列（Mutex + Cond，`done` 标志驱动消费者退出） |
| `progress.odin` | 终端进度条（`\r` 原地刷新 + 限流，`--quiet` 时整体关闭） |
| `worker.odin` | `worker_steal`（扫描线程）与 `output_thread`（唯一打印线程）；**线程入口先归一化 `context`** |
| `io_utils.odin` | `read_file_data`、`file_size_of`（--max-size 探测）、`context_range`、`print_context`、`sanitize_dump_name`、`dump_matches`（覆盖/追加） |
| `scan.odin` | `Scan_Options` + `scan_file` 单文件编排（`--max-size` 拦截 → 空文件快速跳过 → 并行扫描 → 过滤 → 落盘 → 统计）与 `scan_region_parallel` |
| `selftest.odin` | 内建自检 `run_tests`（`--test`），随二进制分发 |
| `bench.odin` | 微基准 `run_bench`（`--bench`） |

### 测试代码（11 个文件，77 个用例）

| 测试文件 | 覆盖目标 | 用例数 |
| --- | --- | --- |
| `io_utils_test.odin` | `context_range` 全部边界、文件读取成功/失败、`file_size_of`、**`sanitize_dump_name`（绝对/相对/Windows 保留字符/UTF-8/空串）**、dump 十进制/十六进制/空集/写入失败/**追加模式** | 16 |
| `cli_test.odin` | 参数解析：默认值、位置参数分配、全部标志（含新增 4 个）、错误分支、`--help`/`--version` 即时性、未知标志归入模式、**线程数不在解析层夹取** | 14 |
| `scan_test.odin` | 端到端扫描：计数、线程数一致性（含 **0 → 防御性当作 1**）、区间过滤、`--limit` 契约语义、dump 与 **dump-prefix 清洗**、**`--dump-append`/`--skip-empty`/`--max-size`/空文件快速跳过/落盘失败上报**、跨分片归并有序、文件缺失 | 14 |
| `matcher_test.odin` | 算法选择表边界（1/2/16/17/64/65/0、区间外回退）、重叠命中、大小写、空模式、NUL 字节、算法间一致性 | 5 |
| `progress_test.odin` | 初始化字段、禁用时不累加 `scanned`、启用时累加与限流、`total=0` 渲染短路 | 5 |
| `slice_utils_test.odin` | map/fold/filter/take/drop/sort 的空切片、n=0、n=len、n>len、重复键等边界 | 5 |
| `common_test.odin` | `lower_table` 填充规则（含非字母透传）、`s2b` 零拷贝、arena 生命周期、**`clamp_thread_count` 边界、常量不变量** | 5 |
| `merge_test.odin` | 空列表集合、单列表、三路交错、空条目、重复偏移、总长度不变量 | 4 |
| `output_queue_test.odin` | FIFO、`done` 后立即返回、重复 `set_done`、单生产者/单消费者并发往返 | 4 |
| `task_pool_test.odin` | 空池出队、LIFO 顺序、取空后可复用 | 3 |
| `arena_pool_test.odin` | 预分配、借出、池空自动扩容、归还 reset 与实例复用 | 2 |

## 测试

```bash
./test.sh                 # 推荐：单元测试（含内存泄漏检查）+ 内建自检，一条命令跑完
```

等价的手工命令（注意与 `build.sh` 相同链接器修正）：

```bash
ODIN_CC=/usr/bin/clang odin test . -linker:lld
```

只跑某个用例、或做单线程排查：

```bash
ODIN_CC=/usr/bin/clang odin test . -linker:lld \
  -define:ODIN_TEST_NAMES=main.test_parse_args_defaults
ODIN_CC=/usr/bin/clang odin test . -linker:lld -define:ODIN_TEST_THREADS=1   # 串行执行
```

其它入口：

```bash
./xrep --test             # 进程内自检（核心工具函数 + 朴素匹配冒烟）
./xrep --bench            # 匹配算法吞吐量对比
```

### 基线：77 用例全绿、0 内存泄漏

内存追踪**保持开启**（`test.sh` 不再传 `ODIN_TEST_TRACK_MEMORY=false`）。
基线就是"全绿且没有任何 `+++ leak` 告警"——因此**看到 leak 就是真问题**，
不是噪声。写测试时请遵守"谁分配谁释放"：

- `merge_ordered_matches(...)` 的返回值、`parse_args(...)` 的 `Options.file_list`、
  `os.read_entire_file(...)` 的缓冲、`slice_map`/`slice_filter` 的结果
  都由调用方 `delete`；`os.stat` 返回的 `File_Info` 需 `file_info_delete`。
  只判存在性时用 `os.exists(path)`，它不分配。
- 自建线程的入口必须先 `context = runtime.default_context()`（见下节）。

### 关于测试输出的噪声（均为预期行为，非失败）

- 错误路径用例（文件不存在、dump 目录不可达、`--max-size` 跳过）会向 stderr
  打印预期内的信息；`print_context` 冒烟用例会向 stdout 打印几行 hex。
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

这四条是踩过坑后固化下来的规则，违反任意一条都会产生**偶发但真实**的错误。

1. **线程入口必须归一化上下文。** Odin 创建线程时会复制创建者的 `context`，
   子线程因此默认继承调用方的分配器。生产环境下 main 的分配器就是堆分配器，
   继承与不继承等价；但在 `odin test` 下，运行器装的是 `mem.Tracking_Allocator`，
   它内部是一个**无锁 map**，被多个线程并发分配会写坏其数据结构——表现是
   **偶发 SIGBUS（退出码 138）** 以及一大批误导性的 leak 告警。
   因此 `worker_steal` / `output_thread`（以及测试里自建线程的入口）第一件事都是
   `context = runtime.default_context()`。**新增线程时照做。**

2. **匹配算法不得写 `context.allocator`。** `single_match` / `naive_match` 用
   `make(..., mem.arena_allocator(arena))` 把 arena 分配器**显式**传给每一次分配。
   若图省事写成 `context.allocator = mem.arena_allocator(arena)`，该线程的分配器会被
   **永久**改写（proc 返回也不还原），调用方之后的所有 `make`/`append`
   （worker 的"拷贝到堆"、`output_queue` 的扩容……）全都会落进 arena；
   而 arena 会被 `arena_pool` 反复 reset 复用，数据随时可能被后续分片覆盖。

3. **arena 只 reset、不归还系统内存。** `mem.arena_free_all` 仅把 `offset` 归零，
   内存原样复用。因此**任何指向 arena 的数据都必须在下一次复用前深拷贝出去**
   （`worker_steal` 的 `stable := make(...)` 就是干这个）；也不要让长期存活的结构的
   底层数组落在 arena 里（例如 `Arena_Pool.free_list`、`Output_Queue.items`）。

4. **全局表用 `@(init)` / 编译期常量，不要依赖 main。** `lower_table` 是
   `[256]u8` 定长数组、纯算术填充，用 `@(init) ... proc "contextless"` 在进程启动时
   填好；`alg_table` 直接是编译期常量数组。这样 main 与 `odin test` 走同一条启动
   路径，"测试忘了初始化全局表"这个问题从根上消失（曾因此让大小写不敏感匹配把
   所有字节都视为相等，得出 29 命中而非 3 的误判）。

## 模块拆分与兼容性验证

`main.odin` 原先 966 行单文件，现按职责拆为 15 个生产文件 + 11 个测试文件。
拆分原则是**只移动与加注释，不改语义**：所有函数名、签名、字段名、默认值、
输出文本、退出码均保持原样。

行为等价性用命令矩阵验证：47 条命令（含全部标志组合、错误路径、多线程、
dump、`--test`/`--help`）各采集 stdout、stderr、退出码三份产物，
拆分前后 `diff -r` 结果为空。

拆分中仅引入两处"可测试性缝隙"，均由上述矩阵覆盖，行为不变：

1. `parse_args` 不再内嵌 `os.exit`，改为返回 `(Options, Parse_Outcome, message)`，
   退出策略留在 `main`。`--help` 的"即时退出"语义用 `.Help` 三态保持
   （`--threads abc --help` 仍以 1 退出）。收益：14 个 CLI 用例可覆盖全部错误分支。
2. `print_context` 的窗口夹取算术抽为纯函数 `context_range(file_len, offset, pat_len, ctx)`
   并被其复用；hex 渲染逻辑未动。收益：边界算术可单测。

- `ADR 0002`（`.ai-memory/adr/0002-optional-fixes-and-dump-prefix-sanitization.md`）：
  新增 4 个 flag、线程数夹取、空文件快速跳过、dump 失败非零退出、常量抽取，
  以及 `--dump-prefix` 文件名清洗这一**唯一的有意行为变更**。
- `ADR 0003`（`.ai-memory/adr/0003-thread-context-and-allocator-hygiene.md`）：
  本轮健壮性修复 —— 线程上下文归一化、matcher 显式 arena 分配器、
  `merge` 临时缓冲释放、全局表改 `@(init)`/常量、`cli.file_list` 惰性分配与所有权。
  **对外可观察行为零变化**：47 条命令矩阵（含 dump 内容与退出码）`diff -r` 为空。
  直接效果是 `odin test .` 不再需要 `ODIN_TEST_TRACK_MEMORY=false` 就能稳定通过，
  内存追踪因此可以常开。

## 已知行为与限制

标注「契约」的为**原实现既有语义**，刻意保留；标注「变更」的为 ADR 0002
明确修改过的行为。

1. 「契约」`--no-color` 接受但不改变行为：`use_color` 恒为 `true`。
2. 「契约」**分片重叠窗口内的命中会重复上报**。每个任务向后多扫 16 字节
   （`CHUNK_OVERLAP`）以避免切断跨分片匹配，导致偏移落在
   `[分片边界, 分片边界+16)` 的命中被两个任务各报一次（`--dump` 与 `--count`
   中可见重复行）。列表按偏移升序，重复项相邻，暂未做去重。
3. 「契约」`--limit N` 只截断 pretty **汇总行**，且截断前会先丢弃前 2 条命中；
   `--count` 与 `--dump` 使用完整结果集。注意命中明细是由输出线程流式打印的，
   本身不受 `--limit` 限制。本项**未修改**（保留原语义）。
4. 「契约」`bndm_match`（2..16 字节模式）当前直接委托 `naive_match`，未实现位并行算法，
   因此 2..16 区间的性能与朴素扫描相同。
5. 「变更」`--dump-prefix P` 展开为 `P{sanitized(path)}.txt`：文件名中的路径分隔符
   （`/` `\`）与 Windows 保留字符（`: * ? " < > |`）被替换为 `_`，长度不变。
   因此不再需要预先创建与输入路径同构的目录层级（原行为会生成
   `out_./data/file.bin.txt` 并写入失败）。注意 `P` 本身**不参与清洗**，
   若 `P` 含目录分隔符，其目录仍需存在。
6. 「契约」进度条关闭（`--quiet`）时 `scanned` 不累加，进度条不显示任何百分比。
7. 「契约」命中明细由单一输出线程按队列顺序打印，多线程下明细的先后取决于调度，
   与 `--dump` 中按偏移有序的结果不同。
8. 「变更」`--threads N` 会被夹到 `1 .. 逻辑核心数×4`。原先 `0` 表示"不起 worker"，
   结果是**静默 0 命中**；超大值（如 `100000`）会创建上千线程并挂死。
9. 「变更」任一 dump 落盘失败时进程以 `1` 退出（原先只打 stderr、退出码仍为 0）。
10. 「变更」`--max-size` 跳过的文件不输出任何 stdout 统计（它不是"0 命中"而是
    "未扫描"，打印 `0 hits` 会误导）；跳过原因固定写 stderr，且**不受 `--quiet`
    抑制** —— `--quiet` 的语义是"不闲聊"，而"请求的工作没做"必须仍然可见。
11. 「契约」空文件仍会创建空的 dump 文件（便于脚本判断"已执行过"）；
    若需跳过，用 `--skip-empty`。
