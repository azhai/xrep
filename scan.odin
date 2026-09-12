package main

// ============================================================================
// scan.odin — 单文件扫描编排
//
// 职责：把"一次完整扫描"的步骤串起来：
//   选路(--max-size 拦截) → 读文件 → [空文件快速跳过] →
//   切分成 [start,end) 任务入池 → 起 N 个 worker + 1 个输出线程 →
//   等待收敛 → 归并各分片命中 → 过滤(--after/--before) →
//   落盘(--dump / --dump-prefix / --skip-empty / --dump-append) →
//   按模式打印统计。
//
// 依赖：io_utils / worker / matcher / merge / 各并发基础设施模块。
// 线程生命周期：worker 先全部 join，再 set_done 唤醒并 join 输出线程，
//               否则输出线程可能在仍有生产者时提前退出丢结果。
//
// 选项以 Scan_Options 结构体传入：本函数参数已随功能增多接近两位数，
// 用结构体承载可避免调用点出现一长串同类型实参（易错且难读）。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

// 一次扫描的全部选项。由 main 从 cli.Options 映射而来；测试直接构造。
Scan_Options :: struct {
    ctx:           Match_Ctx, // 模式与大小写选项
    after:         u64, // 命中偏移下界（闭区间）
    before:        u64, // 命中偏移上界（闭区间）
    limit:         uint, // 仅截断 pretty 汇总（0 = 不截断；见 README 已知行为#3）
    context_bytes: uint, // 命中前后展示的字节数
    only_count:    bool, // 只打印命中总数
    thread_count:  uint, // worker 线程数（<=0 时按 1 处理）
    offset_hex:    bool, // 打印/落盘用十六进制偏移
    dump_path:     string, // --dump 的目标文件（单文件汇总）
    dump_prefix:   string, // --dump-prefix 的前缀
    quiet:         bool, // 完全静默：不打印统计，仅 dump 与 stderr 错误
    skip_empty:    bool, // 命中 0 条时不落盘（--skip-empty）
    dump_append:   bool, // 落盘改为追加（--dump-append）
    max_size:      u64, // >0 时跳过超过该字节数的文件（--max-size）
}

// 扫描单个文件。
// 返回值：
//   hits    — 区间过滤后的命中数
//   dump_ok — 落盘是否成功（未落盘/被跳过视为成功）；false 时错误已写 stderr，
//             调用方据此把进程退出码置为非 0（--fail-fast 语义，见 README）。
scan_file :: proc(path: string, o: Scan_Options) -> (hits: uint, dump_ok: bool) {
    dump_ok = true

    // ---- 0) --max-size 预拦截：读入前先看大小，避免把超大文件整个读进内存 ----
    if o.max_size > 0 {
        if size, ok := file_size_of(path); ok && size > o.max_size {
            // 被跳过的文件不输出任何 stdout 统计（它并非"0 命中"，而是"未扫描"，
            // 打印 0 hits 会误导）。原因固定写 stderr，且**不受 --quiet 抑制**：
            // --quiet 的语义是"不要闲聊"，而"请求的工作没做"必须仍然可见。
            fmt.fprintf(os.stderr, "skip %s: size %d exceeds --max-size %d\n", path, size, o.max_size)
            return 0, true
        }
    }

    file_data, err := read_file_data(path)
    if err != nil {
        fmt.fprintf(os.stderr, "open %s failed: %v\n", path, err)
        return 0, true
    }
    defer delete(file_data)
    file_size := uint(len(file_data))

    // ---- 命中结果：空文件直接为空，避免为一无所有的文件建池起线程 ----
    filtered: []Match_Result
    if file_size > 0 {
        filtered = scan_region_parallel(file_data, o)
    }
    // 重要：Odin 的 defer 是**块作用域**——写在 if 体内会在该 if 结束时就执行。
    // 因此释放必须挂在函数作用域上，否则 filtered 会在落盘读取之前被释放，
    // dump 会写出已释放内存中的垃圾值。
    defer {
        if filtered != nil {
            delete(filtered)
        }
    }

    // ---- 落盘：--dump-prefix 优先；--skip-empty 时不产出空文件 ----
    if !(o.skip_empty && len(filtered) == 0) {
        final_dump_path := o.dump_path
        if len(o.dump_prefix) > 0 {
            // 清洗路径分隔符后再拼接：--dump-prefix 会把输入文件路径直接写进
            // 输出名，含 './' 或子目录的路径会因中间目录不存在而写入失败。
            safe := sanitize_dump_name(path)
            final_dump_path = fmt.tprintf("%s%s.txt", o.dump_prefix, transmute(string)safe)
            delete(safe) // tprintf 已拷贝内容，立即释放（不依赖块作用域 defer）
        }
        if len(final_dump_path) > 0 {
            dump_ok = dump_matches(final_dump_path, filtered, o.offset_hex, o.dump_append)
        }
    }

    // ---- 统计输出（quiet 完全静默，交给调用方聚合）----
    if o.quiet {
        return len(filtered), dump_ok
    }
    if o.only_count {
        fmt.printf("%s: %d hits\n", path, len(filtered))
    } else {
        // 既有行为（契约，见 README 已知行为#3）：pretty 汇总会先丢弃前 2 条命中。
        // --count 与 --dump 使用完整 filtered；此处刻意不做修正。
        dropped := slice_drop(Match_Result, filtered, 2)
        taken := dropped
        if o.limit > 0 {
            taken = slice_take(Match_Result, dropped, o.limit)
        }
        fmt.printf("\n=== %s: %d results ===\n", path, len(taken))
    }
    return len(filtered), dump_ok
}

