package lib

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

// 环形缓冲的初始槽位数。与旧实现（动态数组 + 出队时整体左移）的初始容量一致。
OUTPUT_QUEUE_MIN_CAP :: 64

Output_Item :: struct {
    offset:  u64,
    pat_len: u32, // 命中长度：多模式时可能是任一模式的长度；0 表示未标注
}

// 生产者/消费者队列，内部是**环形缓冲**。
//
// 数据布局（ADR 0008）：`items` 的 `len` 恒等于**槽位总数**（容量），
// 元素个数另由 `count` 记录，队首在 `head`。入队写 `(head+count) % cap`，
// 出队读 `head` 后 `head` 前进一格 —— 两者都是 O(1)。
//
// 为什么改：旧实现出队是"整体左移 + pop 尾部"，单次 O(队列长度)。消费者
// （打印）比生产者（SIMD 扫描）慢时队列会堆积，总代价是 O(n²) —— 稠密命中
// 场景（每 4 字节一条）正是这种形态。改环形后出队与队列长度无关。
Output_Queue :: struct {
    mu:    sync.Mutex,
    cond:  sync.Cond,
    items: [dynamic]Output_Item, // len == 槽位数（容量），不是元素数
    head:  uint, // 队首槽位
    count: uint, // 元素个数
    done:  bool,
}

output_queue_init :: proc(q: ^Output_Queue) {
    // len 必须等于容量：环形写入按索引访问 items[i]，不依赖动态数组的 len 语义。
    q.items = make([dynamic]Output_Item, OUTPUT_QUEUE_MIN_CAP)
    q.head = 0
    q.count = 0
    q.done = false
}

// 槽位满时扩容一倍，并把环形内容**按顺序**搬到新缓冲的开头（head 归零）。
// 只在持锁时调用（由 output_queue_push 保证）。
output_queue_grow :: proc(q: ^Output_Queue) {
    old_cap := uint(len(q.items))
    new_cap := old_cap * 2
    if new_cap < OUTPUT_QUEUE_MIN_CAP {
        new_cap = OUTPUT_QUEUE_MIN_CAP
    }
    buf := make([dynamic]Output_Item, int(new_cap))
    // 从 head 起按 FIFO 顺序拷出 count 个元素到新缓冲的 [0, count)。
    for i in 0..<q.count {
        buf[i] = q.items[(q.head + i) % old_cap]
    }
    delete(q.items)
    q.items = buf
    q.head = 0
}

// 入队并唤醒一个等待中的消费者。
output_queue_push :: proc(q: ^Output_Queue, item: Output_Item) {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    if q.count >= uint(len(q.items)) {
        output_queue_grow(q)
    }
    slots := uint(len(q.items))
    q.items[(q.head + q.count) % slots] = item
    q.count += 1
    sync.cond_signal(&q.cond)
}

// 阻塞式出队（FIFO）。
// 等待条件：队列为空**且**未结束 → 继续睡；否则：
//   - 有元素 → 取队首（O(1)，只挪动 head 游标）；
//   - 无元素且已 done → 返回 ok=false，消费者据此退出。
output_queue_pop :: proc(q: ^Output_Queue) -> (ok: bool, item: Output_Item) {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    for q.count == 0 && !q.done {
        sync.cond_wait(&q.cond, &q.mu)
    }
    if q.count == 0 {
        return false, {}
    }
    slots := uint(len(q.items))
    item = q.items[q.head]
    q.head = (q.head + 1) % slots
    q.count -= 1
    return true, item
}

// 队列中待消费的元素个数（供测试与诊断使用；调用方不必持锁语义）。
output_queue_len :: proc(q: ^Output_Queue) -> uint {
    sync.mutex_lock(&q.mu)
    defer sync.mutex_unlock(&q.mu)
    return q.count
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
    q.head = 0
    q.count = 0
}
