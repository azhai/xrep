package app

// ============================================================================
// cli.odin — 命令行解析与帮助
//
// 职责：把 `os.args` 翻译成纯数据的 Options 结构体；**不决定进程存活**。
//       退出策略交给调用方（main），于是参数解析可以被单元测试完整覆盖
//       （含所有错误分支），这是本模块拆分出的主要动机。
//
// 依赖：core:fmt、core:strconv、core:strings、core:os、core:sys/info。
//
// 结果 Parse_Outcome：
//   .Ok      → 解析成功，继续主流程
//   .Help    → 调用方打印帮助并退出 0
//   .Version → 调用方打印版本并退出 0
//   .Error   → 调用方把 message 写入 stderr 并退出 1
//
// 行为保持要点：
//   - `--help` / `--version` 在遍历中**即时生效**：出现在它之后的参数不会被解析，
//     因此 `--threads abc --help` 仍然以 1 退出（先撞上 --threads 的错误）。
//   - `--dump` 与 `--dump-prefix` 互斥，检查发生在遍历结束之后、
//     在 --test/--bench 判定之前。
//   - 没有 `-e` 时：第一个非 flag 参数是模式，其余非 flag 参数是文件列表。
//     有 `-e` 时：**所有**非 flag 参数都是文件列表（与 grep 一致）。
//
// 参数规范化（normalize_args，新增）：
//   为了同时支持 `--threads=N` 与短别名 `-t N` / `-tN` / 布尔捆绑 `-rn`，
//   解析前先把 argv 规范化为"长 flag + 独立值"的 token 序列，主循环只认长名。
//   规范化对**未知**短 flag 不做任何展开（原样保留），因此像 `-foo` 这样的
//   参数仍然落到位置参数分支，行为与加短别名之前一致。
//
// 注意：parse_args 保持"纯数据"——不探测硬件、不夹取线程数。
//       --threads 的合法性由 main 调用 clamp_thread_count 处理，这样解析结果
//       可被单元测试精确断言，不会随运行机器的核心数变化。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import info "core:sys/info"
import "xrep:lib"

// ---------------------------------------------------------------------------
// 短 flag 映射与参数规范化
// ---------------------------------------------------------------------------

// 该短 flag 是否需要一个值（形如 `-t 8` / `-t8`）。
short_takes_value :: proc(c: u8) -> bool {
    switch c {
    case 't', 'm', 'e', 'g', 'f':
        return true
    }
    return false
}

// 短 flag → 长 flag 名；返回空串表示"不是已知短 flag"。
short_to_long :: proc(c: u8) -> string {
    switch c {
    case 'i':
        return "--ignore-case"
    case 'c':
        return "--count"
    case 'q':
        return "--quiet"
    case 'v':
        return "--version"
    case 'h':
        return "--help"
    case 'n':
        return "--line-number"
    case 'o':
        return "--only-matching"
    case 'l':
        return "--files-with-matches"
    case 'L':
        return "--files-without-match"
    case 'r':
        return "--recursive"
    case 't':
        return "--threads"
    case 'm':
        return "--max-count"
    case 'e':
        return "--pattern"
    case 'g':
        return "--glob"
    case 'f':
        return "--file"
    }
    return ""
}

// 规范化为"长 flag + 独立值"token 序列。返回的动态数组归调用方所有。
//   `--threads=8`  → "--threads" "8"
//   `-rn`          → "-r" 分支展开为 "--recursive" "--line-number"
//   `-t8`          → "--threads" "8"
//   `-e` "pat"     → "--pattern" "pat"（值留在下一个 token，主循环照常取用）
//   `-foo`         → 原样（未知短 flag 不展开）
normalize_args :: proc(args: []string) -> [dynamic]string {
    out: [dynamic]string
    for a in args {
        // ---- 长 flag：`--name=value` ----
        if len(a) >= 3 && a[0] == '-' && a[1] == '-' {
            eq := -1
            for i in 2..<len(a) {
                if a[i] == '=' {
                    eq = i
                    break
                }
            }
            if eq > 2 {
                append(&out, a[:eq])
                append(&out, a[eq + 1:])
                continue
            }
            append(&out, a)
            continue
        }
        // ---- 短 flag 簇：`-abc` / `-t8` ----
        if len(a) >= 2 && a[0] == '-' && a[1] != '-' {
            valid := true
            for i in 1..<len(a) {
                if len(short_to_long(a[i])) == 0 {
                    valid = false
                    break
                }
                if short_takes_value(a[i]) {
                    break // 其后是值，不再当作 flag 校验
                }
            }
            if valid {
                i := 1
                for i < len(a) {
                    c := a[i]
                    append(&out, short_to_long(c))
                    i += 1
                    if short_takes_value(c) {
                        if i < len(a) {
                            append(&out, a[i:]) // `-t8` 的 8
                        }
                        break
                    }
                }
                continue
            }
        }
        append(&out, a)
    }
    return out
}