// 对已读入的整块数据执行并行扫描，返回区间过滤后的命中（按偏移升序）。
// 调用方负责释放返回切片。
scan_region_parallel :: proc(file_data: []u8, o: Scan_Options) -> []Match_Result {
    file_size := uint(len(file_data))
    // 防御：没有任何 worker 则任务无人消费，结果会静默变成 0 命中。
    // （main 已用 clamp_thread_count 夹过一次，此处保证直接调用者同样安全。）
    thread_count := o.thread_count
    if thread_count < 1 {
        thread_count = 1
    }

    // ---- 1) 切分任务：每个任务 TASK_CHUNK_SIZE 字节，最后一块可能不足 ----
    tp: Task_Pool
    task_pool_init(&tp)
    defer task_pool_destroy(&tp)
    for pos := uint(0); pos < file_size; {
        end := pos + TASK_CHUNK_SIZE
        if end > file_size {
            end = file_size
        }
        task_pool_push(&tp, Scan_Task{start = pos, end = end})
        pos = end
    }

    // ---- 2) 准备共享资源：arena 池 / 输出队列 / 命中汇总 ----
    ap: Arena_Pool
    arena_pool_init(&ap, ARENA_BLOCK_SIZE, thread_count)
    defer arena_pool_destroy(&ap)
    out_q: Output_Queue
    output_queue_init(&out_q)
    defer output_queue_destroy(&out_q)
    match_lists := make([dynamic][]Match_Result)
    defer delete(match_lists)
    list_mu: sync.Mutex
    hit_counter: uint = 0
    hit_mu: sync.Mutex

    // ---- 3) 进度条：--quiet 时关闭（此时 scanned 不累加）----
    prog: Progress
    progress_init(&prog, u64(file_size), true, !o.quiet)
    defer progress_destroy(&prog)

    // ---- 4) 先启动输出线程（消费者），再启动 worker（生产者）----
    out_args := output_data{
        q = &out_q,
        file_data = file_data,
        pat_len = uint(len(o.ctx.pattern)),
        ctx = o.context_bytes,
        use_color = true,
        only_count = o.only_count,
        offset_hex = o.offset_hex,
        out_hits = &hit_counter,
        hit_mu = &hit_mu,
        quiet = o.quiet,
    }
    out_th := thread.create_and_start_with_data(&out_args, output_thread)

    workers := make([dynamic]^thread.Thread, 0, thread_count)
    defer delete(workers)
    worker_args := make([]worker_data, thread_count)
    defer delete(worker_args)
    for i in 0..<int(thread_count) {
        worker_args[i] = worker_data{
            file_data = file_data,
            ctx = o.ctx,
            tp = &tp,
            ap = &ap,
            out_q = &out_q,
            out_list = &match_lists,
            list_mu = &list_mu,
            progress = &prog,
        }
        th := thread.create_and_start_with_data(&worker_args[i], worker_steal)
        append(&workers, th)
    }

    // ---- 5) 收敛：先等所有 worker，再通知输出线程结束并等它 ----
    for t in workers {
        thread.join(t)
        thread.destroy(t)
    }
    output_queue_set_done(&out_q)
    thread.join(out_th)
    thread.destroy(out_th)
    progress_finish(&prog)

    // ---- 6) 归并分片结果并做区间过滤 ----
    all_matches := merge_ordered_matches(match_lists[:])
    defer delete(all_matches)
    filtered := make([dynamic]Match_Result, 0, len(all_matches))
    for res in all_matches {
        if res.offset >= o.after && res.offset <= o.before {
            append(&filtered, res)
        }
    }
    return filtered[:]
}
