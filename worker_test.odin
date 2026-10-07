package main

// ============================================================================
// worker_test.odin — 扫描线程与输出线程的单元测试
//
// 覆盖：
//   * worker_steal：命中偏移从"分片内相对"改写为"文件绝对"（--after/--before、
//     --dump 与行号全部依赖这个改写）、多个任务产出多个分片列表、空任务池立即退出；
//   * output_thread：-m/--max-count 同时约束计数与打印（README ADR 0005）、
//     max_count=0 表示不限、done 之后立即退出、silent 模式只计数。
//
// 为什么只断言"计数"而不是输出文本：输出线程把明细写到**进程级 stdout**，而
// `odin test` 默认并行跑用例 —— 捕获或重定向 fd 1 会与其它用例互相污染，
// 属于用不可靠的断言换覆盖面。输出文本由 README「行为验收矩阵」的外部命令矩阵
// 把关；这里只断言 output_data.out_hits 这个无歧义的可观察出口。
//
// 内存约定（两条都踩过坑）：
//   1. 线程入口会 `context = runtime.default_context()`，因此命中数组分配在
//      **进程默认堆**上。测试在主线程释放它们时必须显式带上同一个分配器
//      （`delete(x, runtime.default_context().allocator)`），
//      否则 `odin test` 的追踪分配器会去 free 堆指针，直接报 "bad free"。
//   2. 分片列表的**外层**动态数组由主线程分配（普通 delete 即可），
//      内层切片才需要默认分配器 —— 两者别搞混。
// ============================================================================

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"

// 喂给输出线程的样例数据（silent 模式下不会被读，仅为让字段非空）
WORKER_SAMPLE :: "....test...."

// 起一个 worker 线程把给定任务取空，返回它挂进 out_list 的分片列表。
// 返回值由**调用方**拥有：外层切片用普通 delete，内层用默认分配器 delete。
run_worker_once :: proc(wd_in: worker_data, tasks: []Scan_Task) -> [][]Match_Result {
    lists: [dynamic][]Match_Result
    tp: Task_Pool
    task_pool_init(&tp)
    for task in tasks {
        task_pool_push(&tp, task)
    }
    list_mu: sync.Mutex

    // 形参不可赋值：复制一份再挂上共享资源（Odin proc 形参是只读的）。
    wd := wd_in
    wd.tp = &tp
    wd.out_list = &lists
    wd.list_mu = &list_mu

    th := thread.create_and_start_with_data(&wd, worker_steal)
    thread.join(th)
    thread.destroy(th)
    task_pool_destroy(&tp)
    return lists[:]
}

// 释放分片列表：**内外两层都要用默认分配器**。
// 内层命中数组由 matcher 在 worker 线程里分配（默认堆）；外层 dynamic 数组同样
// 是被 worker 的 append 首次扩容出来的 —— 那里 context 已是 default_context，
// 于是它的底层内存也在默认堆上。若在主线程用默认的追踪分配器去 free，
// 会得到 "bad free"。
free_match_lists :: proc(lists: [][]Match_Result) {
    for lst in lists {
        if lst != nil {
            delete(lst, runtime.default_context().allocator)
        }
    }
    delete(lists, runtime.default_context().allocator)
}

// 构造一个只关心命中的 worker 参数（输出队列由调用方持有）。
worker_probe :: proc(file_data: []u8, q: ^Output_Queue, p: ^Progress, extra: [][]u8 = nil) -> worker_data {
    return worker_data{
        file_data = file_data,
        ctx = Match_Ctx{pattern = s2b("test"), case_insensitive = false, extra = extra},
        out_q = q,
        progress = p,
    }
}

// 造一段以 'z' 填充、只在给定偏移埋入 "test" 的数据（调用方 delete）。
make_probe_data :: proc(size: int, marks: []int) -> []u8 {
    data := make([]u8, size)
    for i in 0..<size {
        data[i] = 'z'
    }
    for off in marks {
        copy(data[off:off + 4], s2b("test"))
    }
    return data
}

@(test)
test_worker_steal_rebases_offsets_to_absolute :: proc(t: ^testing.T) {
    // 关键契约：matcher 返回的是**分片内相对**偏移，worker 必须加上 task.start
    // 改写成文件绝对偏移。若漏了这里，--after/--before、--dump 与行号会全部错位。
    data := make_probe_data(200, []int{100})
    defer delete(data)

    p: Progress
    progress_init(&p, u64(len(data)), false, false)
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    // 任务只覆盖 [96, 110)，命中位于分片内相对偏移 4
    lists := run_worker_once(worker_probe(data, &q, &p), []Scan_Task{{start = 96, end = 110}})
    defer free_match_lists(lists)

    testing.expect_value(t, len(lists), 1)
    testing.expect_value(t, len(lists[0]), 1)
    testing.expect_value(t, lists[0][0].offset, u64(100)) // 不是 4
    testing.expect_value(t, lists[0][0].pat_len, u32(4))

    // 同一批命中也进了输出队列（实时打印路径拿到的必须是绝对偏移）
    output_queue_set_done(&q)
    ok, item := output_queue_pop(&q)
    testing.expect(t, ok, "输出队列应收到一条命中")
    testing.expect_value(t, item.offset, u64(100))
    testing.expect_value(t, item.pat_len, u32(4))
    ok2, _ := output_queue_pop(&q)
    testing.expect(t, !ok2, "不应有多余命中")
}

