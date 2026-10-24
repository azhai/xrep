# 进度：位并行 BNDM / Aho-Corasick / 稀疏行号表（ADR 0009）

## 目标

补完 ADR 0008 登记为"未做"的两项，并把行号表改稀疏。**每项都要有对照组**，
结论以实测为准（允许结论是"不该用"）。

## 完成情况

### 1. 位并行 BNDM —— 完成，但定位变了

- [x] `bndm_match` 实现 u64 位掩码 + 反向窗口 + `last` 移位
- [x] 差分测试把它加进参照组（1..70 字节模式 × 大小写两态 × 随机数据）
- [x] A/B 对拍（`--bench` A4 组）
- [x] 按实测定位：**退化出口**而非主路径（`memchr_match` 密度 >1/4 时接管剩余区间）

| 数据 | memchr | bndm |
| --- | --- | --- |
| uniform | 34115 MB/s | 7670 MB/s |
| dense | 87 MB/s | 164 MB/s |
| zeros | 814 MB/s | 836 MB/s |

### 2. Aho-Corasick —— 完成

- [x] `search/ac.odin`：两遍构建（字母表压缩 → trie → BFS 补 fail/完全转移表/输出链接）
- [x] 延迟线保序：按起点分桶 + 延迟 `max_len` 字节倒出 + 桶内按模式序号插入排序
- [x] `search/ac_test.odin`（8 个用例，含与 `multi_match` 的逐条比对）
- [x] 阈值：真实文本实测交叉点 16 个模式 → `AC_MIN_PATTERNS = 16`
- [x] 端到端 md5 对照：4/16/32 模式 × `--count`/`-n`/`--json`/`-o`/`--dump` 全一致

真实文本（100 MiB 源码，`-f` N 个词，单线程 `--count`）：

| N | multi_match | multi_ac |
| --- | --- | --- |
| 4 | 0.16 s | 0.50 s |
| 8 | 0.34 s | 0.52 s |
| 16 | 0.68 s | 0.53 s |
| 32 | 1.31 s | 0.54 s |

### 3. 稀疏行号表 —— 完成

- [x] `Line_Index { marks, stride, data }` + 自适应抽稀（上限 256K 标记）
- [x] `line_of(li, offset, hint)`：二分 + 块内回扫 + `Line_Hint` 增量快路径
- [x] `line_index_destroy`；`scan.odin` / `worker.odin` 同步（`output_data.line_hint`）
- [x] 差分测试：40 万行数据抽稀后**逐偏移**对照"边走边数"参照，快慢两路都覆盖

| 300 万行 / 3M 命中，`-n` | 稠密（旧） | 稀疏无提示 | 稀疏 + 提示 |
| --- | --- | --- | --- |
| 耗时 | 1.04 s | 2.20 s | **0.91 s** |
| 峰值 RSS | 437 MB | — | **408 MB** |

### 4. 基准与文档

- [x] `--bench` 加 A5 组（稀疏数据测多模式纯扫描成本）
- [x] 修 A3 的模式生成 bug（步长 16 撞上 256 周期 → 64 个"模式"其实 16 个不同）
- [x] `alg_name` 补 `multi_ac`（否则打印 "?"）
- [x] ADR 0009、README（文件表 / 测试表 / 性能章节 / 契约 #4 / ADR 清单）
- [x] `.workbuddy/memory`（性能分档章节 + 今日日志）

## 验收

- `./test.sh`：140 用例全绿，0 泄漏（lib 19 / search 34 / engine 26 / app 61）
- `./verify.sh`：护栏 28 + golden 78 + run2 34 + run3 56 全部通过
- `-n` 输出与改动前 `cmp` 逐字节一致

## 未做（已登记理由）

- AC 输出链接在"大量模式共享后缀"时会重复展开（正确但非最优）
- `-n` 在跨分片乱序到达时提示命中率下降（可接受，已有乱序测试）
- 更细的行号索引分层（三级索引）—— 当前 2 MB 上限已够
