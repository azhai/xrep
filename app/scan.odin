package app

// ============================================================================
// scan.odin — 单文件扫描编排
//
// 职责：把"一次完整扫描"的步骤串起来：
//   选路(--max-size 拦截) → 读文件 → [空文件快速跳过] →
//   切分成 [start,end) 任务入池 → 起 N 个 worker + 1 个输出线程 →
//   等待收敛 → 归并各分片命中 → 过滤(--after/--before) → 截断(--max-count) →
//   落盘(--dump / --dump-prefix / --skip-empty / --dump-append) →
//   按模式打印统计（-l / -L / --count / --json / 传统汇总）。
//
// 依赖：io_utils / worker / matcher / merge / 各并发基础设施模块。
// 线程生命周期：worker 先全部 join，再 set_done 唤醒并 join 输出线程，
//               否则输出线程可能在仍有生产者时提前退出丢结果。
//
// 选项以 Scan_Options 结构体传入：本函数参数已随功能增多接近两位数，
// 用结构体承载可避免调用点出现一长串同类型实参（易错且难读）。
//
// 输出兼容性（重要）：当 `show_path=false`、无 `-n/-o/-m/--json/-l/-L` 时，
// 走的是与加这些功能之前**完全一致**的路径（`match offset: N` + 可选 hex 上下文
// + `=== path: N results ===` 汇总），因此单文件默认调用的输出逐字节不变。
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "xrep:engine"
import "xrep:lib"
import "xrep:search"

// 是否处于"传统单文件输出"模式。
// 为真时：输出 `match offset: N` + 可选 hex 上下文 + `=== path: N results ===` 汇总，
// 进度条可见 —— 即加这些功能之前的完整行为（逐字节兼容）。
// 为假时：行导向 / JSON / -l / -L / -n / -o 等"结构化"输出，进度条与汇总都关闭，
// 以免 `\r` 进度条和汇总行混进可被管道消费的输出里。
legacy_output :: proc(o: lib.Scan_Options) -> bool {
    return !o.show_path && !o.line_numbers && !o.only_matching && !o.json && o.list_mode == .None
}

// 是否需要构建行号表。
// 明细不输出时（quiet / -l / -L / --count）用不到行号 —— 省掉一次 O(n) 扫描
// 与 O(换行数) 的内存。
line_index_needed :: proc(o: lib.Scan_Options) -> bool {
    if o.quiet || o.list_mode != .None || o.only_count {
        return false
    }
    return o.line_numbers || o.show_path || o.json
}

