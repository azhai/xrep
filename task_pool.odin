package main

// ============================================================================
// task_pool.odin — 扫描任务池（工作窃取的任务来源）
//
// 职责：以 [start, end) 字节区间为单位登记待扫描分片；多个 worker 并发地从池中
//       取任务，取完即退出。池本身是"抢占式"的：谁能取到谁就干，天然负载均衡。
//
// 依赖：core:sync。
// 约束：tasks 为动态数组，pop 取尾部（LIFO）。LIFO 顺序对结果正确性无影响
//       （命中集合与顺序无关，跨分片顺序由 merge_ordered_matches 恢复），
//       但有利于提升缓存局部性。
// ============================================================================

import "core:sync"

// 一个待扫描的字节区间（左闭右开）。
Scan_Task :: struct {
    start: uint,
    end:   uint,
}

// 任务池：简单 Mutex 保护，临界区仅覆盖出/入队，不覆盖实际扫描。
Task_Pool :: struct {
    mu:    sync.Mutex,
    tasks: [dynamic]Scan_Task,
}

// 取出一个任务；池空时返回 ok=false（worker 据此结束循环）。
task_pool_pop :: proc(p: ^Task_Pool) -> (ok: bool, task: Scan_Task) {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    if len(p.tasks) == 0 {
        return false, {}
    }
    return true, pop(&p.tasks)
}

task_pool_push :: proc(p: ^Task_Pool, t: Scan_Task) {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    append(&p.tasks, t)
}

task_pool_init :: proc(p: ^Task_Pool) {
    p.tasks = make([dynamic]Scan_Task)
}

task_pool_destroy :: proc(p: ^Task_Pool) {
    delete(p.tasks)
}
