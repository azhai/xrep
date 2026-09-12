package main

// ============================================================================
// cli.odin — 命令行解析与帮助
//
// 职责：把 `os.args` 翻译成纯数据的 Options 结构体；**不决定进程存活**。
//       退出策略交给调用方（main），于是参数解析可以被单元测试完整覆盖
//       （含所有错误分支），这是本模块拆分出的主要动机。
//
// 依赖：core:fmt、core:strconv、core:sys/info。
//
// 结果 Parse_Outcome：
//   .Ok      → 解析成功，继续主流程
//   .Help    → 调用方打印帮助并退出 0
//   .Version → 调用方打印版本并退出 0
//   .Error   → 调用方把 message 写入 stderr 并退出 1
//
// 行为保持要点（与拆分前逐条一致）：
//   - `--help` 在遍历中**即时生效**：出现在它之后的参数不会被解析，
//     因此 `--threads abc --help` 仍然以 1 退出（先撞上 --threads 的错误）。
//     `--version` 同样即时生效。
//   - `--dump` 与 `--dump-prefix` 互斥，检查发生在遍历结束之后、
//     在 --test/--bench 判定之前。
//   - 第一个非 flag 参数是模式，其余非 flag 参数是文件列表。
//
// 注意：parse_args 保持"纯数据"——不探测硬件、不夹取线程数。
//       --threads 的合法性由 main 调用 clamp_thread_count 处理，这样解析结果
//       可被单元测试精确断言，不会随运行机器的核心数变化。
// ============================================================================

import "core:fmt"
import "core:strconv"
import info "core:sys/info"

// 解析后的全部运行选项。字段默认值与拆分前的局部变量初始化一一对应。
Options :: struct {
    pattern:       []u8, // 第一个非 flag 参数；空表示未提供
    file_list:     [dynamic]string, // 其余非 flag 参数（**调用方负责 delete**，见 parse_args）
    ignore_case:   bool, // --ignore-case
    limit:         uint, // --limit N（0 = 不截断 pretty 输出）
    after:         u64, // --after N，命中偏移下界
    before:        u64, // --before N，命中偏移上界
    context_bytes: uint, // --context N
    run_test:      bool, // --test
    do_bench:      bool, // --bench
    only_count:    bool, // --count
    thread_count:  uint, // --threads N
    offset_hex:    bool, // --offset-hex
    dump_path:     string, // --dump FILE
    dump_prefix:   string, // --dump-prefix P
    quiet:         bool, // --quiet
    skip_empty:    bool, // --skip-empty：命中 0 条时不产出 dump 文件
    dump_append:   bool, // --dump-append：dump 改为追加写
    max_size:      u64, // --max-size N：跳过大于 N 字节的文件（0 = 不限制）
}

Parse_Outcome :: enum {
    Ok,
    Help,
    Version,
    Error,
}

