package main

// ============================================================================
// main.odin — 程序入口（仅顶层编排）
//
// 职责：初始化全局表 → 解析参数 → 夹取线程数 → 分派子命令（--test/--bench）→
//       遍历文件列表执行扫描 → 汇总统计 → 退出。
// 具体实现按职责分散在：
//   cli.odin（参数） / scan.odin（扫描） / selftest.odin（内建自测）
//   bench.odin（微基准） / matcher.odin（算法） / *_pool.odin（并发设施）
//
// 退出码约定：
//   0 — 正常完成（含"文件不存在"等已报告但不致命的错误）
//   1 — 参数错误，或任一 dump 落盘失败（--dump / --dump-prefix 写不进去）
// ============================================================================

import "core:fmt"
import "core:os"

main :: proc() {
    // 全局表（lower_table / alg_table）**不在这里初始化**：
    //   * alg_table 是编译期常量，随二进制固化；
    //   * lower_table 由 common.odin 里的 `@(init)` 过程在进程启动时自动填充。
    // 这样 main 与 `odin test` 的启动路径完全一致，不存在"测试忘了初始化全局表"
    // 的问题（详见 README「测试」章节）。

    // 参数解析只产出数据；错误/帮助/版本的退出策略在此处统一决定。
    opts, outcome, message := parse_args(os.args[1:])
    switch outcome {
    case .Help:
        print_help()
        os.exit(0)
    case .Version:
        print_version()
        os.exit(0)
    case .Error:
        fmt.fprintln(os.stderr, message)
        os.exit(1)
    case .Ok:
    // 继续主流程
    }

    // 子命令优先级：--test > --bench > 正常扫描。
    if opts.run_test {
        _ = run_tests()
        os.exit(0)
    }
    if opts.do_bench {
        run_bench()
        os.exit(0)
    }

    // 模式或文件缺失时打印用法并以 1 退出（注意：该判定在 --test/--bench 之后）。
    if len(opts.pattern) == 0 || len(opts.file_list) == 0 {
        print_help()
        os.exit(1)
    }

    // --threads 合法性：0 会让任务无人消费（静默 0 命中），超大值会拖垮进程。
    // 夹到 [1, 逻辑核心数 × 4]；探测不到核心数时用固定上界。
    opts.thread_count = clamp_thread_count(opts.thread_count, max_threads_for_machine())

    // cli.Options → scan.Scan_Options：一次映射，避免每个调用点重复 14 个实参。
    scan_opts := Scan_Options{
        ctx = Match_Ctx{pattern = opts.pattern, case_insensitive = opts.ignore_case},
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
    }

    // 多文件顺序处理（单文件内部并行）。
    total_hits: uint = 0
    io_failed := false
    for fpath in 0..<len(opts.file_list) {
        hits, dump_ok := scan_file(opts.file_list[fpath], scan_opts)
        total_hits += hits
        if !dump_ok {
            io_failed = true
        }
    }

    // 多文件汇总统计：受 --quiet 控制；单文件时跳过（避免噪音，单文件统计已在扫描行内）。
    if !opts.quiet && len(opts.file_list) > 1 {
        fmt.printf("\nScanned %d files, total hits: %d\n", len(opts.file_list), total_hits)
    }

    // file_list 是 parse_args 分配、由调用方拥有的动态数组（见 cli.odin 说明）。
    // 放在这里显式归还：下方都是 os.exit（不会展开 defer），而且此刻它已用完。
    delete(opts.file_list)

    // 落盘失败必须反映到退出码，否则脚本会误判"扫描成功"。
    if io_failed {
        os.exit(1)
    }
    os.exit(0)
}