// 解析 --color=WHEN：always / never / auto。
parse_color_mode :: proc(v: string) -> (mode: lib.Color_Mode, ok: bool) {
    switch v {
    case "always", "yes", "force":
        return .Always, true
    case "never", "no", "none":
        return .Never, true
    case "auto", "tty":
        return .Auto, true
    }
    return .Auto, false
}

// 从 `-f FILE` 读入模式文件；每个非空行是一个模式（行尾 CRLF 的 \r 会被剥掉）。
// 内容缓冲挂到 opts.pattern_buffers 上统一释放，模式字符串是指向它的视图。
read_pattern_file :: proc(opts: ^lib.Options, path: string) -> (ok: bool, message: string) {
    buf, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        return false, fmt.tprintf("cannot read pattern file: %s", path)
    }
    append(&opts.pattern_buffers, buf)
    start := 0
    for i := 0; i <= len(buf); i += 1 {
        if i == len(buf) || buf[i] == '\n' {
            line := buf[start:i]
            if len(line) > 0 && line[len(line) - 1] == '\r' {
                line = line[:len(line) - 1]
            }
            if len(line) > 0 {
                append(&opts.patterns, transmute(string)line)
            }
            start = i + 1
        }
    }
    return true, ""
}

// 解析参数。args 通常为 os.args[1:]（不含程序名）。
// 返回的 message 不含换行，由调用方决定输出目标与格式。
parse_args :: proc(args: []string) -> (opts: lib.Options, outcome: lib.Parse_Outcome, message: string) {
    // 默认值：线程数 4；before 上界为 u64 最大值（等价"不设上界"）；
    // 颜色默认 always —— 与加 --color 之前的行为完全一致（原 use_color 恒为 true）。
    // 想跟随终端能力请显式 `--color=auto`。
    opts.thread_count = lib.DEFAULT_THREAD_COUNT
    opts.before = 0xFFFFFFFFFFFFFFFF
    opts.color_mode = .Always

    norm := normalize_args(args)
    defer delete(norm)

    // 位置参数先收集，解析结束后再决定"第一个是模式还是文件"：
    // 因为 `-e` 可能出现在文件参数之后，只有遍历完才知道有没有它。
    positional: [dynamic]string
    defer delete(positional)

    arg_idx := 0
    for arg_idx < len(norm) {
        arg := norm[arg_idx]
        arg_idx += 1
        switch arg {
        case "--threads", "-t":
            if arg_idx >= len(norm) {
                return opts, .Error, "--threads requires number"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid threads: %s", norm[arg_idx - 1])
            }
            opts.thread_count = uint(n)
        case "--ignore-case", "-i":
            opts.ignore_case = true
        case "--limit":
            if arg_idx >= len(norm) {
                return opts, .Error, "--limit requires number"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid limit: %s", norm[arg_idx - 1])
            }
            opts.limit = uint(n)
        case "--max-count", "-m":
            if arg_idx >= len(norm) {
                return opts, .Error, "--max-count requires number"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid max-count: %s", norm[arg_idx - 1])
            }
            opts.max_count = uint(n)
        case "--after":
            if arg_idx >= len(norm) {
                return opts, .Error, "--after requires offset"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 0) // base 0：同时接受 0x 前缀
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid after offset: %s", norm[arg_idx - 1])
            }
            opts.after = u64(n)
        case "--before":
            if arg_idx >= len(norm) {
                return opts, .Error, "--before requires offset"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 0)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid before offset: %s", norm[arg_idx - 1])
            }
            opts.before = u64(n)
        case "--context":
            if arg_idx >= len(norm) {
                return opts, .Error, "--context requires byte count"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid context: %s", norm[arg_idx - 1])
            }
            opts.context_bytes = uint(n)
        case "--count", "-c":
            opts.only_count = true
        case "--line-number", "-n":
            opts.line_numbers = true
        case "--only-matching", "-o":
            opts.only_matching = true
        case "--recursive", "-r":
            opts.recursive = true
        case "--hidden":
            opts.hidden = true
        case "--files-with-matches", "-l":
            opts.list_mode = .Files_With
        case "--files-without-match", "-L":
            opts.list_mode = .Files_Without
        case "--json", "--jsonl":
            opts.json = true
        case "--stats":
            opts.stats = true
        case "--no-color":
            // 语义已生效：等价 `--color=never`（历史上是 no-op，见 README 契约#4）。
            opts.color_mode = .Never
        case "--color":
            if arg_idx >= len(norm) {
                return opts, .Error, "--color requires WHEN (always|never|auto)"
            }
            mode, ok := parse_color_mode(norm[arg_idx])
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid color mode: %s", norm[arg_idx - 1])
            }
            opts.color_mode = mode
        case "--glob", "-g":
            if arg_idx >= len(norm) {
                return opts, .Error, "--glob requires a pattern"
            }
            append(&opts.globs, norm[arg_idx])
            arg_idx += 1
        case "--exclude":
            if arg_idx >= len(norm) {
                return opts, .Error, "--exclude requires a pattern"
            }
            append(&opts.excludes, norm[arg_idx])
            arg_idx += 1
        case "--pattern", "-e":
            if arg_idx >= len(norm) {
                return opts, .Error, "--pattern requires a value"
            }
            append(&opts.patterns, norm[arg_idx])
            arg_idx += 1
        case "--file", "-f":
            if arg_idx >= len(norm) {
                return opts, .Error, "--file requires a path"
            }
            fpath := norm[arg_idx]
            arg_idx += 1
            ok, msg := read_pattern_file(&opts, fpath)
            if !ok {
                return opts, .Error, msg
            }
        case "--offset-hex":
            opts.offset_hex = true
        case "--dump":
            if arg_idx >= len(norm) {
                return opts, .Error, "--dump requires output file"
            }
            opts.dump_path = norm[arg_idx]
            arg_idx += 1
        case "--dump-prefix":
            if arg_idx >= len(norm) {
                return opts, .Error, "--dump-prefix requires prefix string"
            }
            opts.dump_prefix = norm[arg_idx]
            arg_idx += 1
        case "--quiet", "-q":
            opts.quiet = true
        case "--skip-empty":
            opts.skip_empty = true
        case "--dump-append":
            opts.dump_append = true
        case "--max-size":
            if arg_idx >= len(norm) {
                return opts, .Error, "--max-size requires byte count"
            }
            n, ok := strconv.parse_uint(norm[arg_idx], 10)
            arg_idx += 1
            if !ok {
                return opts, .Error, fmt.tprintf("invalid max-size: %s", norm[arg_idx - 1])
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
            append(&positional, arg)
        }
    }

    // ---- 位置参数的归属：有 -e/-f 时全部是文件，否则第一个非空者才是模式 ----
    // 注意"非空"这个判据：既有语义用 `len(opts.pattern) == 0` 判断模式位是否已占用，
    // 因此空字符串参数**不占位**（`xrep "" file.bin` 里 file.bin 才是模式）。
    // 这是被单元测试钉住的兼容行为，不能用"位置下标 == 0"来替代。
    if len(opts.patterns) > 0 {
        for p in positional {
            append(&opts.file_list, p)
        }
    } else {
        for p in positional {
            if len(opts.pattern) == 0 {
                opts.pattern = lib.s2b(p)
            } else {
                append(&opts.file_list, p)
            }
        }
    }
    if len(opts.patterns) > 0 {
        opts.pattern = lib.s2b(opts.patterns[0])
    }

    // 互斥检查：--dump 和 --dump-prefix 不能同时使用
    if len(opts.dump_path) > 0 && len(opts.dump_prefix) > 0 {
        return opts, .Error, "Error: --dump and --dump-prefix are mutually exclusive"
    }

    return opts, .Ok, ""
}

