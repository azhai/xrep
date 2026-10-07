package main

// ============================================================================
// task_pool_test.odin — 任务池单元测试
//
// 覆盖：空池出队返回 false、入队/出队 LIFO 顺序、全部取空后重复出队、
//       单条任务、区间字段在传递过程中不被篡改，
//       以及多线程并发弹出时"每个任务被取走恰好一次"。
//
// 线程上下文：自建线程的入口必须先 `context = runtime.default_context()` ——
//       `odin test` 下调用方的分配器是 mem.Tracking_Allocator（内部无锁 map），
//       多线程并发 append 会写坏它（实测 SIGBUS）。见 worker.odin 文件头。
// ============================================================================

import "base:runtime"
import "core:testing"
import "core:thread"

// 并发弹出测试的规模（文件作用域常量：嵌套 proc 不构成闭包，无法捕获外层局部量）
POOL_WORKERS :: 4
POOL_TASKS :: 200

// 每个 worker 一份独立参数副本：row 指向位图中属于它自己的一行。
// 各 worker 只写自己那一行 → 无需再上一把锁（地址互不重叠）。
pool_worker_data :: struct {
    tp:  ^Task_Pool,
    row: []u8,
}

pool_worker :: proc(data: rawptr) {
    context = runtime.default_context()
    w := cast(^pool_worker_data)data
    for {
        ok, task := task_pool_pop(w.tp)
        if !ok {
            break
        }
        w.row[task.start] = 1 // 任务 start 即其编号
    }
}

@(test)
test_task_pool_empty_pop :: proc(t: ^testing.T) {
    p: Task_Pool
    task_pool_init(&p)
    defer task_pool_destroy(&p)

    // 边界：空池出队必须失败且任务为零值
    ok, task := task_pool_pop(&p)
    testing.expect(t, !ok, "空池出队应返回 false")
    testing.expect_value(t, task.start, uint(0))
    testing.expect_value(t, task.end, uint(0))
    // 连续多次出队仍然安全
    ok2, _ := task_pool_pop(&p)
    testing.expect(t, !ok2, "空池重复出队仍应返回 false")
}

@(test)
test_task_pool_lifo_order :: proc(t: ^testing.T) {
    p: Task_Pool
    task_pool_init(&p)
    defer task_pool_destroy(&p)

    task_pool_push(&p, Scan_Task{start = 0, end = 10})
    task_pool_push(&p, Scan_Task{start = 10, end = 20})
    task_pool_push(&p, Scan_Task{start = 20, end = 30})

    // pop 取尾部（LIFO）
    ok1, a := task_pool_pop(&p)
    testing.expect(t, ok1)
    testing.expect_value(t, a.start, uint(20))
    testing.expect_value(t, a.end, uint(30))

    ok2, b := task_pool_pop(&p)
    testing.expect(t, ok2)
    testing.expect_value(t, b.start, uint(10))

    ok3, c := task_pool_pop(&p)
    testing.expect(t, ok3)
    testing.expect_value(t, c.start, uint(0))
    testing.expect_value(t, c.end, uint(10))

    // 取空后回到失败态：可安全地被多个 worker 反复调用
    ok4, _ := task_pool_pop(&p)
    testing.expect(t, !ok4, "取空后应返回 false")
}

@(test)
test_task_pool_single_and_reuse :: proc(t: ^testing.T) {
    p: Task_Pool
    task_pool_init(&p)
    defer task_pool_destroy(&p)

    // 边界：单任务
    task_pool_push(&p, Scan_Task{start = 12345, end = 67890})
    ok_s, task := task_pool_pop(&p)
    testing.expect(t, ok_s)
    testing.expect_value(t, task.start, uint(12345))
    testing.expect_value(t, task.end, uint(67890))

    // 边界：取空后可继续入队（池可复用）
    ok_after, _ := task_pool_pop(&p)
    testing.expect(t, !ok_after)
    task_pool_push(&p, Scan_Task{start = 7, end = 8})
    ok2, task2 := task_pool_pop(&p)
    testing.expect(t, ok2)
    testing.expect_value(t, task2.start, uint(7))
    testing.expect_value(t, task2.end, uint(8))
}

@(test)
test_task_pool_concurrent_pop_each_task_once :: proc(t: ^testing.T) {
    // 4 个 worker 抢同一个池：每个任务必须被弹出**恰好一次** ——
    // 既不能丢（漏扫一段字节，结果会少命中），也不能重（同一段被扫两遍，
    // 表现为重叠窗口之外的重复命中）。这是 Task_Pool 唯一的并发不变量。
    p: Task_Pool
    task_pool_init(&p)
    defer task_pool_destroy(&p)
    for i in 0..<POOL_TASKS {
        task_pool_push(&p, Scan_Task{start = uint(i), end = uint(i) + 1})
    }

    grid := make([]u8, POOL_WORKERS * POOL_TASKS)
    defer delete(grid)

    args := make([]pool_worker_data, POOL_WORKERS)
    defer delete(args)
    threads := make([dynamic]^thread.Thread, 0, POOL_WORKERS)
    defer delete(threads)
    for w in 0..<POOL_WORKERS {
        args[w] = pool_worker_data{tp = &p, row = grid[w * POOL_TASKS:]}
        append(&threads, thread.create_and_start_with_data(&args[w], pool_worker))
    }
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }

    for task in 0..<POOL_TASKS {
        pops := 0
        for w in 0..<POOL_WORKERS {
            pops += int(grid[w * POOL_TASKS + task])
        }
        testing.expectf(t, pops == 1, "任务 %d 被弹出 %d 次（应为 1）", task, pops)
    }
    total := 0
    for i in 0..<len(grid) {
        total += int(grid[i])
    }
    testing.expect_value(t, total, POOL_TASKS)
}