// 扫描单个文件。
// 返回值：
//   hits    — 区间过滤 + 上限截断后的命中数
//   dump_ok — 落盘是否成功（未落盘/被跳过视为成功）；false 时错误已写 stderr，
//             调用方据此把进程退出码置为非 0（见 README）。
scan_file :: proc(path: string, o: lib.Scan_Options) -> (hits: uint, dump_ok: bool) {
    dump_ok = true
    // 展示名：多文件 / 递归场景由调用方传入（可能是 walk 展开后的相对路径）。
    label := o.path_label
    if len(label) == 0 {
        label = path
    }

    // ---- 0) --max-size 预拦截：读入前先看大小，避免把超大文件整个读进内存 ----
    if o.max_size > 0 {
        if size, ok := engine.file_size_of(path); ok && size > o.max_size {
            // 被跳过的文件不输出任何 stdout 统计（它并非"0 命中"，而是"未扫描"，
            // 打印 0 hits 会误导）。原因固定写 stderr，且**不受 --quiet 抑制**：
            // --quiet 的语义是"不要闲聊"，而"请求的工作没做"必须仍然可见。
            fmt.fprintf(os.stderr, "skip %s: size %d exceeds --max-size %d\n", path, size, o.max_size)
            if o.stats != nil {
                o.stats.files_skipped += 1
            }
            return 0, true
        }
    }

    file_data, err := engine.read_file_data(path)
    if err != nil {
        fmt.fprintf(os.stderr, "open %s failed: %v\n", path, err)
        return 0, true
    }
    defer delete(file_data)
    file_size := uint(len(file_data))

    // ---- 命中结果：空文件直接为空，避免为一无所有的文件建池起线程 ----
    filtered: []lib.Match_Result
    if file_size > 0 {
        filtered = scan_region_parallel(file_data, o, label)
    }
    // 重要：Odin 的 defer 是**块作用域**——写在 if 体内会在该 if 结束时就执行。
    // 因此释放必须挂在函数作用域上，否则 filtered 会在落盘读取之前被释放，
    // dump 会写出已释放内存中的垃圾值。
    defer {
        if filtered != nil {
            delete(filtered)
        }
    }

    // ---- --max-count：归并结果同样截断到 N，与流式打印的条数保持一致 ----
    if o.max_count > 0 && uint(len(filtered)) > o.max_count {
        filtered = filtered[:o.max_count]
    }

    // ---- 落盘：--dump-prefix 优先；--skip-empty 时不产出空文件 ----
    if !(o.skip_empty && len(filtered) == 0) {
        final_dump_path := o.dump_path
        if len(o.dump_prefix) > 0 {
            // 清洗路径分隔符后再拼接：--dump-prefix 会把输入文件路径直接写进
            // 输出名，含 './' 或子目录的路径会因中间目录不存在而写入失败。
            safe := engine.sanitize_dump_name(path)
            final_dump_path = fmt.tprintf("%s%s.txt", o.dump_prefix, transmute(string)safe)
            delete(safe) // tprintf 已拷贝内容，立即释放（不依赖块作用域 defer）
        }
        if len(final_dump_path) > 0 {
            dump_ok = engine.dump_matches(final_dump_path, filtered, o.offset_hex, o.dump_append)
        }
    }

    // ---- 统计累加（--stats）----
    if o.stats != nil {
        o.stats.files_scanned += 1
        o.stats.bytes_scanned += u64(file_size)
        o.stats.total_hits += u64(len(filtered))
        if len(filtered) > 0 {
            o.stats.files_matched += 1
        }
    }

    // ---- -l / -L：只输出"有/无命中"的文件名，抑制其它一切 stdout ----
    switch o.list_mode {
    case .Files_With:
        if len(filtered) > 0 {
            print_file_verdict(label, o.json, true)
        }
        return len(filtered), dump_ok
    case .Files_Without:
        if len(filtered) == 0 {
            print_file_verdict(label, o.json, false)
        }
        return len(filtered), dump_ok
    case .None:
    // 继续走常规输出
    }

    // ---- 统计输出（quiet 完全静默，交给调用方聚合）----
    if o.quiet {
        return len(filtered), dump_ok
    }
    if o.only_count {
        if o.json {
            // Odin 的 fmt 把 `{` `}` 当格式语法：字面量大括号写成 `{{` `}}`。
            esc := engine.json_escape(label)
            fmt.printf("{{\"file\":\"%s\",\"count\":%d}}\n", esc, len(filtered))
            delete(esc)
        } else {
            fmt.printf("%s: %d hits\n", label, len(filtered))
        }
        return len(filtered), dump_ok
    }
    if legacy_output(o) {
        // 既有行为（契约，见 README 已知行为#3）：pretty 汇总会先丢弃前 2 条命中。
        // --count 与 --dump 使用完整 filtered；此处刻意不做修正。
        dropped := search.slice_drop(lib.Match_Result, filtered, 2)
        taken := dropped
        if o.limit > 0 {
            taken = search.slice_take(lib.Match_Result, dropped, o.limit)
        }
        fmt.printf("\n=== %s: %d results ===\n", label, len(taken))
    }
    return len(filtered), dump_ok
}

// -l / -L 的单文件输出；--json 时输出对象而非裸文件名。
print_file_verdict :: proc(label: string, json: bool, matched: bool) {
    if json {
        esc := engine.json_escape(label)
        fmt.printf("{{\"file\":\"%s\",\"matched\":%s}}\n", esc, matched ? "true" : "false")
        delete(esc)
        return
    }
    fmt.println(label)
}

