# Progress Log

## 2026-10-07
- Ran: `wc -l *.odin` → 生产15+测试11 共 5074 行。
- Ran: `grep '^test_[a-z0-9_]*'` → 盘点现有 105 用例名，避免重名。
- Ran: `./test.sh` → exit 0，105 用例全绿、0 leak。（基线）

## 2026-10-07 扩充测试与基准
- 改动文件：common_test / scan_test / walk_test / matcher_test / merge_test /
  output_queue_test / task_pool_test / worker_test(新) / bench / selftest / README。
- 新增用例 24 个：**105 → 129**，全部通过，0 leak、0 bad free。
  - common_test +1（模式表访问器）
  - scan_test +7（输出模式真值表 ×2、Run_Stats 累加、-m 截断、-l/-L 计数不变、
    多模式端到端、分片重叠窗口契约）
  - walk_test +5（空输入/不可读目录、strip_dot_slash、join_path、walk_hidden、
    walk_excluded/walk_glob_ok）
  - matcher_test +3（差分测试、多重集并集、Progress 上报字节数）
  - merge_test +2（8 路随机分片多重集、全同偏移）
  - output_queue_test +1（4 生产者 × 250 条）
  - task_pool_test +1（4 线程 × 200 任务恰好一次）
  - worker_test(新) +4（偏移改写、多任务/空池、多模式分派、输出线程 -m 计数）
- Ran: `odin check .` → exit 0（无类型/语法错误）
- Ran: `odin test . -linker:lld` → 129 tests successful，连跑 3 次无抖动
- Ran: `odin test . -linker:lld -define:ODIN_TEST_THREADS=1` → 129 tests successful
- Ran: `./test.sh` → exit 0（单测 + 内建自检 11 项全 OK）
- Ran: `./xrep --bench` → 7.5s，输出 10 个 case + 4 档线程伸缩（8 线程 5.95x）

## 尝试与失败记录
1. 差分测试最初把小写化结果写在 `if ci {}` 块内并 `defer delete` → Odin defer 是
   **块作用域**，if 块结束即释放，后续比对读到已释放内存，表现为"参考实现少报一半
   命中"。修复：把 `low_data` 提到循环外（函数体顶层 defer），`low_pat` 用显式
   delete 紧跟 ref_offsets。
2. `worker_test` 释放分片列表时外层 dynamic 数组报 `+++ bad free`：它的底层内存是
   worker 线程里首次 `append` 扩容出来的（那里 context 已是 default_context），
   因此**内外两层**都要用 `runtime.default_context().allocator` 释放。
3. 三处期望值写错（已修）：SCAN_SAMPLE 里 "world" 在偏移 11 而非 12；
   "foo test bar testfoo" 里 "test" 出现 2 次（4 条而非 3 条）；
   `walk_hidden("..weird")` 为 true（只看首字符是否为 '.'）。
4. `--bench` 用 `%9.2f` 右对齐，Odin 对数字宽度默认**补 0**（打印成 001355.42）。
   改用空格填充标志 `% 9.2f`（' ' 紧跟 %）。