// 解析参数。args 通常为 os.args[1:]（不含程序名）。
// 返回的 message 不含换行，由调用方决定输出目标与格式。
//
// 内存所有权：返回的 Options.file_list 是动态数组，**由调用方负责 delete**
// （main 会释放；单元测试也必须释放，否则内存追踪器会报 leak）。
// 该数组按需分配：没有文件参数时保持为 nil，`len()` 语义不变。
parse_args :: proc(args: []string) -> (opts: Options, outcome: Parse_Outcome, message: string) {
    // 默认值：线程数 4；before 上界为 u64 最大值（等价"不设上界"）。
    opts.thread_count = DEFAULT_THREAD_COUNT
    opts.before = 0xFFFFFFFFFFFFFFFF
    // 注意：file_list 刻意不在这里 make —— 走 --help/--version/--test/--bench
    // 或参数报错路径时不需要它；首次 append 时 Odin 会自动分配（nil 动态数组可 append）。

    arg_idx := 0
    for arg_idx < len(args) {
        arg := args[arg_idx]
        arg_idx += 1
        switch arg {
        case "--threads":
            if arg_idx >= len(args) {
                return opts, .Error, "--threads requires number"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid threads: %s", args[arg_idx - 1])
            }
            opts.thread_count = uint(n)
        case "--ignore-case":
            opts.ignore_case = true
        case "--limit":
            if arg_idx >= len(args) {
                return opts, .Error, "--limit requires number"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid limit: %s", args[arg_idx - 1])
            }
            opts.limit = uint(n)
        case "--after":
            if arg_idx >= len(args) {
                return opts, .Error, "--after requires offset"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 0) // base 0：同时接受 0x 前缀
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid after offset: %s", args[arg_idx - 1])
            }
            opts.after = u64(n)
        case "--before":
            if arg_idx >= len(args) {
                return opts, .Error, "--before requires offset"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 0)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid before offset: %s", args[arg_idx - 1])
            }
            opts.before = u64(n)
        case "--context":
            if arg_idx >= len(args) {
                return opts, .Error, "--context requires byte count"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid context: %s", args[arg_idx - 1])
            }
            opts.context_bytes = uint(n)
        case "--count":
            opts.only_count = true
        case "--no-color":
            // 颜色由 use_color 固定为 true，此标志接受但不改行为（防止终端转义混淆）。
            // 保留解析分支以免既有脚本误报 "unknown flag"。
        case "--offset-hex":
            opts.offset_hex = true
        case "--dump":
            if arg_idx >= len(args) {
                return opts, .Error, "--dump requires output file"
            }
            opts.dump_path = args[arg_idx]
            arg_idx += 1
        case "--dump-prefix":
            if arg_idx >= len(args) {
                return opts, .Error, "--dump-prefix requires prefix string"
            }
            opts.dump_prefix = args[arg_idx]
            arg_idx += 1
        case "--quiet":
            opts.quiet = true
        case "--skip-empty":
            opts.skip_empty = true
        case "--dump-append":
            opts.dump_append = true
        case "--max-size":
            if arg_idx >= len(args) {
                return opts, .Error, "--max-size requires byte count"
            }
            n, ok := strconv.parse_uint(args[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid max-size: %s", args[arg_idx - 1])
            }
            opts.max_size = u64(n)
        case "--test":
            opts.run_test = true
        case "--bench":
            opts.do_bench = true
        case "--version", "-v":
            // 即时退出：后续参数不再解析。
            return opts, .Version, ""
        case "--help", "-h":
            // 即时退出：后续参数不再解析（与拆分前行为一致）。
            return opts, .Help, ""
        case:
            // 第一个非flag作为pattern，其余作为文件列表
            if len(opts.pattern) == 0 {
                opts.pattern = s2b(arg)
            } else {
                append(&opts.file_list, arg)
            }
        }
    }

    // 互斥检查：--dump 和 --dump-prefix 不能同时使用
    if len(opts.dump_path) > 0 && len(opts.dump_prefix) > 0 {
        return opts, .Error, "Error: --dump and --dump-prefix are mutually exclusive"
    }

    return opts, .Ok, ""
}

// 本机允许的最大 worker 线程数 = 逻辑核心数 × MAX_THREADS_FACTOR。
// 探测失败（容器/异常平台）时退回 FALLBACK_MAX_THREADS，保证上界总是有限。
max_threads_for_machine :: proc() -> uint {
    _, logical, ok := info.cpu_core_count()
    if !ok || logical <= 0 {
        return FALLBACK_MAX_THREADS
    }
    return uint(logical) * MAX_THREADS_FACTOR
}

print_help :: proc() {
    fmt.println("xrep - fast binary pattern search tool")
    fmt.println("Usage: xrep <pattern> [files...] [flags]")
    fmt.println("Flags:")
    fmt.println("  --threads N     set worker thread count (clamped to 1..cpu*4)")
    fmt.println("  --ignore-case   case insensitive match")
    fmt.println("  --limit N       limit pretty summary items (0 = unlimited)")
    fmt.println("  --after N       offset >= N")
    fmt.println("  --before N      offset <= N")
    fmt.println("  --context N     show N bytes context hex")
    fmt.println("  --count         only output hit count")
    fmt.println("  --offset-hex    print offset in hexadecimal")
    fmt.println("  --dump FILE     write all matched offsets to single file")
    fmt.println("  --dump-prefix P write per-file dump: P{sanitized filename}.txt")
    fmt.println("  --dump-append   append to dump file instead of overwriting")
    fmt.println("  --skip-empty    do not create dump files for files with 0 hits")
    fmt.println("  --max-size N    skip files larger than N bytes")
    fmt.println("  --quiet         quiet mode: no stdout, only dump + stderr errors")
    fmt.println("  --test          run unit tests")
    fmt.println("  --bench         run benchmark")
    fmt.println("  -v,--version    show version")
    fmt.println("  -h,--help       show this help")
    fmt.println()
    fmt.println("Examples:")
    fmt.println("  xrep ABC data.bin                      # match ABC in one file")
    fmt.println("  xrep abc f.bin --ignore-case --count   # case-insensitive count")
    fmt.println("  xrep GET app.log --dump hits.txt       # dump offsets to hits.txt")
    fmt.println("  xrep GET *.log --dump-prefix out_      # per-file dumps out_*.txt")
    fmt.println("  xrep GET big.bin --max-size 104857600  # skip files over 100 MiB")
}

print_version :: proc() {
    fmt.printf("xrep %s\n", XREP_VERSION)
}
