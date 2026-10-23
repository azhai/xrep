package lib

// ============================================================================
// base_test.odin — 基础层单元测试
//
// 覆盖：lower_table 填充规则（含非字母字节透传）、s2b 零拷贝视图语义、
//       运行期常量不变量。
// 注意：`lower_table` 由 base.odin 的 `@(init)` 过程在进程启动时填充，
//       main 与 `odin test` 走同一条启动路径，因此用例**无需**手动初始化。
// ============================================================================

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

// ---------------------------------------------------------------------------
// 模式表访问器（multi_match 的取模式入口）
// ---------------------------------------------------------------------------

@(test)
test_ctx_pattern_accessors :: proc(t: ^testing.T) {
    // 单模式：主模式独占 0 号槽位，模式表长度为 1
    single := Match_Ctx{pattern = s2b("ab")}
    testing.expect_value(t, ctx_pattern_count(single), 1)
    testing.expect_value(t, string(ctx_pattern_at(single, 0)), "ab")

    // 多模式：索引 0 恒为主模式，其余按 extra 顺序排列
    multi := Match_Ctx{pattern = s2b("ab"), extra = [][]u8{s2b("cd"), s2b("ef")}}
    testing.expect_value(t, ctx_pattern_count(multi), 3)
    testing.expect_value(t, string(ctx_pattern_at(multi, 0)), "ab")
    testing.expect_value(t, string(ctx_pattern_at(multi, 1)), "cd")
    testing.expect_value(t, string(ctx_pattern_at(multi, 2)), "ef")

    // 边界：extra 为空切片（而非 nil）时长度仍是 1 —— -f 读到空文件就会是这种形状
    empty_extra := Match_Ctx{pattern = s2b("z"), extra = [][]u8{}}
    testing.expect_value(t, ctx_pattern_count(empty_extra), 1)

    // 空模式**仍然占槽**：由 multi_match 负责跳过（见 matcher.odin），
    // 这里锁住"占槽"这一事实，避免有人改成过滤后改变模式编号语义。
    blanks := Match_Ctx{pattern = s2b(""), extra = [][]u8{s2b("")}}
    testing.expect_value(t, ctx_pattern_count(blanks), 2)
    testing.expect_value(t, len(ctx_pattern_at(blanks, 0)), 0)
    testing.expect_value(t, len(ctx_pattern_at(blanks, 1)), 0)
}

@(test)
test_runtime_constants_sane :: proc(t: ^testing.T) {
    // 常量抽取后仍需满足基本不变量，避免误调
    testing.expect(t, TASK_CHUNK_SIZE > 0, "分片大小必须为正")
    testing.expect(t, CHUNK_OVERLAP > 0, "重叠窗口必须为正")
    testing.expect(t, PROGRESS_MIN_INTERVAL > 0, "进度刷新间隔必须为正")
    testing.expect(t, MAX_THREADS_FACTOR >= 1, "线程数上限倍数至少为 1")
    testing.expect(t, FALLBACK_MAX_THREADS >= DEFAULT_THREAD_COUNT, "兜底上界不应小于默认线程数")
}