// 对已读入的整块数据执行并行扫描，返回区间过滤后的命中（按偏移升序）。
// 调用方负责释放返回切片。
scan_region_parallel :: proc(file_data: []u8, o: lib.Scan_Options, label: string) -> []lib.Match_Result {
    file_size := uint(len(file_data))
    // 防御：没有任何 worker 则任务无人消费，结果会静默变成 0 命中。
    // （main 已用 clamp_thread_count 夹过一次，此处保证直接调用者同样安全。）
    thread_count := o.thread_count
    if thread_count < 1 {
        thread_count = 1
    }

    // ---- 0) 行号表（仅在需要时构建；见 line_index_needed）----
    line_index: []u64
    if line_index_needed(o) {
        line_index = engine.build_line_index(file_data)
    }
    defer if line_index != nil { delete(line_index) }

    // ---- 1) 切分任务：每个任务 TASK_CHUNK_SIZE 字节，最后一块可能不足 ----
    tp: lib.Task_Pool
    lib.task_pool_init(&tp)
    defer lib.task_pool_destroy(&tp)
    for pos := uint(0); pos < file_size; {
        end := pos + lib.TASK_CHUNK_SIZE
        if end > file_size {
            end = file_size
        }
        lib.task_pool_push(&tp, lib.Scan_Task{start = pos, end = end})
        pos = end
    }

    // ---- 2) 准备共享资源：输出队列 / 命中汇总 ----
    out_q: lib.Output_Queue
    lib.output_queue_init(&out_q)
    defer lib.output_queue_destroy(&out_q)
    match_lists := make([dynamic][]lib.Match_Result)
    defer delete(match_lists)
    list_mu: sync.Mutex
    hit_counter: uint = 0
    hit_mu: sync.Mutex

    // ---- 3) 进度条 ----
    // 只在传统输出模式下可见：进度条用 `\r` 原地刷新且写 stdout，
    // 混进 `path:line:offset` / JSON 会破坏管道消费。
    progress_on := !o.quiet && legacy_output(o)
    prog: lib.Progress
    // 实参顺序是 (use_color, enabled) —— 形参签名见 progress.odin:29。
    // 曾经在这里写过 `true, progress_on`，把 use_color 写死成"永远着色"，
    // 于是 `--color never` / `--no-color` 只管住了命中高亮，进度条那一行
    // 仍在往 stdout 吐 ANSI 转义（重定向到文件/管道时可见）。
    // 改这一行时注意别把两个 bool 再写反。
    lib.progress_init(&prog, u64(file_size), o.use_color, progress_on)
    defer lib.progress_destroy(&prog)

    // ---- 4) 先启动输出线程（消费者），再启动 worker（生产者）----
    silent := o.quiet || o.only_count || o.list_mode != .None
    out_args := engine.output_data{
        q = &out_q,
        file_data = file_data,
        path_label = label,
        pat_len = uint(len(o.ctx.pattern)),
        ctx = o.context_bytes,
        use_color = o.use_color,
        offset_hex = o.offset_hex,
        show_path = o.show_path,
        line_numbers = o.line_numbers,
        line_index = line_index,
        only_matching = o.only_matching,
        max_count = o.max_count,
        json = o.json,
        silent = silent,
        out_hits = &hit_counter,
        hit_mu = &hit_mu,
    }
    out_th := thread.create_and_start_with_data(&out_args, engine.output_thread)

    workers := make([dynamic]^thread.Thread, 0, thread_count)
    defer delete(workers)
    worker_args := make([]engine.worker_data, thread_count)
    defer delete(worker_args)
    for i in 0..<int(thread_count) {
        worker_args[i] = engine.worker_data{
            file_data = file_data,
            ctx = o.ctx,
            tp = &tp,
            out_q = &out_q,
            out_list = &match_lists,
            list_mu = &list_mu,
            progress = &prog,
        }
        th := thread.create_and_start_with_data(&worker_args[i], engine.worker_steal)
        append(&workers, th)
    }

    // ---- 5) 收敛：先等所有 worker，再通知输出线程结束并等它 ----
    for t in workers {
        thread.join(t)
        thread.destroy(t)
    }
    lib.output_queue_set_done(&out_q)
    thread.join(out_th)
    thread.destroy(out_th)
    lib.progress_finish(&prog)

    // ---- 6) 归并分片结果并做区间过滤 ----
    all_matches := search.merge_ordered_matches(match_lists[:])
    defer delete(all_matches)
    // 归并只读取内容，不接管所有权；各分片的命中数组必须在这里逐个释放。
    // （此前 worker 会把命中"深拷贝到堆"再挂进 match_lists，而只释放了外层
    //  dynamic 数组 —— 内层切片从未被释放，是一次每分片一次的隐蔽泄漏：
    //  它不可见于 `odin test` 的泄漏统计，因为 worker 用的是归一化后的默认
    //  分配器，而不是测试的追踪分配器。）
    //
    // 释放必须**显式指定与分配相同的分配器**：这些数组是 worker 线程用
    // `runtime.default_context().allocator`（进程默认堆）分配的，而本函数运行在
    // main 线程 —— 在 `odin test` 下 main 的 `context.allocator` 是
    // mem.Tracking_Allocator，用它去 free 堆指针会直接报 "bad free"。
    for lst in match_lists {
        if lst != nil {
            delete(lst, runtime.default_context().allocator)
        }
    }
    filtered := make([dynamic]lib.Match_Result, 0, len(all_matches))
    for res in all_matches {
        if res.offset >= o.after && res.offset <= o.before {
            append(&filtered, res)
        }
    }
    return filtered[:]
}
