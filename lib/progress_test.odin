#+dialect hela
package lib

// ============================================================================
// progress_test.odin — 进度条单元测试
//
// 覆盖：初始化字段、enabled=false 时"不累加 scanned"的既有语义、
//       启用时累加且首次 add 不触发渲染（200ms 限流从 init 起算）、
//       以及 total=0 / finish 的边界行为。
//
// 说明：progress_render 会向 stdout 输出，因此用例尽量避开渲染路径
//       （选择 total=0 或 disabled），断言聚焦可观察状态而非终端文本。
// ADR 0010：Progress 无锁化后，scanned / last_render_ns 是 #atomic 字段，
//       用例一律经 sync.atomic_* 读写；限流常量也换成纳秒（PROGRESS_MIN_INTERVAL_NS）。
// ============================================================================

import "core:sync"
import "core:testing"

@(test)
test_progress_init_fields :: proc(t: ^testing.T) {
    p: Progress
    progress_init(&p, 1024, true, true)
    testing.expect_value(t, p.total, u64(1024))
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(0))
    testing.expect_value(t, p.use_color, true)
    testing.expect_value(t, p.enabled, true)

    // 变体：彩色关闭 / 进度禁用
    p2: Progress
    progress_init(&p2, 0, false, false)
    testing.expect_value(t, p2.use_color, false)
    testing.expect_value(t, p2.enabled, false)
}

@(test)
test_progress_disabled_does_not_accumulate :: proc(t: ^testing.T) {
    // 既有语义：enabled=false 时 progress_add 提前返回，scanned 保持 0。
    p: Progress
    progress_init(&p, 100, false, false)
    progress_add(&p, 10)
    progress_add(&p, 90)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(0))

    // progress_finish 在禁用时同样是 no-op
    progress_finish(&p)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(0))
}

@(test)
test_progress_enabled_accumulates_with_throttle :: proc(t: ^testing.T) {
    p: Progress
    // total=0 使 progress_render 立即返回，从而测"累加但不渲染"的路径。
    progress_init(&p, 0, false, true)
    init_ns := sync.atomic_load_explicit(&p.last_render_ns, .Relaxed)

    progress_add(&p, 1)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(1))
    progress_add(&p, 41)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(42))

    // 首次 add 距 init 不足 200ms，渲染权 CAS 不放行 → last_render_ns 仍是 init 时刻
    testing.expect(t, sync.atomic_load_explicit(&p.last_render_ns, .Relaxed) == init_ns,
        "200ms 内不应推进 last_render_ns")

    // 边界：add(0) 不改变计数
    progress_add(&p, 0)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(42))
}

@(test)
test_progress_add_after_interval_advances_render_time :: proc(t: ^testing.T) {
    p: Progress
    progress_init(&p, 0, false, true)

    // 人工把 last_render_ns 拨到 1 秒前，验证限流放行且它被推进。
    sync.atomic_store_explicit(&p.last_render_ns,
        sync.atomic_load_explicit(&p.last_render_ns, .Relaxed) - PROGRESS_MIN_INTERVAL_NS * 5, .Relaxed)
    before := sync.atomic_load_explicit(&p.last_render_ns, .Relaxed)
    progress_add(&p, 5)
    testing.expect_value(t, sync.atomic_load_explicit(&p.scanned, .Relaxed), u64(5))
    testing.expect(t, sync.atomic_load_explicit(&p.last_render_ns, .Relaxed) > before,
        "超过限流间隔后应推进 last_render_ns")

    // progress_finish 对 total=0 的实例不渲染，但不应报错
    progress_finish(&p)
}

@(test)
test_progress_render_zero_total_is_noop :: proc(t: ^testing.T) {
    // 边界：total=0 时渲染直接返回（避免除以 0 得到 NaN%）。
    p: Progress
    progress_init(&p, 0, true, true)
    progress_add(&p, 0)
    progress_render(&p) // 应无输出、无异常
    testing.expect_value(t, p.total, u64(0))
    progress_destroy(&p) // 当前为空实现，调用必须安全
}
