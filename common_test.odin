package main

// ============================================================================
// common_test.odin — 基础层单元测试
//
// 覆盖：lower_table 填充规则（含非字母字节透传）、s2b 零拷贝视图语义、
//       arena_make/arena_free 生命周期。
// 注意：`lower_table` 由 common.odin 的 `@(init)` 过程在进程启动时填充，
//       main 与 `odin test` 走同一条启动路径，因此用例**无需**手动初始化。
// ============================================================================

import "core:mem"
import "core:testing"

@(test)
test_lower_table_contents :: proc(t: ^testing.T) {
    // 表内容自检：验证 `@(init)` 已正确填充（不再需要用例自行调用 init）。

    // 大写字母 → 小写
    testing.expect_value(t, lower_table[int('A')], u8('a'))
    testing.expect_value(t, lower_table[int('Z')], u8('z'))
    // 小写字母、数字、标点、高字节应原样透传
    testing.expect_value(t, lower_table[int('a')], u8('a'))
    testing.expect_value(t, lower_table[int('0')], u8('0'))
    testing.expect_value(t, lower_table[int('_')], u8('_'))
    testing.expect_value(t, lower_table[0x00], u8(0x00))
    testing.expect_value(t, lower_table[0x80], u8(0x80))
    testing.expect_value(t, lower_table[0xFF], u8(0xFF))
    // 边界：'A'-1（'@'）与 'Z'+1（'['）不属于字母区间，必须保持原值
    testing.expect_value(t, lower_table[int('@')], u8('@'))
    testing.expect_value(t, lower_table[int('[')], u8('['))

    // 全表扫描自检：仅 A..Z 被改写，其余恒等
    for i in 0..<256 {
        c := u8(i)
        want := c
        if c >= 'A' && c <= 'Z' {
            want = c - 'A' + 'a'
        }
        if lower_table[i] != want {
            testing.expectf(t, false, "lower_table[%d] = %d, want %d", i, lower_table[i], want)
            return
        }
    }
}

@(test)
test_s2b_is_zero_copy_view :: proc(t: ^testing.T) {
    s := "hello"
    b := s2b(s)
    testing.expect_value(t, len(b), 5)
    testing.expect_value(t, b[0], u8('h'))
    testing.expect_value(t, b[4], u8('o'))
    testing.expect_value(t, len(s2b("")), 0)

    // 零拷贝证明：视图首元素地址与原字符串起始地址相同（共享底层内存，非复制）。
    testing.expect(t, rawptr(&b[0]) == rawptr(raw_data(s)), "s2b 应与源字符串共享内存")
    // 字节视图与字符视图长度一致（单字节字符场景）
    testing.expect_value(t, len(b), len(s))
}

@(test)
test_arena_make_and_free :: proc(t: ^testing.T) {
    arena: mem.Arena
    arena_make(&arena, 1024)
    testing.expect(t, arena.data != nil, "arena.data 已分配")
    testing.expect_value(t, len(arena.data), 1024)

    // 分配器可用：从 arena 分配后 reset 可复用容量
    alloc := mem.arena_allocator(&arena)
    buf := make([]u8, 64, alloc)
    testing.expect_value(t, len(buf), 64)
    mem.arena_free_all(&arena)

    arena_free(&arena)
}

// ---------------------------------------------------------------------------
// clamp_thread_count（--threads 范围校验的纯函数部分）
// ---------------------------------------------------------------------------

@(test)
test_clamp_thread_count :: proc(t: ^testing.T) {
    // 0 / 1 → 至少 1：0 个 worker 会让任务无人消费，结果静默变成 0 命中
    testing.expect_value(t, clamp_thread_count(0, 32), uint(1))
    testing.expect_value(t, clamp_thread_count(1, 32), uint(1))
    // 区间内原样返回（含上界本身）
    testing.expect_value(t, clamp_thread_count(8, 32), uint(8))
    testing.expect_value(t, clamp_thread_count(32, 32), uint(32))
    // 超上限 → 夹到 max（防止创建上千线程拖垮进程）
    testing.expect_value(t, clamp_thread_count(100000, 32), uint(32))
    // max_threads == 0（核心数探测失败）→ 退回 FALLBACK_MAX_THREADS
    testing.expect_value(t, clamp_thread_count(0, 0), uint(1))
    testing.expect_value(t, clamp_thread_count(100000, 0), uint(FALLBACK_MAX_THREADS))
    testing.expect_value(t, clamp_thread_count(FALLBACK_MAX_THREADS + 1, 0), uint(FALLBACK_MAX_THREADS))
}

@(test)
test_runtime_constants_sane :: proc(t: ^testing.T) {
    // 常量抽取后仍需满足基本不变量，避免误调
    testing.expect(t, TASK_CHUNK_SIZE > 0, "分片大小必须为正")
    testing.expect(t, CHUNK_OVERLAP > 0, "重叠窗口必须为正")
    testing.expect(t, ARENA_BLOCK_SIZE > 0, "arena 容量必须为正")
    testing.expect(t, PROGRESS_MIN_INTERVAL > 0, "进度刷新间隔必须为正")
    testing.expect(t, MAX_THREADS_FACTOR >= 1, "线程数上限倍数至少为 1")
    testing.expect(t, FALLBACK_MAX_THREADS >= DEFAULT_THREAD_COUNT, "兜底上界不应小于默认线程数")
}