// 由选项构造匹配上下文。pattern_extra 在此一次性分配（patterns[1:] 的字节视图），
// 由调用方通过 options_destroy 释放。
match_ctx_from_options :: proc(opts: ^lib.Options) -> lib.Match_Ctx {
    if opts.pattern_extra == nil && len(opts.patterns) > 1 {
        extra := make([][]u8, len(opts.patterns) - 1)
        for i in 1..<len(opts.patterns) {
            extra[i - 1] = lib.s2b(opts.patterns[i])
        }
        opts.pattern_extra = extra
    }
    return lib.Match_Ctx{
        pattern = opts.pattern,
        case_insensitive = opts.ignore_case,
        extra = opts.pattern_extra,
    }
}

// 释放 parse_args 拥有的全部资源（见 Options 的"内存所有权"说明）。
options_destroy :: proc(opts: ^lib.Options) {
    delete(opts.file_list)
    delete(opts.patterns)
    delete(opts.globs)
    delete(opts.excludes)
    if opts.pattern_extra != nil {
        delete(opts.pattern_extra)
    }
    for buf in opts.pattern_buffers {
        delete(buf)
    }
    delete(opts.pattern_buffers)
}

// 本机允许的最大 worker 线程数 = 逻辑核心数 × MAX_THREADS_FACTOR。
// 探测失败（容器/异常平台）时退回 FALLBACK_MAX_THREADS，保证上界总是有限。
max_threads_for_machine :: proc() -> uint {
    _, logical, ok := info.cpu_core_count()
    if !ok || logical <= 0 {
        return lib.FALLBACK_MAX_THREADS
    }
    return uint(logical) * lib.MAX_THREADS_FACTOR
}

