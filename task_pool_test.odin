package main

// ============================================================================
// task_pool_test.odin — 任务池单元测试
//
// 覆盖：空池出队返回 false、入队/出队 LIFO 顺序、全部取空后重复出队、
//       单条任务、以及区间字段在传递过程中不被篡改。
// ============================================================================

import "core:testing"

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
