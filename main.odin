package main

// ============================================================================
// main.odin — 程序入口（仅顶层编排）
//
// 职责：解析参数 → 夹取线程数 → 分派子命令（--test/--bench）→
//       展开输入项（目录 → 文件列表）→ 遍历文件执行扫描 → 汇总统计 → 退出。
// 具体实现按职责分散在：
//   cli.odin（参数） / walk.odin（目录遍历） / scan.odin（扫描）
//   selftest.odin（内建自测） / bench.odin（微基准） / matcher.odin（算法）
//   *_pool.odin（并发设施）
//
// 退出码约定：
//   0 — 正常完成（含"文件不存在""目录未加 -r"等已报告但不致命的错误）
//   1 — 参数错误，或任一 dump 落盘失败（--dump / --dump-prefix 写不进去）
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "xrep:app"
import "xrep:engine"
import "xrep:lib"

// 预读默认开启（多文件时）。环境变量只做"关"，因为"开"已经是默认值：
// 一个有副作用的环境开关比一个纯开关更难推理。
readahead_disabled :: proc() -> bool {
    v := os.get_env_alloc("XREP_NO_READAHEAD", context.allocator)
    defer delete(v)
    return v != ""
}

main :: proc() {
    // 全局表（lower_table / alg_table）**不在这里初始化**：
    //   * alg_table 是编译期常量，随二进制固化；
    //   * lower_table 由 lib/base.odin 里的 `@(init)` 过程在进程启动时自动填充。
    // 这样 main 与 `odin test` 的启动路径完全一致，不存在"测试忘了初始化全局表"
    // 的问题（详见 README「测试」章节）。

    // 参数解析只产出数据；错误/帮助/版本的退出策略在此处统一决定。
    opts, outcome, message := app.parse_args(os.args[1:])
    switch outcome {
    case .Help:
        app.print_help()
        os.exit(0)
    case .Version:
        app.print_version()
        os.exit(0)
    case .Error:
        fmt.fprintln(os.stderr, message)
        os.exit(1)
    case .Ok:
    // 继续主流程
    }

    // 子命令优先级：--test > --bench > 正常扫描。
    if opts.run_test {
        _ = app.run_tests()
        os.exit(0)
    }
    if opts.do_bench {
        app.run_bench()
        os.exit(0)
    }

    // 模式或文件缺失时打印用法并以 1 退出（注意：该判定在 --test/--bench 之后）。
    if len(opts.pattern) == 0 || len(opts.file_list) == 0 {
        app.print_help()
        os.exit(1)
    }

    // --threads 合法性：0 会让任务无人消费（静默 0 命中），超大值会拖垮进程。
    // 夹到 [1, 逻辑核心数 × 4]；探测不到核心数时用固定上界。
    opts.thread_count = lib.clamp_thread_count(opts.thread_count, app.max_threads_for_machine())

    // 颜色：默认 always（与加 --color 之前一致），--color=auto 才跟随终端。
    use_color := engine.resolve_color(opts.color_mode)

    // ---- 输入展开：目录 → 文件列表（-r / --glob / --exclude / --hidden）----
    files := app.walk_expand(opts.file_list[:], lib.Walk_Options{
        recursive = opts.recursive,
        hidden = opts.hidden,
        globs = opts.globs[:],
        excludes = opts.excludes[:],
    })
    // 不能写成 `defer walk_free(&files)`：main 以 os.exit 收尾，
    // 属于发散调用，Odin 会判定 defer 不可达。改在下方用完处显式释放。
    n_files := len(files)

    // 行导向输出（path[:line]:offset）在"多文件 / -r"时启用；单文件保持历史偏移输出。
    show_path := opts.recursive || len(files) > 1

    // cli.Options → scan.Scan_Options：一次映射，避免每个调用点重复十几二十个实参。
    stats: lib.Run_Stats
    scan_opts := lib.Scan_Options{
        ctx = app.match_ctx_from_options(&opts),
        after = opts.after,
        before = opts.before,
        limit = opts.limit,
        context_bytes = opts.context_bytes,
        only_count = opts.only_count,
        thread_count = opts.thread_count,
        offset_hex = opts.offset_hex,
        dump_path = opts.dump_path,
        dump_prefix = opts.dump_prefix,
        quiet = opts.quiet,
        skip_empty = opts.skip_empty,
        dump_append = opts.dump_append,
        max_size = opts.max_size,
        path_label = "",
        show_path = show_path,
        line_numbers = opts.line_numbers,
        only_matching = opts.only_matching,
        max_count = opts.max_count,
        json = opts.json,
        list_mode = opts.list_mode,
        use_color = use_color,
        stats = opts.stats ? &stats : nil,
    }

    started := time.now()

    // 多文件顺序处理（单文件内部并行）。
    //
    // 从 ADR 0013 起，"读下一个文件"与"扫当前文件"重叠：读者线程按同一顺序预读，
    // 主线程从队列取（见 engine/readahead.odin）。顺序不变，因此输出不变；
    // 单文件时没有"下一个"可重叠，预读是纯开销，所以不启用。
    // `XREP_NO_READAHEAD=1` 关掉它 —— A/B 测量与排障都需要一条回到串行读的路。
    total_hits: uint = 0
    io_failed := false
    reader: engine.Reader
    use_reader := !readahead_disabled() && n_files > 0
    if use_reader && n_files == 1 {
        // 单文件没有"下一个"可重叠，但**大文件仍值得并行读**：一个同步 read 是队列
        // 深度 1（1.81 GB/s），两个 pread 是 3.15 GB/s。小于阈值的单文件不为它起线程。
        size, size_ok := engine.file_size_of(files[0])
        use_reader = size_ok && size >= engine.PARALLEL_READ_MIN
    }
    if use_reader && engine.readahead_init(&reader, files[:], scan_opts.max_size) {
        for {
            item, ok := engine.readahead_next(&reader)
            if !ok {
                break
            }
            hits: uint
            dump_ok: bool
            if !item.skipped {
                hits, dump_ok = app.scan_file_preloaded(item.path, scan_opts, item.data)
                // 预读的缓冲由读者线程用进程默认堆分配：这里必须用同一个分配器还回去
                // （`odin test` 下主线程的 context.allocator 是追踪分配器）。
                delete(item.data, runtime.default_context().allocator)
            } else {
                // 太大、读失败、或会被 --max-size 跳过：走原路径，措辞与退出码不变。
                hits, dump_ok = app.scan_file(item.path, scan_opts)
            }
            total_hits += hits
            if !dump_ok {
                io_failed = true
            }
        }
        // 必须在 walk_free 之前停掉读者线程：它借用的是 `files` 里的字符串。
        engine.readahead_destroy(&reader)
    } else {
        for f in files {
            hits, dump_ok := app.scan_file(f, scan_opts)
            total_hits += hits
            if !dump_ok {
                io_failed = true
            }
        }
    }

    // 扫描期结束，文件路径字符串不再需要（只余计数）。
    app.walk_free(&files)

    // 多文件汇总统计：受 --quiet 控制。
    // 行：-l/-L/--json 的输出要能直接进管道（xargs / jq），故这些模式下不追加汇总。
    if !opts.quiet && n_files > 1 && opts.list_mode == .None && !opts.json {
        fmt.printf("\nScanned %d files, total hits: %d\n", n_files, total_hits)
    }

    // --stats：汇总写 stderr，与 --quiet 无关（"请求的工作做了多少"必须可见）。
    if opts.stats {
        print_stats(&stats, time.since(started))
    }

    // 以上资源由 parse_args / walk_expand 分配，均需显式归还：
    // 下方都是 os.exit（不会展开 defer），所以在此处手动释放。
    app.options_destroy(&opts)

    // 落盘失败必须反映到退出码，否则脚本会误判"扫描成功"。
    if io_failed {
        os.exit(1)
    }
    os.exit(0)
}

// --stats 的输出行（固定写 stderr）。
print_stats :: proc(st: ^lib.Run_Stats, elapsed: time.Duration) {
    fmt.fprintf(
        os.stderr,
        "stats: %d files scanned, %d with matches, %d skipped, %d bytes, %d hits, %.2f ms\n",
        st.files_scanned,
        st.files_matched,
        st.files_skipped,
        st.bytes_scanned,
        st.total_hits,
        f64(elapsed) / f64(time.Millisecond),
    )
}
