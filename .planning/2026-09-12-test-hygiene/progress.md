# 执行日志 — 测试崩溃与泄漏修复（2026-09-12）

命令与结果按时间顺序。

```
# 1) 复现
./test.sh                                  → exit 0（77/77），但 stderr 混有 leak 告警
odin test . -linker:lld                    → exit 138（SIGBUS）   [4/5 次]
odin test . -linker:lld -define:ODIN_TEST_THREADS=1  → exit 0      [5/5 次]

# 2) 根因确认（读 Odin 源码）
grep -n "Tracking_Allocator :: struct" -A 6 core/mem/tracking_allocator.odin
  → allocation_map: map[rawptr]Tracking_Allocator_Entry   （无锁）
grep -n "create_and_start_with_data ::" -A 12 core/thread/thread.odin
  → 复制创建者的 context

# 3) 探针：确认 context.allocator 劫持的落点
/tmp/odin_arena_probe: x[0]=0x965400008 arena.data=[0x965400008,+65536]  → true（落在 arena 内）

# 4) 探针：@(init) 在 odin test 下是否执行 + 常量 proc 表
/tmp/odin_init_probe: odin test 读到 lower=[1,2,3,4]、len(table)=2  → 可用
（注意：@(init) 必须是 "contextless"，否则报错）

# 5) 实施修复后
odin test . -linker:lld    ×10             → 10/10 exit 0，0 条 "+++ leak"
./test.sh                                  → exit 0，77/77 + 内建自检全绿
odin check .                               → 无告警

# 6) 行为等价
cd /tmp/xrep_verify && ./run.sh /opt/repos/xrep/xrep gate && diff -r final gate
  → diff 行数 = 0（stdout/stderr/exit code/dump 内容全部一致）
./run2.sh /opt/repos/xrep/xrep             → PASS=27 FAIL=0

# 7) 多分片正确性复验（allocator 语义改动后）
dense.bin (2.5 MiB, 65 万命中) → dump 655364 行、逆序 0、非4倍数 0、重复仅 4 处（契约内）
asym.bin (分片1 少 + 分片2 多)  → offset 100 保留
big.bin 5 MiB                 → 7 hits（6 处埋点 + 1 处边界重复，与基线一致）
```

## 失败/踩坑记录（避免重犯）
- 排查中出现 `./xrep: No such file or directory` 与 `exit 127`，曾误判为"二进制被误删"。
  真因：**`odin test .` 编译测试产物时占用并最终删除仓库里的 `./xrep`**。
- `grep "leak" /tmp/s*.txt` 匹配到了上一轮遗留的 `/tmp/s_1.txt`…，一度以为修完仍有泄漏。
  教训：按 mtime 或明确文件名核对，别用宽通配符 glob 判断。
- 同一条消息里对同一文件发两个 `Edit` 会互相覆盖 → 本轮改为"一个文件一次改完/整份 Write"。