@(test)
test_worker_steal_multiple_tasks_and_empty_pool :: proc(t: ^testing.T) {
    data := make_probe_data(300, []int{10, 200})
    defer delete(data)

    p: Progress
    progress_init(&p, u64(len(data)), false, false)
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    // 两个任务 → 两个分片列表，每个恰好一条（顺序由 LIFO 决定，不作假设）
    tasks := []Scan_Task{{start = 0, end = 100}, {start = 100, end = 300}}
    lists := run_worker_once(worker_probe(data, &q, &p), tasks)
    defer free_match_lists(lists)

    testing.expect_value(t, len(lists), 2)
    seen := false
    for lst in lists {
        testing.expect_value(t, len(lst), 1)
        testing.expect(t, lst[0].offset == 10 || lst[0].offset == 200, "命中偏移应为 10 或 200")
        if lst[0].offset == 200 {
            seen = true
        }
    }
    testing.expect(t, seen, "两个任务的结果都应出现")

    // 空任务池：worker 立刻退出，不产出任何列表（不会挂起）
    lists_empty := run_worker_once(worker_probe(data, &q, &p), []Scan_Task{})
    defer free_match_lists(lists_empty)
    testing.expect_value(t, len(lists_empty), 0)
}

@(test)
test_worker_steal_dispatches_multi_pattern :: proc(t: ^testing.T) {
    // worker 用的是 select_matcher_for：给了 extra 就必须走 multi_match，
    // 而不是"只找主模式"（那会静默少报命中）。
    data := make([]u8, 200)
    defer delete(data)
    for i in 0..<len(data) {
        data[i] = '.'
    }
    copy(data[50:54], s2b("test"))
    copy(data[120:124], s2b("XYZW"))

    p: Progress
    progress_init(&p, u64(len(data)), false, false)
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    wd := worker_probe(data, &q, &p, [][]u8{s2b("XYZW")})
    lists := run_worker_once(wd, []Scan_Task{{start = 0, end = 200}})
    defer free_match_lists(lists)

    testing.expect_value(t, len(lists), 1)
    testing.expect_value(t, len(lists[0]), 2)
    has_main, has_extra := false, false
    for m in lists[0] {
        if m.offset == 50 { has_main = true }
        if m.offset == 120 { has_extra = true }
    }
    testing.expect(t, has_main, "主模式命中应出现")
    testing.expect(t, has_extra, "额外模式命中也应出现（否则走了单模式分派）")
}

// 把 items 条命中喂给输出线程（silent 模式：只计数不打印），返回它累加的计数。
run_output_thread :: proc(items: int, max_count: uint) -> uint {
    q: Output_Queue
    output_queue_init(&q)
    defer output_queue_destroy(&q)

    hits: uint = 0
    mu: sync.Mutex
    od := output_data{
        q = &q,
        file_data = s2b(WORKER_SAMPLE),
        pat_len = 4,
        max_count = max_count,
        silent = true,
        out_hits = &hits,
        hit_mu = &mu,
    }

    th := thread.create_and_start_with_data(&od, output_thread)
    for i in 0..<items {
        output_queue_push(&q, Output_Item{offset = u64(i), pat_len = 4})
    }
    output_queue_set_done(&q)
    thread.join(th)
    thread.destroy(th)
    return hits
}

@(test)
test_output_thread_counting_contract :: proc(t: ^testing.T) {
    // 空队列 + done：消费者立即退出，计数为 0（不阻塞、不崩溃）
    testing.expect_value(t, run_output_thread(0, 0), uint(0))

    // max_count = 0（默认）：全部计数
    testing.expect_value(t, run_output_thread(10, 0), uint(10))

    // 契约（ADR 0005）：-m N 同时约束计数与打印 —— 第 N+1 条起既不计数也不打印。
    testing.expect_value(t, run_output_thread(10, 1), uint(1))
    testing.expect_value(t, run_output_thread(10, 3), uint(3))

    // -m 大于命中数：不补齐，仍是实际到达的条数
    testing.expect_value(t, run_output_thread(10, 20), uint(10))
    // -m 等于命中数：恰好全收
    testing.expect_value(t, run_output_thread(10, 10), uint(10))
}