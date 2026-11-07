#+dialect hela
package engine

// ============================================================================
// worker.odin — 扫描线程与输出线程
//
// 职责：
//   * worker_steal — 扫描工作线程：循环从 Task_Pool 抢任务 → 调用匹配算法 →
//     把命中分流给"输出队列"（实时打印）与"命中列表"（汇总给上层）。
//   * output_thread — 输出线程：唯一消费者，串行打印，保证终端输出不交错。
//
// 依赖：core:fmt、core:sync、base:runtime。
// 并发约定：
//   - 线程入口的第一步是 `context = runtime.default_context()`：Odin 创建线程时
//     会复制创建者的 context，因此 worker 默认继承调用方的分配器。生产环境下
//     main 的分配器就是堆分配器，继承与不继承等价；但在 `odin test` 下，
//     测试运行器会把分配器换成 mem.Tracking_Allocator —— 它内部是**无锁 map**，
//     被多个线程并发分配会写坏其数据结构，实测表现为偶发 SIGBUS（退出码 138）。
//     显式归一化后，线程行为与创建者无关，也让泄漏追踪只统计真正的泄漏。
//   - 分配器归一化后，worker 内所有 make/append 都走堆；命中数组同样由 matcher
//     在堆上分配（ADR 0004），不再是 arena —— 因此既没有容量上限，也不会因
//     arena 复用而读到脏数据。切片所有权交给 scan_region_parallel 统一释放。
//
// 输出格式（由 output_data 的开关决定，优先级从高到低）：
//   1. silent（--quiet / --count / -l / -L）→ 只计数，不打明细；
//   2. --json      → 每行一个 JSON 对象；
//   3. show_path   → `path[:line]:offset` 行导向（多文件 / -r 时启用）；
//   4. 默认        → 沿用历史输出 `match offset: N`（单文件路径，逐字节兼容）。
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "xrep:lib"
import "xrep:search"

// ADR 0010（Hela 方言）：本文件的跨线程结构全部改为显式契约——
//   * 命中汇总从「共享 dynamic 数组 + list_mu」改为**每 worker 一个固定槽**
//     （out_lists[idx]）：地址互不重叠，天然免锁，这是 shared-nothing 的直接结论；
//   * 命中计数 out_hits 只有输出线程一个写者，锁是历史冗余，已删除；
//   * 任务池 / 输出队列的锁已由 lib 层换成的无锁环吸收（见 task_pool.odin /
//     output_queue.odin）。

// 线程参数聚合体。用结构体打包而非多个全局变量，是为了让线程入口只依赖一个
// rawptr，也让"哪些数据被共享"一目了然（凡是指针字段均为跨线程共享）。
// ADR 0010：out_list 指向**本 worker 独占**的 dynamic 数组——一个 worker 可能
// 抢到多个任务，每任务的命中列表 append 进自己的数组；地址互不重叠，
// 所有权按 worker 划分，list_mu 不复存在。
worker_data :: struct {
    file_data: []u8,
    ctx:       lib.Match_Ctx,
    tp:        ^lib.Task_Pool, // 共享：任务来源（无锁 MPMC）
    out_q:     ^lib.Output_Queue, // 共享：实时输出队列（无锁 + 反压）
    out_list:  ^[dynamic][]lib.Match_Result, // 本 worker 独占：只有它 append
    progress:  ^lib.Progress,
    no_stream: bool, // 明细不会被打印时跳过输出队列（见下方说明）
}

