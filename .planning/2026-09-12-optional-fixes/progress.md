# progress — 可选修复项 + 新增 flag（2026-09-12）

## 命令与结果日志

### 阶段 0：核实前提
```
grep -rn "mmap\|simd" *.odin          → 无匹配（清单两条前提不成立）
xrep test /tmp/p.txt --limit 2 --dump /tmp/d1.txt --quiet
  → dump 行数 = 4（不是 2）；--count 报 4 hits ⇒ drop-2 不影响 dump/count
xrep test ./sample.bin --dump-prefix out_ --quiet
  → stderr: Failed to open dump file out_./sample.bin.txt: Not_Exist（0 文件产出）
xrep test /tmp/p.txt --threads 0 --count        → "0 hits"（静默错误）
xrep test /tmp/p.txt --threads 100000 --quiet   → timeout 15s，exit 124（挂死）
xrep test /tmp/p.txt --dump /nonexistent_dir_xyz/o.txt --quiet → exit 0（失败被吞）
```

### 阶段 1：用户决策
- `--dump-prefix` → 直接改成清洗
- `--limit` → 保持现状
- 范围 → 推荐 5 项 + 易用性

### 阶段 2：实现期间的错误与修复
```
odin check . → Syntax Error: Expected ';', got case   （cli.odin 162 行换行被吞）
  原因：同一条消息里对 cli.odin 发了两条 Edit，后一条基于原始快照覆盖前一条。
  修复：改为整份 Write。
odin check . → Undeclared name 'Version' / 'print_version' / 'skip_empty'
  同因（Options/Parse_Outcome 的那次 Edit 被覆盖）。
odin check . → Cannot assign to 'max_threads'（proc 形参不可赋值）→ 改局部变量 cap。
odin check . → Assignment count mismatch '1' = '2'（scan_file 现在返回两个值）
  → `_ = scan_file(...)` 改 `_, _ = scan_file(...)`。

=== 关键运行时 bug ===
xrep test b.bin --dump /tmp/x1.txt --quiet → dump 内容 = 9 / 0 / 0（应为 6 / 17 / 28）
  而 --count 报 3 hits 正确、流式 "match offset" 打印也正确。
  根因：Odin 的 defer 是**块作用域**。
        if file_size > 0 { filtered = ...; defer delete(filtered) }  ← 在本 if 结束即释放
        落盘时读已释放内存 → 垃圾偏移；len 在栈上未变所以计数仍对。
  探针验证：/tmp/odin_defer（if 内 defer 打印在 "after if" 之前）。
  修法：defer 提到函数体顶层，`defer { if filtered != nil { delete(filtered) } }`。

run2.sh 首次运行 4 个 FAIL —— 全部是**验收脚本自身**写错，非代码问题：
  1/2. 期望文件名写成 out__sample.bin.txt，实际 out_._sample.bin.txt
       （`.` 是安全字符会被保留，只有 `/ \ :` 等被替换）
  3/4. `run test test f1.bin ...` 多写一个 test，导致变成双文件扫描，
       最后一行成了汇总行而非 --count 行
```

### 阶段 3/4：验证
```
./build.sh                                     → exit 0
ODIN_CC=/usr/bin/clang odin check .            → 无输出（无告警）
./test.sh                                      → Finished 77 tests ... All tests were successful
                                                 内建自检 === All tests passed ===

原 47 条矩阵（/tmp/xrep_verify/run.sh） vs 改动前二进制：
  diff -rq → 仅 5 个文件不同：help.out / help_h.out / noargs.out /
             err_no_file.out / empty_pattern.out（全部是 help 文本，因新增 flag 说明）
  过滤这 5 个后逐条 diff → 无差异
  dump 内容抽查：dump_single=6/17/28、dump_hex=0x6/0x11/0x1c、dumpprefix=6/17/28 ✓
  exit code 抽查：test_flag=0 help=0 noargs=1 dump_conflict=1 missing_file=0 big_t0=0 ✓

新增行为矩阵 /tmp/xrep_verify/run2.sh → PASS=27 FAIL=0
  --version/-v/即时退出、threads=0 与 100000（含"未挂死"）、
  dump-prefix 清洗（文件名 + 无中间目录 + 内容）、
  落盘失败 exit 1、--skip-empty、--dump-append、--max-size、
  多文件汇总行与 quiet 抑制、空文件路径
```

## 最终决定：不做的事
- 不实现 mmap / SIMD 相关优化（代码里不存在对应实现）
- 不改 `--limit` 的 drop-2（保留契约，只加测试钉死）
- 未实现清单中的：`--min-size`、glob 自动展开、arena shrink_to_fit、
  按需 chunk 自适应（最多 64 任务）、`--dump-unsorted` 边扫边写