print_help :: proc() {
    fmt.println("xrep - fast binary pattern search tool")
    fmt.println("Usage: xrep <pattern> [files/dirs...] [flags]")
    fmt.println()
    fmt.println("Matching:")
    fmt.println("  -i,--ignore-case     case insensitive match")
    fmt.println("  -e,--pattern PATTERN add pattern (repeatable, multiple patterns)")
    fmt.println("  -f,--file FILE       read patterns line by line from FILE")
    fmt.println("  --after N            offset >= N")
    fmt.println("  --before N           offset <= N")
    fmt.println("  -m,--max-count N     report at most N matches per file (0 = unlimited)")
    fmt.println("  --limit N            limit pretty summary items (0 = unlimited)")
    fmt.println()
    fmt.println("Searching:")
    fmt.println("  -r,--recursive       search directories recursively")
    fmt.println("  -g,--glob GLOB       only files matching GLOB (repeatable)")
    fmt.println("  --exclude GLOB       skip files/dirs matching GLOB (repeatable)")
    fmt.println("  --hidden             include dotfiles (default: skipped)")
    fmt.println("  --max-size N         skip files larger than N bytes")
    fmt.println("  -t,--threads N       worker thread count (clamped to 1..cpu*4)")
    fmt.println()
    fmt.println("Output:")
    fmt.println("  -c,--count           only print hit count per file")
    fmt.println("  -n,--line-number     include 1-based line number")
    fmt.println("  -o,--only-matching   also print the matched bytes in hex")
    fmt.println("  -l,--files-with-matches    print only names of files with matches")
    fmt.println("  -L,--files-without-match   print only names of files without matches")
    fmt.println("  --context N          show N bytes context in hex")
    fmt.println("  --offset-hex         print offsets in hexadecimal")
    fmt.println("  --json,--jsonl       JSON Lines output")
    fmt.println("  --color WHEN         always|never|auto (default: always)")
    fmt.println("  --stats              print run summary to stderr")
    fmt.println("  --quiet,-q           no stdout (dump + stderr errors only)")
    fmt.println()
    fmt.println("Dump:")
    fmt.println("  --dump FILE          write all matched offsets to single file")
    fmt.println("  --dump-prefix P      write per-file dump: P{sanitized filename}.txt")
    fmt.println("  --dump-append        append to dump file instead of overwriting")
    fmt.println("  --skip-empty         do not create dump files for files with 0 hits")
    fmt.println()
    fmt.println("Misc:")
    fmt.println("  --test               run built-in self test")
    fmt.println("  --bench              run benchmark")
    fmt.println("  -v,--version         show version")
    fmt.println("  -h,--help            show this help")
    fmt.println()
    fmt.println("Examples:")
    fmt.println("  xrep ABC data.bin                       # match ABC in one file")
    fmt.println("  xrep abc f.bin -i -c                    # case-insensitive count")
    fmt.println("  xrep GET -r ./logs --glob '*.log'       # recursive over *.log")
    fmt.println("  xrep TODO -r src --exclude '*.min.js'   # add exclusions")
    fmt.println("  xrep -e foo -e bar -r . -n              # multi-pattern with line numbers")
    fmt.println("  xrep GET app.log --json --stats         # JSON Lines + summary")
    fmt.println("  xrep GET big.bin --max-size 104857600   # skip files over 100 MiB")
    fmt.println("  xrep GET *.log --dump-prefix out_       # per-file dumps out_*.txt")
}

print_version :: proc() {
    fmt.printf("xrep %s\n", lib.XREP_VERSION)
}