// 扫描线程主体。
worker_steal :: proc(data: rawptr) {
    // 先归一化线程上下文（原因见文件头"并发约定"）：不继承创建者的分配器。
    context = runtime.default_context()
    w := cast(^worker_data)data
    // 算法在启动时按上下文选定一次（多模式 → multi_match；单模式 → 按长度分派），
    // 循环内复用。
    matcher := search.select_matcher_for(w.ctx)
    n := uint(len(w.file_data))
    for {
        ok, task := lib.task_pool_pop(w.tp)
        if !ok {
            break
        }
        // 分片边界可能切断一个匹配，因此向后多扫 CHUNK_OVERLAP 字节；
        // 代价是分片尾部会重复产出命中，由上层 offset 过滤（--after/--before）
        // 与 dump 语义消化，不影响"是否存在命中"的判定。
        overlap := uint(lib.CHUNK_OVERLAP)
        end_scan := task.end + overlap
        if end_scan > n {
            end_scan = n
        }
        scan_region := w.file_data[task.start:end_scan]
        // 命中数组由 matcher 在堆上分配（ADR 0004），其所有权自此处起转移给本
        // 函数：先原地改成文件内绝对偏移，再交给输出队列与汇总列表。
        // 释放由 scan_region_parallel 在归并之后统一进行，此处不要 delete。
        matches := matcher(scan_region, w.ctx, w.progress)
        for m in 0..<len(matches) {
            matches[m].offset += u64(task.start)
            // --quiet / --count / -l / -L 时明细根本不打印，入队只是白付一次
            // 加锁 + 唤醒；这些模式的命中数由上层归并结果得出（ADR 0008）。
            // 仅在 `-m` 未设置时跳过：`-m` 的契约是"流式到达顺序的前 N 条"，
            // 而流式顺序只有输出线程看得到。
            if !w.no_stream {
                lib.output_queue_push(w.out_q, lib.Output_Item{offset = matches[m].offset, pat_len = matches[m].pat_len})
            }
        }
        // append 进本 worker 独占的数组：与其它 worker 的地址互不重叠，无需任何锁。
        append(w.out_list, matches)
    }
}

// 输出线程参数。
// 注意 ctx 字段实际承载的是 --context 的**字节数**（沿用原命名），
// 与 worker_data.ctx（Match_Ctx）不同义。
output_data :: struct {
    q:             ^lib.Output_Queue,
    file_data:     []u8,
    path_label:    string, // 展示用文件名（--json / 行导向输出）
    pat_len:       uint, // 主模式长度：item.pat_len 为 0 时的回退值
    ctx:           uint, // --context N 的 N
    use_color:     bool,
    offset_hex:    bool,
    show_path:     bool, // 行导向：输出 `path:line:offset`
    line_numbers:  bool, // 输出行号
    line_index:    Line_Index, // 稀疏换行索引（仅在需要行号时构建；stride=1 即全量）
    line_hint:     Line_Hint, // 行号查询提示（只有本线程读写，无需同步）
    only_matching: bool, // -o：额外打印命中字节的 hex
    max_count:     uint, // -m：每文件最多报告多少条（0 = 不限）
    json:          bool, // --json
    silent:        bool, // --quiet / --count / -l / -L：不打明细（但仍计数）
    out_hits:      ^uint, // 计数出口：仅本线程在循环内累加，退出前写回；join 后主线程可读
}

// 输出线程主体：从队列取命中，按选定格式打印，并累加计数。
// --quiet / --count / -l / -L 仍然计数，只是不打印明细。
//
// --max-count 语义：**同时**约束计数与打印条数（第 N+1 条起既不计数也不打印）。
// 取的是"流式到达顺序"的前 N 条 —— 多分片时任务完成顺序可能与偏移顺序不同，
// 因此上限截取的是"最先算出来的 N 条"，而不是"偏移最小的 N 条"。
// 汇总/落盘路径（scan_file）另行把归并结果截断到 N，两条路径的条数一致。
// 打印阈值：攒到这么多字节才 write 一次 stdout。
// 每条命中一次 `fmt.printf` 就是一次 write 系统调用，稠密命中（百万条）下
// syscall 是主要成本；攒批后输出文本逐字节不变，只是 write 次数变少。
OUT_FLUSH_BYTES :: 64 * 1024

