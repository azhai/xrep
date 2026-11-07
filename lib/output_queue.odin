#+dialect hela
package lib

// ============================================================================
// output_queue.odin — 生产者/消费者输出队列（ADR 0010：Mutex+Cond → core:hela/queue）
//
// 职责：解耦"扫描"(生产者，多线程) 与"打印"(消费者，单线程)，保证输出顺序
//       稳定且不阻塞扫描；队列带 done 标志，消费者在队列空且生产者全部结束后
//       才会退出等待。
//
// 为什么换：旧实现是 Mutex + Cond + 手写环形缓冲（出队 O(1)，ADR 0008 改的）。
//       三块状态、两把原语。现在队列本体换成 `core:hela/queue.Queue`（Vyukov
//       无锁 MPMC，游标行由其内部契约隔离），外部只剩一个 `done` 标志：
//       `#atomic` 声明"它用原子操作访问"，`#share(controller)` 声明"只有
//       controller（scan_region_parallel 在全部 worker join 之后）写它"——
//       这两句话由编译器检查、随清单导出，不再靠文件头注释自觉。
//
// 等待方式的变化：消费者从 cond_wait 阻塞改为「空转 + cpu_relax」自旋。
//       这是有意取舍：打印线程的消费速度远低于 SIMD 扫描速度，队列鲜少长时间
//       为空；且批次总量有限，最坏情况也只是这一轮扫描期间多烧一个核的空转。
//       换来的是删除 Mutex/Cond 后，push/pop 路径上没有任何系统调用。
//
// 有界与反压：容量固定 OUTPUT_QUEUE_CAP（2 的幂）。满时 push 自旋重试而不是
//       扩容——这正是反压：打印跟不上时扫描线程减速，而不是无界吃内存。
//       旧版无界扩容在稠密命中（每 4 B 一条）下会堆积数百 MB；新版上限
//       = OUTPUT_QUEUE_CAP * 16 B。
// ============================================================================

import "core:hela/queue"
import "core:sync"

// 输出队列容量（2 的幂）。稠密命中下这是扫描与打印之间的全部缓冲，
// 超过即反压扫描线程。
OUTPUT_QUEUE_CAP :: 4096

Output_Item :: struct #explicit {
    offset:  u64,
    pat_len: u32, // 命中长度：多模式时可能是任一模式的长度；0 表示未标注
    _:       [4]u8, // 显式命名的对齐空隙
}

#assert(size_of(Output_Item) == 16)

// 生产者/消费者队列。`done` 独占一条 cache line：它被 controller 写一次、
// 被消费者反复读，不与队列游标共享行。
Output_Queue :: struct {
    q: queue.Queue(Output_Item),
    #align(64) #atomic #share(controller) done: u64,
}

output_queue_init :: proc(q: ^Output_Queue, capacity := OUTPUT_QUEUE_CAP, allocator := context.allocator) -> bool {
    sync.atomic_store_explicit(&q.done, 0, .Relaxed)
    return queue.init(&q.q, capacity, allocator)
}

// 入队；队列满时自旋等待消费者腾出槽位（反压），不会丢消息。
output_queue_push :: proc(q: ^Output_Queue, item: Output_Item) {
    for !queue.push(&q.q, item) {
        sync.cpu_relax()
    }
}

// 出队（FIFO）。等待条件与旧版一致：队列空且未结束 → 等待；
// 无元素且已 done → 返回 ok=false，消费者据此退出。
output_queue_pop :: proc(q: ^Output_Queue) -> (ok: bool, item: Output_Item) {
    for {
        it, got := queue.pop(&q.q)
        if got {
            item = it
            return true, item
        }
        if sync.atomic_load_explicit(&q.done, .Acquire) != 0 {
            return false, {}
        }
        sync.cpu_relax()
    }
}

// 队列中待消费的元素个数（供测试与诊断使用）。
// `queue.length` 是游标差的近似读数（诊断用途，语义见 hela/queue 的注释）。
output_queue_len :: proc(q: ^Output_Queue) -> uint {
    return uint(queue.length(&q.q))
}

// 标记生产结束：消费者下一次发现队列空时退出。
// 并发约定（由 #share 声明）：只能在**所有生产者结束后**调用，
// 否则消费者会提前退出并丢掉尚未入队的命中。
output_queue_set_done :: proc(q: ^Output_Queue) {
    sync.atomic_store_explicit(&q.done, 1, .Release)
}

output_queue_destroy :: proc(q: ^Output_Queue, allocator := context.allocator) {
    queue.destroy(&q.q, allocator)
}
