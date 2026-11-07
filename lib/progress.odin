#+dialect hela
package lib

// ============================================================================
// progress.odin — 进度条（ADR 0010：Mutex → 无锁 atomic）
//
// 职责：把"已扫描字节 / 总字节"渲染成终端进度条（\r 原地刷新，200ms 限流）。
//
// 依赖：core:fmt、core:os、core:sync、core:time、core:hela/flow。
// 行为约定（保持既有语义）：
//   - enabled=false 时 progress_add 直接返回，**连 scanned 都不累加**；
//     因此关闭进度条时 scanned 恒为 0，progress_render 不会输出百分比。
//   - 限流只作用于 add（自动刷新），progress_finish 会强制渲染一次收尾。
//
// 并发设计（类型布局见 base.odin 的 Progress）：
//   - scanned：worker 用 atomic_add 累加（.Relaxed 足够，渲染时重新读）；
//   - 渲染权：last_render_ns 用 CAS 抢占。到达 200ms 间隔的线程把
//     last_render_ns 从旧时刻换到 now，谁换成功谁渲染——并发下恰有一个
//     线程 render，终端输出不会撕裂，也不需要那把旧版 Mutex。
//   - finish 在所有线程 join 之后调用，无竞争，直接渲染。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

progress_init :: proc(p: ^Progress, total_bytes: u64, use_color: bool, enabled: bool) {
    p.total = total_bytes
    sync.atomic_store_explicit(&p.scanned, 0, .Relaxed)
    // 以当前时刻为基准，保证启动后第一次 add 不会立刻刷新（限流从 init 起算）。
    sync.atomic_store_explicit(&p.last_render_ns, tick_ns(), .Relaxed)
    p.use_color = use_color
    p.enabled   = enabled
}

// tick_ns：单调时钟的纳秒读数。经 `time.tick_nanoseconds`（回流进 Hela
// core:time 的公开读数，见 .planning 2026-11-07-hela-dialect）取值，不再摸私有字段。
tick_ns :: proc() -> u64 {
    return u64(time.tick_nanoseconds(time.tick_now()))
}

// 累加已扫描字节。仅在抢到渲染权且满足限流间隔时才真正刷新终端。
progress_add :: proc(p: ^Progress, bytes: u64) {
    if !p.enabled {
        return
    }
    sync.atomic_add_explicit(&p.scanned, bytes, .Relaxed)
    if bytes == 0 {
        return
    }
    // 抢渲染权：只有把 last_render_ns 成功从旧值换到 now 的线程渲染。
    now := tick_ns()
    prev := sync.atomic_load_explicit(&p.last_render_ns, .Acquire)
    for now >= prev + PROGRESS_MIN_INTERVAL_NS {
        _, won := sync.atomic_compare_exchange_strong_explicit(
            &p.last_render_ns, prev, now, .Acq_Rel, .Acquire)
        if won {
            progress_render(p)
            return
        }
        // CAS 失败时 prev 已被更新为最新值；要么别人刚渲染过（窗口重置），
        // 要么 now 已落后，循环条件自然退出。
    }
}

// 渲染一行进度条：`[####----] 12.34% 已扫/总量 bytes`。
// 调用方需先取得渲染权（progress_add 的 CAS / progress_finish 的独占期）。
progress_render :: proc(p: ^Progress) {
    if p.total == 0 {
        return
    }
    scanned := sync.atomic_load_explicit(&p.scanned, .Relaxed)
    percent := f64(scanned) / f64(p.total) * 100.0
    bar_width :: 40
    filled := uint(percent / 100.0 * bar_width)
    fmt.print("\r")
    if p.use_color {
        fmt.print(COLOR_GREEN)
    }
    fmt.print("[")
    for i in 0..<bar_width {
        if i < int(filled) {
            fmt.print("#")
        } else {
            fmt.print("-")
        }
    }
    fmt.print("]")
    if p.use_color {
        fmt.print(COLOR_RESET)
    }
    fmt.printf(" %.2f%% %d/%d bytes", percent, scanned, p.total)
    // 进度条无换行，需显式 flush 才能立即可见。
    os.flush(os.stdout)
}

// 收尾：强制渲染最终状态并换行，避免后续输出接在进度条同一行上。
// 无竞争（所有 worker 已 join）：直接更新时刻并渲染。
progress_finish :: proc(p: ^Progress) {
    if !p.enabled {
        return
    }
    sync.atomic_store_explicit(&p.last_render_ns, tick_ns(), .Relaxed)
    progress_render(p)
    fmt.println()
}

progress_destroy :: proc(p: ^Progress) {
    // 当前为空实现（scanned/渲染权都是值字段，无独立资源）。保留签名以兼容调用点。
    _ = p
}
