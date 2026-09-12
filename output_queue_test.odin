package main

// ============================================================================
// output_queue_test.odin — 输出队列单元测试
//
// 覆盖：FIFO 顺序、done 之后空队列返回 false（消费者退出条件）、
//       done 之后仍有元素时先取完再退出、重复 set_done 幂等。
//
// 说明：这些用例刻意"先 push 再 set_done 再 pop"，因此不依赖线程即可确定性
//       地覆盖退出路径；若先 pop 会阻塞等待 cond（生产端尚未置 done）。
//
// 线程上下文：自建线程的入口必须先把 context 归一化（见 worker.odin 文件头）。
//       Odin 创建线程时复制创建者的 context，`odin test` 下那正是测试运行器的
//       mem.Tracking_Allocator —— 它内部是无锁 map，两个线程并发分配会写坏它
//       （实测 SIGBUS）。output_queue_push 内部 append 会分配，因此这条必须做。
// ============================================================================

import "base:runtime"
import "core:testing"
import "core:thread"

// 并发往返测试的元素个数（文件作用域常量：嵌套 proc 不构成闭包，无法捕获外层局部量）
OUT_Q_TEST_N :: 500

@(test)
test_output_queue_fifo_after_done :: proc(t: ^testing.T) {
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    output_queue_push(&q, Output_Item{offset = 10})
    output_queue_push(&q, Output_Item{offset = 20})
    output_queue_push(&q, Output_Item{offset = 30})
    output_queue_set_done(&q)

    // FIFO：先进先出，且 done 不会让已有元素丢失
    ok1, i1 := output_queue_pop(&q)
    testing.expect(t, ok1, "队列非空时应取到元素")
    testing.expect_value(t, i1.offset, u64(10))
    ok2, i2 := output_queue_pop(&q)
    testing.expect(t, ok2)
    testing.expect_value(t, i2.offset, u64(20))
    ok3, i3 := output_queue_pop(&q)
    testing.expect(t, ok3)
    testing.expect_value(t, i3.offset, u64(30))

    // 取空且 done → 返回 false，消费者据此退出
    ok4, i4 := output_queue_pop(&q)
    testing.expect(t, !ok4, "空队列且 done 时应返回 false")
    testing.expect_value(t, i4.offset, u64(0))
}

@(test)
test_output_queue_done_without_items :: proc(t: ^testing.T) {
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    // 边界：没有任何元素即结束 → 立即返回 false（不阻塞）
    output_queue_set_done(&q)
    ok_a, _ := output_queue_pop(&q)
    testing.expect(t, !ok_a, "direct done 后应立即返回 false")
    // 重复调用仍然安全
    ok_b, _ := output_queue_pop(&q)
    testing.expect(t, !ok_b)
}

@(test)
test_output_queue_set_done_idempotent :: proc(t: ^testing.T) {
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    testing.expect(t, !q.done, "初始 done 应为 false")
    output_queue_set_done(&q)
    output_queue_set_done(&q) // 重复置位不应出错
    testing.expect(t, q.done, "done 应为 true")

    // 结束后仍可 push（既有语义：set_done 不禁止入队），且能取出
    output_queue_push(&q, Output_Item{offset = 77})
    ok_c, item := output_queue_pop(&q)
    testing.expect(t, ok_c)
    testing.expect_value(t, item.offset, u64(77))
}

@(test)
test_output_queue_concurrent_roundtrip :: proc(t: ^testing.T) {
    // 端到端并发验证：1 个生产者 + 1 个消费者，校验总数与顺序完整。
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    producer :: proc(data: rawptr) {
        // 线程入口归一化上下文：不要继承调用方的分配器（尤其是测试运行器的
        // 追踪分配器，非线程安全）。
        context = runtime.default_context()
        pq := cast(^Output_Queue)data
        for i in 0..<OUT_Q_TEST_N {
            output_queue_push(pq, Output_Item{offset = u64(i)})
        }
        output_queue_set_done(pq)
    }

    th := thread.create_and_start_with_data(&q, producer)
    count := 0
    expect := u64(0)
    for {
        ok, item := output_queue_pop(&q)
        if !ok {
            break
        }
        testing.expect_value(t, item.offset, expect)
        expect += 1
        count += 1
    }
    thread.join(th)
    thread.destroy(th)
    testing.expect_value(t, count, OUT_Q_TEST_N)
}
