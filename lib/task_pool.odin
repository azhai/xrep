#+dialect hela
package lib

// ============================================================================
// task_pool.odin — 扫描任务池（ADR 0010：Mutex + 动态数组 → core:hela/queue 无锁 MPMC）
//
// 职责：以 [start, end) 字节区间为单位登记待扫描分片；多个 worker 并发地从池中
//       取任务，取完即退出。池本身是"抢占式"的：谁能取到谁就干，天然负载均衡。
//
// 为什么换：旧实现是一把 `sync.Mutex` 保护 `[dynamic]Scan_Task` 的 LIFO 弹出。
//       `core:hela/queue.Queue` 是 Vyukov 有界 MPMC 环——push/pop 各自一次 CAS，
//       没有锁、没有临界区，N 个 worker 抢任务不再串行化在一把互斥锁上。
//       顺序从 LIFO 变为 FIFO：对结果正确性无影响（命中集合与顺序无关，
//       跨分片顺序由 merge_ordered_matches 恢复），局部性差异由实测吸收
//       （bench 基线对比见 progress.md）。
//
// 容量契约：有界队列需要 2 的幂容量。分片数在启动时是已知量
//       （ceil(file_size / TASK_CHUNK_SIZE)），调用方用 `pool_capacity_for`
//       取整后传入；push 因此只会成功——返回值仍被调用方检查，契约显式。
// ============================================================================

import "core:hela/queue"

// 一个待扫描的字节区间（左闭右开）。#explicit：两个 uint 逐字节声明，
// 无隐式 padding（64 位与 32 位下均如此）。
Scan_Task :: struct #explicit {
    start: uint,
    end:   uint,
}

// 任务池：无锁多生产者多消费者队列。`queue.Queue` 的游标各占一条 cache line，
// 由其自身的 `#atomic #share` 契约保证不伪共享——这些字节事实也随清单导出。
Task_Pool :: struct {
    q: queue.Queue(Scan_Task),
}

// pool_capacity_for 给出容纳 `tasks` 个任务的 2 的幂容量（至少 16，保底有界）。
pool_capacity_for :: proc(tasks: int) -> int {
    cap := 16
    for cap < tasks {
        cap *= 2
    }
    return cap
}

// 取出一个任务；池空时返回 ok=false（worker 据此结束循环）。
task_pool_pop :: proc(p: ^Task_Pool) -> (ok: bool, task: Scan_Task) {
    t, got := queue.pop(&p.q)
    return got, t
}

// 入队一个任务；池满时返回 false（容量契约下不应发生，调用方 fail-fast）。
task_pool_push :: proc(p: ^Task_Pool, t: Scan_Task) -> bool {
    return queue.push(&p.q, t)
}

task_pool_init :: proc(p: ^Task_Pool, capacity: int, allocator := context.allocator) -> bool {
    return queue.init(&p.q, capacity, allocator)
}

task_pool_destroy :: proc(p: ^Task_Pool, allocator := context.allocator) {
    queue.destroy(&p.q, allocator)
}
