#!/usr/bin/env bash
#
# xrep 测试脚本
#
# 说明：
#   - 与 build.sh 同源问题：PATH 里的 `clang` 可能被 Android NDK 的 x86_64 clang
#     抢先占用，导致 Odin 链接 .o 失败（unknown file type）。因此显式指定
#     ODIN_CC 为系统 Apple clang，并强制 lld 链接器。
#     `odin test` 与 `odin build` 走同一套后端，故同样需要该环境修正。
#   - **内存追踪保持开启**（不再传 -define:ODIN_TEST_TRACK_MEMORY=false）。
#     历史上这里是关掉的，原因是测试运行器的 mem.Tracking_Allocator 非线程安全
#     （内部是无锁 map），而被测代码会创建 worker 线程并继承该分配器，
#     并发分配会写坏它的数据结构 → 偶发 SIGBUS（退出码 138）与大量误导性 leak。
#     现在根因已在源码侧修掉：worker.odin / output_thread 入口统一
#     `context = runtime.default_context()`，线程不再继承调用方的分配器。
#     追踪因此可以常开 —— 任何新增的真实泄漏都会立刻以 leak 告警暴露出来。
#   - **顺序有讲究**：`odin test .` 会把仓库里的 ./xrep 覆盖成测试产物并在结束时
#     删除它，所以内建自检必须放在 `./build.sh` 之后（先测后编译）。
#
# 运行内容：
#   1. odin test .   —— 单元测试（*_test.odin，覆盖各核心模块，含内存泄漏检查）
#   2. ./xrep --test —— 随二进制分发的内建自检（进程内冒烟）
#
# 常用变体：
#   只跑单个用例：
#     odin test . -linker:lld -define:ODIN_TEST_NAMES=main.<用例名>
#   串行执行（排查并发问题时更容易读日志）：
#     odin test . -linker:lld -define:ODIN_TEST_THREADS=1
#
set -euo pipefail

cd "$(dirname "$0")"

if [[ -x /usr/bin/clang ]]; then
  export ODIN_CC="${ODIN_CC:-/usr/bin/clang}"
fi

echo "ODIN_CC = ${ODIN_CC:-<系统默认>}"
echo "==== odin test . （内存追踪开启）===="
odin test . -linker:lld

echo "==== 内建自检: ./xrep --test ===="
./build.sh > /dev/null
./xrep --test

echo "==== 全部测试完成 ===="
