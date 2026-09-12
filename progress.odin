package main

// ============================================================================
// progress.odin — 进度条
//
// 职责：把"已扫描字节 / 总字节"渲染成终端进度条（\r 原地刷新，200ms 限流）。
//
// 依赖：core:fmt、core:os、core:sync、core:time。
// 行为约定（保持既有语义）：
//   - enabled=false 时 progress_add 直接返回，**连 scanned 都不累加**；
//     因此关闭进度条时 scanned 恒为 0，progress_render 不会输出百分比。
//   - 限流只作用于 add（自动刷新），progress_finish 会强制渲染一次收尾。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

Progress :: struct {
    mu:          sync.Mutex,
    total:       u64, // 总字节数；为 0 时不做任何渲染
    scanned:     u64, // 已扫描字节数
    last_render: time.Time, // 上次刷新时刻，用于 200ms 限流
    use_color:   bool, // 是否输出 ANSI 颜色
    enabled:     bool, // 总开关（--quiet 时关闭）
}

progress_init :: proc(p: ^Progress, total_bytes: u64, use_color: bool, enabled: bool) {
    p.total = total_bytes
    p.scanned = 0
    // 以当前时刻为基准，保证启动后第一次 add 不会立刻刷新（限流从 init 起算）。
    p.last_render = time.now()
    p.use_color = use_color
    p.enabled = enabled
}

// 累加已扫描字节。仅在满足限流间隔时才真正刷新终端。
// 调用点位于多线程热路径，内部用 Mutex 保护，避免进度条出现撕裂输出。
progress_add :: proc(p: ^Progress, bytes: u64) {
    if !p.enabled {
        return
    }
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    p.scanned += bytes
    now := time.now()
    // 限流：最少间隔 PROGRESS_MIN_INTERVAL 刷新（常量见 common.odin）
    if time.since(p.last_render) < PROGRESS_MIN_INTERVAL {
        return
    }
    p.last_render = now
    progress_render(p)
}

// 渲染一行进度条：`[####----] 12.34% 已扫/总量 bytes`。
// 调用方需自行持锁（progress_add / progress_finish 已加锁）。
progress_render :: proc(p: ^Progress) {
    if p.total == 0 {
        return
    }
    percent := f64(p.scanned) / f64(p.total) * 100.0
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
    fmt.printf(" %.2f%% %d/%d bytes", percent, p.scanned, p.total)
    // 进度条无换行，需显式 flush 才能立即可见。
    os.flush(os.stdout)
}

// 收尾：强制渲染最终状态并换行，避免后续输出接在进度条同一行上。
progress_finish :: proc(p: ^Progress) {
    if !p.enabled {
        return
    }
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    progress_render(p)
    fmt.println()
}

progress_destroy :: proc(p: ^Progress) {
}
