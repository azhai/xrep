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
import "core:sync"
import "core:testing"
import "core:thread"

// 并发往返测试的元素个数（文件作用域常量：嵌套 proc 不构成闭包，无法捕获外层局部量）
OUT_Q_TEST_N :: 500

// 多生产者压力测试的规模
OUT_Q_PRODUCERS :: 4
OUT_Q_PER_PRODUCER :: 250
// 偏移编码：producer*OUT_Q_STRIDE + 序号，消费侧据此还原来源
OUT_Q_STRIDE :: 1000

// 每个生产者一份参数副本：idx / per 是自己的；q / remaining / mu 是共享的。
multi_producer_data :: struct {
    q:         ^Output_Queue,
    remaining: ^int, // 尚未结束的生产者数（受 mu 保护）
    mu:        ^sync.Mutex,
    idx:       int,
    per:       int,
}

// 生产者：顺序推入自己的序号，然后登记退出。
// **最后一个退出的生产者**负责置 done —— 消费者阻塞在 cond_wait 上，
// 必须有人唤醒；而 done 又只能在"所有生产者都结束"之后置位（见 output_queue.odin
// 文件头的并发约定），因此这里需要一把独立的计数锁。
multi_producer :: proc(data: rawptr) {
    context = runtime.default_context()
    ps := cast(^multi_producer_data)data
    for i in 0..<ps.per {
        output_queue_push(ps.q, Output_Item{offset = u64(ps.idx * OUT_Q_STRIDE + i)})
    }
    sync.mutex_lock(ps.mu)
    ps.remaining^ -= 1
    last := ps.remaining^ == 0
    sync.mutex_unlock(ps.mu)
    if last {
        output_queue_set_done(ps.q)
    }
}

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

@(test)
test_output_queue_multi_producer_complete_and_ordered :: proc(t: ^testing.T) {
    // 4 个生产者 × 250 条，单消费者。校验两件事：
    //   1. 总数完整（1000 条一条不少 —— 丢一条就意味着终端输出少一行命中）；
    //   2. **每个生产者各自的顺序**保持（队列是 FIFO，同一生产者的相邻两次
    //      push 之间不可能插入它自己的后继）→ 命中明细不会自相交错。
    // 注意：跨生产者之间的相对顺序不作要求（那本来就是调度决定的）。
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    mu: sync.Mutex
    remaining := OUT_Q_PRODUCERS
    args := make([]multi_producer_data, OUT_Q_PRODUCERS)
    defer delete(args)
    threads := make([dynamic]^thread.Thread, 0, OUT_Q_PRODUCERS)
    defer delete(threads)
    for w in 0..<OUT_Q_PRODUCERS {
        args[w] = multi_producer_data{
            q = &q,
            remaining = &remaining,
            mu = &mu,
            idx = w,
            per = OUT_Q_PER_PRODUCER,
        }
        append(&threads, thread.create_and_start_with_data(&args[w], multi_producer))
    }

    // 消费侧就在主线程：出队直到 done（由最后一个生产者置位）。
    last_seq := make([]int, OUT_Q_PRODUCERS)
    defer delete(last_seq)
    for w in 0..<OUT_Q_PRODUCERS {
        last_seq[w] = -1
    }
    total := 0
    for {
        ok, item := output_queue_pop(&q)
        if !ok {
            break
        }
        w := int(item.offset / OUT_Q_STRIDE)
        seq := int(item.offset % OUT_Q_STRIDE)
        testing.expectf(t, w >= 0 && w < OUT_Q_PRODUCERS, "偏移 %d 解出非法生产者号 %d", item.offset, w)
        if w < 0 || w >= OUT_Q_PRODUCERS {
            continue
        }
        testing.expectf(t, seq == last_seq[w] + 1, "生产者 %d: 期望序号 %d，实际 %d", w, last_seq[w] + 1, seq)
        last_seq[w] = seq
        total += 1
    }
    for th in threads {
        thread.join(th)
        thread.destroy(th)
    }

    testing.expect_value(t, total, OUT_Q_PRODUCERS * OUT_Q_PER_PRODUCER)
    for w in 0..<OUT_Q_PRODUCERS {
        testing.expectf(t, last_seq[w] == OUT_Q_PER_PRODUCER - 1, "生产者 %d 最后收到序号 %d", w, last_seq[w])
    }
}
