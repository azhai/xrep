package main

// ============================================================================
// output_queue.odin — 生产者/消费者输出队列
//
// 职责：解耦"扫描"(生产者，多线程) 与"打印"(消费者，单线程)，保证输出顺序
//       稳定且不阻塞扫描；队列带 done 标志，消费者在队列空且生产者全部结束后
//       才会退出等待。
//
// 依赖：core:sync（Mutex + Cond）。
// 并发约定：done 只能由生产端在**所有生产者结束后**置位，否则消费者会提前退出
//           并丢掉尚未入队的命中。
// ============================================================================

import "core:sync"

Output_Item :: struct {
    offset: u64,
}

Output_Queue :: struct {
    mu:    sync.Mutex,
    cond:  sync.Cond,
    items: [dynamic]Output_Item,
    done:  bool,
}

output_queue_init :: proc(q: ^Output_Queue) {
    q.items = make([dynamic]Output_Item, 0, 64)
    q.done = false
}

// 入队并唤醒一个等待中的消费者。
output_queue_push :: proc(q: ^Output_Queue, item: Output_Item) {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    append(&q.items, item)
    sync.cond_signal(&q.cond)
}

// 阻塞式出队（FIFO）。
// 等待条件：队列为空**且**未结束 → 继续睡；否则：
//   - 有元素 → 从头部取走，保证先进先出；
//   - 无元素且已 done → 返回 ok=false，消费者据此退出。
// 移除队首采用"整体左移 + pop 尾部"，在队列长度通常很短（消费者跟得上）时
// 比引入环形缓冲更简单。
output_queue_pop :: proc(q: ^Output_Queue) -> (ok: bool, item: Output_Item) {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    for len(q.items) == 0 && !q.done {
        sync.cond_wait(&q.cond, &q.mu)
    }
    if len(q.items) == 0 {
        return false, {}
    }
    item = q.items[0]
    for i in 0..<len(q.items) - 1 {
        q.items[i] = q.items[i + 1]
    }
    pop(&q.items)
    return true, item
}

// 标记生产结束并广播，确保所有等待中的消费者被唤醒退出。
output_queue_set_done :: proc(q: ^Output_Queue) {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    q.done = true
    sync.cond_broadcast(&q.cond)
}

output_queue_destroy :: proc(q: ^Output_Queue) {
    delete(q.items)
}
