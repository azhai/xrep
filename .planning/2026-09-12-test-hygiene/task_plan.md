# 任务计划 — 修掉测试崩溃 + 清零泄漏（2026-09-12）

目标：用户报"测试有报错"。查明是崩溃还是断言/噪声，修掉；并把相关约定系统更新到 README。

## 阶段

- [x] P1 复现并定位：`./test.sh` 通过但裸跑 `odin test .` 4/5 次 SIGBUS（exit 138）
- [x] P2 二分根因：串行 runner 5/5 通过 → 指向"多线程 runner + 追踪分配器"
- [x] P3 读 Odin 源码确认：`Tracking_Allocator` 用无锁 map；Odin 线程复制创建者 context
- [x] P4 顺带审计分配器/所有权问题（matcher 劫持、merge 临时缓冲、测试侧未释放）
- [x] P5 实施修复（worker 上下文归一化、matcher 显式 arena、merge 释放、全局表 @(init)/常量、
      cli.file_list 所有权）
- [x] P6 测试侧修复（merge/slice/scan 用例释放；output_queue 线程入口归一化）
- [x] P7 `test.sh` 恢复内存追踪
- [x] P8 门禁：build / odin check / test.sh（77 全绿 + 0 leak）/ 47 条矩阵 diff=0 / 新增矩阵 27 PASS
- [x] P9 文档：README（新增「并发与内存约定」+ 重写「测试」）、ADR 0003、MEMORY、技能

## 恢复点
全部完成。下一步若继续：可选做 README 里列出的未实现项（mmap/SIMD 不存在无需做）、
或把 47 条矩阵脚本收进仓库（现仍在 `/tmp/xrep_verify/`）。
