package main

// ============================================================================
// worker.odin — 扫描线程与输出线程
//
// 职责：
//   * worker_steal — 扫描工作线程：循环从 Task_Pool 抢任务 → 调用匹配算法 →
//     把命中分流给"输出队列"（实时打印）与"命中列表"（汇总给上层）。
//   * output_thread — 输出线程：唯一消费者，串行打印，保证终端输出不交错。
//
// 依赖：core:fmt、core:sync、core:mem、base:runtime。
// 并发约定：
//   - 线程入口的第一步是 `context = runtime.default_context()`：Odin 创建线程时
//     会复制创建者的 context，因此 worker 默认继承调用方的分配器。生产环境下
//     main 的分配器就是堆分配器，继承与不继承等价；但在 `odin test` 下，
//     测试运行器会把分配器换成 mem.Tracking_Allocator —— 它内部是**无锁 map**，
//     被多个线程并发分配会写坏其数据结构，实测表现为偶发 SIGBUS（退出码 138）。
//     显式归一化后，线程行为与创建者无关，也让泄漏追踪只统计真正的泄漏。
//   - 分配器归一化后，worker 内所有 make/append 都走堆；命中数组来自 arena
//     （由 matcher 显式指定），两者互不干扰。
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:sync"

// 线程参数聚合体。用结构体打包而非多个全局变量，是为了让线程入口只依赖一个
// rawptr，也让"哪些数据被共享"一目了然（凡是指针字段均为跨线程共享）。
worker_data :: struct {
    file_data: []u8,
    ctx:       Match_Ctx,
    tp:        ^Task_Pool, // 共享：任务来源
    ap:        ^Arena_Pool, // 共享：结果分配器池
    out_q:     ^Output_Queue, // 共享：实时输出队列
    out_list:  ^[dynamic][]Match_Result, // 共享：命中汇总（受 list_mu 保护）
    list_mu:   ^sync.Mutex,
    progress:  ^Progress,
}

// 扫描线程主体。
worker_steal :: proc(data: rawptr) {
    // 先归一化线程上下文（原因见文件头"并发约定"）：不继承创建者的分配器。
    context = runtime.default_context()
    w := cast(^worker_data)data
    // 算法在启动时按模式长度选定一次，循环内复用。
    matcher := select_matcher(uint(len(w.ctx.pattern)))
    n := uint(len(w.file_data))
    for {
        ok, task := task_pool_pop(w.tp)
        if !ok {
            break
        }
        // 分片边界可能切断一个匹配，因此向后多扫 CHUNK_OVERLAP 字节；
        // 代价是分片尾部会重复产出命中，由上层 offset 过滤（--after/--before）
        // 与 dump 语义消化，不影响"是否存在命中"的判定。
        overlap := uint(CHUNK_OVERLAP)
        end_scan := task.end + overlap
        if end_scan > n {
            end_scan = n
        }
        scan_region := w.file_data[task.start:end_scan]
        arena := arena_pool_get(w.ap)
        matches := matcher(scan_region, w.ctx, arena, w.progress)
        // 把分片内相对偏移转成文件内绝对偏移，并送入输出队列（实时打印）。
        for m in 0..<len(matches) {
            matches[m].offset += u64(task.start)
            output_queue_push(w.out_q, Output_Item{offset = matches[m].offset})
        }
        // 深拷贝到堆：arena 归还后会被 arena_free_all 清空（offset 归零、内存复用），
        // 直接持有 arena 切片迟早会读到脏数据。
        // 注意此处必须真的落在堆上——matcher 不再改写 context.allocator 之后
        // 这个前提才成立（见 matcher.odin 文件头的"内存约定"）。
        stable := make([]Match_Result, len(matches))
        copy(stable, matches)
        sync.mutex_lock(w.list_mu)
        append(w.out_list, stable)
        sync.mutex_unlock(w.list_mu)
        arena_pool_put(w.ap, arena)
    }
}

// 输出线程参数。
// 注意 ctx 字段实际承载的是 --context 的**字节数**（沿用原命名），
// 与 worker_data.ctx（Match_Ctx）不同义。
output_data :: struct {
    q:          ^Output_Queue,
    file_data:  []u8,
    pat_len:    uint,
    ctx:        uint, // --context N 的 N
    use_color:  bool,
    only_count: bool,
    offset_hex: bool,
    out_hits:   ^uint, // 共享：命中计数（受 hit_mu 保护）
    hit_mu:     ^sync.Mutex,
    quiet:      bool,
}

// 输出线程主体：从队列取命中，打印偏移（可选上下文 hex），并累加计数。
// --quiet 与 --count 仍然计数，只是不打印明细。
output_thread :: proc(data: rawptr) {
    // 同 worker_steal：线程入口先归一化上下文，避免继承测试运行器的追踪分配器。
    context = runtime.default_context()
    w := cast(^output_data)data
    for {
        ok, item := output_queue_pop(w.q)
        if !ok {
            break
        }
        sync.mutex_lock(w.hit_mu)
        w.out_hits^ += 1
        sync.mutex_unlock(w.hit_mu)
        if w.quiet || w.only_count {
            continue
        }
        if w.offset_hex {
            fmt.printf("match offset: 0x%x\n", item.offset)
        } else {
            fmt.printf("match offset: %d\n", item.offset)
        }
        if w.ctx > 0 {
            print_context(w.file_data, item.offset, w.pat_len, w.ctx, w.use_color)
        }
    }
}
