# Progress Log

## 2026-09-12 08:23 — 启动与基线固化
- Ran: `head main.odin` / 全量 Read（966 行）→ 确认单文件包含 10 类职责。
- Ran: `./build.sh` → exit 0（ODIN_CC=/usr/bin/clang, -linker:lld）。
- Ran: `./xrep --test` → 6 项自检全 OK；`./xrep --help` → 输出 13 行帮助。
- Ran: `cp xrep /tmp/xrep_baseline` → 固化基线二进制。
- Ran: 生成 `/tmp/xrep_verify/{a.bin,b.bin}` 与 `run.sh`（47 条命令矩阵）。
- Ran: `./run.sh /tmp/xrep_baseline base` → 141 个产物文件（47 × stdout/stderr/exit）。

## 2026-09-12 08:24 — Odin 工具链探针（/tmp/odin_probe）
- Ran: `odin build .`（含 probe_test.odin）→ 编译通过，说明 `*_test.odin` 会被普通构建编译。
- Ran: `odin build .` 默认 PATH → 链接失败：`unknown file type *.o`（NDK clang 抢占，同 build.sh 注释）。**解决**：`ODIN_CC=/usr/bin/clang` + `-linker:lld`。
- Ran: `odin test .`（无 ODIN_CC）→ 同样链接失败 → 需要独立 `test.sh`。
- Ran: `odin test .` 成功执行 → 确认：不执行 main；proc 值可用 `==`；`[]u8`→`string` 必须 `transmute`。
- 失败尝试 1：`transmute([]byte)SCAN_SAMPLE`（无类型常量）→ 编译错误 "Cannot transmute untyped expression"。
  **改用**：先赋给 `content: string` 形参，再 transmute。
- 失败尝试 2：`for n in []uint{1,2,4,8}` → 语法错误 "Expected 1 expression"。**改用**：先赋值给变量再 range。

## 2026-09-12 08:26 — 模块拆分
- 新增 15 个生产文件：main / cli / common / slice_utils / matcher / merge /
  task_pool / arena_pool / output_queue / progress / worker / io_utils / scan /
  selftest / bench（原 main.odin 仅保留入口）。
- 首次 `./build.sh` 即通过（缺 import 已在写入前补：matcher/arena_pool/scan 的 core:mem）。

## 2026-09-12 08:27 — Phase 2 行为等价验证（拆分后首次）
- Ran: `./build.sh` → exit 0。
- Ran: `./run.sh /opt/repos/xrep/xrep new` + `diff -r base new` → **diff_exit=0**（47 用例零差异）。
- Ran: `./xrep --bench` → single 1634.55 / bndm 1290.64 / naive 1255.24 MB/s，正常。

## 2026-09-12 08:28 — Phase 3 单元测试（59 用例）
- 新增 11 个 `*_test.odin`。
- 失败尝试 3：`odin check .` 报 6 类错误（`&testing.T` 笔误、proc 内 `const` 非法、
  for-in 复合字面量、`ok` 同名重复声明 ×2、`mem.arena_total_allocated` 不存在、
  `os.write_entire_file` 重载歧义）→ 逐一修正；`arena_total_allocated` 改为 `Arena.offset`
  （对照 `core/mem/allocators.odin:147` 的字段定义）。
- Ran: `odin test .` → 59 用例，2 个失败。**两处均为我的断言写错，非实现缺陷**：
  1. `test_naive_match`：NUL 数据 `{00 01 41 00 41}` 匹配 `{00 41}` 只有偏移 3 一处命中 → 改为断言 1 处，并补"尾部不足"边界。
  2. `test_parse_args_empty_string_argument`：空字符串不占用模式位，故 `["", "file.bin"]` 的模式是 `"file.bin"` → 按实际（怪异）语义重写断言并注释。
- 失败尝试 4：全量默认线程 + 内存追踪 → 偶发 `Bus error: 10`（exit 138，6 次中出现 1 次）；
  按名隔离运行 scan 组又暴露 `test_scan_file_basic_count` 失败（hits=29）。
  **定位**：
  - hits=29 是因为该组单独运行时 `lower_table` 未被初始化（全 0 → 任意字节相等），
    即测试间存在隐式依赖 → 新增 `scan_init_globals()` 并在 8 个扫描用例中显式调用。
  - SIGBUS 与"并行测试线程 + 追踪分配器"相关：`-define:ODIN_TEST_THREADS=1`（追踪开）
    与 `-define:ODIN_TEST_TRACK_MEMORY=false`（默认线程）均稳定通过；
    实测 `TRACK_MEMORY=false` + 默认线程连续 6/6 全绿。
- 失败尝试 5：`test_scan_file_dump_prefix_resolution` 报"应能创建前缀目录"——
  上一次异常中断留下的目录使 `make_directory_all` 返回 Already_Exists。
  **解决**：用例开头先 `os.remove_all` 清理。

## 2026-09-12 08:31 — Phase 4/5 门禁与文档
- Ran: `./test.sh`（含 `ODIN_TEST_TRACK_MEMORY=false`）→ **59/59 全绿** + 内建自检全绿，exit 0。
- Ran: 隔离验证 `-define:ODIN_TEST_NAMES=` 三组（cli 4 / matcher 5 / scan 8）→ 全部通过。
- Ran: 重建后再次 `./run.sh new` + `diff -r base new` → **diff_exit=0**。
- Ran: 边界重复命中实验（3 MiB，命中落在 2 MiB 分片边界与边界+8）→ 基线与新二进制
  输出**完全一致**（边界处各重复一次），确认该行为为既有语义，已写入 README 与 ADR。
- 新增：`README.md`（结构 / 职责 / 测试 / 已知行为）、`test.sh`、`.ai-memory/adr/0001-*.md`、
  `.gitattributes`、`.editorconfig`。
- 拆分后规模：生产 15 文件 1343 行（含注释），测试 11 文件 59 用例，二进制 246944 B
  （基线 246528 B，差异来自测试代码被一并编译）。