output_thread :: proc(data: rawptr) {
    // 同 worker_steal：线程入口先归一化上下文，避免继承测试运行器的追踪分配器。
    context = runtime.default_context()
    w := cast(^output_data)data

    hits: uint = 0 // 本地计数；循环结束后写回 out_hits

    sb: strings.Builder
    strings.builder_init(&sb)
    // 收敛路径只有一处（队列空且 done），但**提前 return / 崩溃**都会漏 flush。
    // 这里用 defer 兜底：先写出残留、再销毁 builder。
    // 注意 defer 必须写在函数体顶层 —— Odin 的 defer 是块作用域，
    // 写在循环或 if 里会在该块结束时就把缓冲刷出去。
    defer {
        // 计数写回：发生在 join 之前（本线程即将退出），主线程 join 后读取安全。
        if w.out_hits != nil {
            w.out_hits^ = hits
        }
        if len(sb.buf) > 0 {
            os.write(os.stdout, sb.buf[:])
        }
        strings.builder_destroy(&sb)
    }

    for {
        ok, item := lib.output_queue_pop(w.q)
        if !ok {
            break
        }
        // ---- 计数：--max-count 覆盖计数与打印 ----
        // ADR 0010：计数是输出线程的**本地**变量——这把锁从建立之初就只保护
        // 一个单线程读写的计数，属于纯冗余。
        reached := w.max_count > 0 && hits >= w.max_count
        if !reached {
            hits += 1
        }
        if reached || w.silent {
            continue
        }

        // item.pat_len 为 0 时回退到主模式长度（保持与历史行为一致）。
        plen := uint(item.pat_len)
        if plen == 0 {
            plen = w.pat_len
        }
        line := line_of(w.line_index, item.offset, &w.line_hint)

        // ---- 1) JSON Lines ----
        // 注意：Odin 的 fmt 把 `{` `}` 当作格式语法，字面量大括号必须写成 `{{` `}}`。
        if w.json {
            esc := json_escape(w.path_label)
            if w.only_matching {
                fmt.sbprintf(&sb, "{{\"file\":\"%s\",\"line\":%d,\"offset\":%d,\"len\":%d,\"match\":\"", esc, line, item.offset, plen)
                print_hex_bytes(w.file_data, item.offset, plen, &sb)
                // 字面量引号与换行：fmt 不解析 `{}`，但这里处在 printf 之外，
                // 直接写字符串即可（与旧代码 fmt.print 的语义一致）。
                strings.write_string(&sb, "\"}\n")
            } else {
                fmt.sbprintf(&sb, "{{\"file\":\"%s\",\"line\":%d,\"offset\":%d,\"len\":%d}}\n", esc, line, item.offset, plen)
            }
            delete(esc)
            maybe_flush(&sb)
            continue
        }

        // ---- 2) 行导向 / 3) 传统偏移输出 ----
        // 前缀规则：
        //   多文件 / -r（show_path）→ `path:line:offset`（行号总在）
        //   单文件 + -n            → `line:offset`
        //   其余                   → 沿用历史 `match offset: N`（逐字节兼容）
        if w.show_path || w.line_numbers {
            if w.show_path {
                fmt.sbprintf(&sb, "%s:", w.path_label)
            }
            fmt.sbprintf(&sb, "%d:", line)
            if w.offset_hex {
                fmt.sbprintf(&sb, "0x%x\n", item.offset)
            } else {
                fmt.sbprintf(&sb, "%d\n", item.offset)
            }
        } else {
            if w.offset_hex {
                fmt.sbprintf(&sb, "match offset: 0x%x\n", item.offset)
            } else {
                fmt.sbprintf(&sb, "match offset: %d\n", item.offset)
            }
        }
        if w.only_matching {
            strings.write_string(&sb, "  matched hex: ")
            print_hex_bytes(w.file_data, item.offset, plen, &sb)
            strings.write_string(&sb, "\n")
        }
        if w.ctx > 0 {
            print_context(w.file_data, item.offset, plen, w.ctx, w.use_color, &sb)
        }
        maybe_flush(&sb)
    }
}

// 攒批写出：达到阈值才真正写一次 stdout。
maybe_flush :: proc(sb: ^strings.Builder) {
    if len(sb.buf) < OUT_FLUSH_BYTES {
        return
    }
    os.write(os.stdout, sb.buf[:])
    strings.builder_reset(sb)
}
