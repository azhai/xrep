package main

// ============================================================================
// io_utils.odin — 文件读取、上下文渲染、结果落盘、输出名清洗
//
// 职责：
//   * read_file_data    — 整文件读入内存（后续所有扫描都在内存切片上做）。
//   * file_size_of      — 只探测文件大小（供 --max-size 在读入前拦截超大文件）。
//   * context_range     — 纯函数：计算上下文窗口的字节区间（可单测的边界算术）。
//   * print_context     — 把窗口内的字节以 hex 打印，命中字节红色高亮。
//   * sanitize_dump_name— 纯函数：把路径分隔符等清洗为下划线（dump-prefix 用）。
//   * dump_matches      — 把命中偏移按指定进制写入文件（支持覆盖/追加）。
//   * build_line_index / line_of — 换行位置表与"偏移 → 行号"二分查找（-n / 行导向）。
//   * json_escape       — 把字符串转义为可嵌入 JSON 的形态（--json）。
//   * resolve_color     — 纯函数：把 --color=WHEN 解析为布尔值。
//
// 依赖：core:fmt、core:os、core:strings。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strings"

// 整文件读取。成功返回数据切片（调用方负责 delete），失败返回 os.Error。
read_file_data :: proc(path: string) -> (data: []byte, err: os.Error) {
    return os.read_entire_file(path, context.allocator)
}

// 只取文件字节数，不读内容。失败返回 (0, false)。
// 用途：--max-size 需要在把整个文件读进内存之前就知道它有多大，
//       否则"跳过超大文件"这个优化本身就会先 OOM。
file_size_of :: proc(path: string) -> (size: u64, ok: bool) {
    f, err := os.open(path)
    if err != nil {
        return 0, false
    }
    defer os.close(f)
    n, serr := os.file_size(f)
    if serr != nil || n < 0 {
        return 0, false
    }
    return u64(n), true
}

// 计算上下文窗口在文件中的字节区间 [start, end)。
// 边界规则（与原实现逐条对应，勿改）：
//   - 起点向前回退 ctx 字节；不足 ctx 时夹到 0（即文件头）；
//   - 终点为 offset + pat_len + ctx；超过文件长度时夹到文件长度。
// 返回半开区间，可直接用于 file_data[start:end] 切片。
context_range :: proc(file_len: uint, offset: u64, pat_len: uint, ctx: uint) -> (start: uint, end: uint) {
    start = uint(offset)
    if start > ctx {
        start -= ctx
    } else {
        start = 0
    }
    end = uint(offset) + pat_len + ctx
    if end > file_len {
        end = file_len
    }
    return
}

// 打印一个命中附近的上下文。
//   file_data — 已读入的整个文件
//   offset    — 命中在文件中的起始偏移
//   pat_len   — 模式长度，用于确定高亮区间 [offset, offset+pat_len)
//   ctx       — 命中前后各展示的字节数
// 输出形如：`  context hex: 61 62 <红色>74 65 73 74<重置> 63 64`
print_context :: proc(file_data: []u8, offset: u64, pat_len: uint, ctx: uint, use_color: bool) {
    start_ctx, end_ctx := context_range(uint(len(file_data)), offset, pat_len, ctx)
    ctx_slice := file_data[start_ctx:end_ctx]
    fmt.print("  context hex: ")
    pos := uint(offset) - start_ctx // 命中在窗口内的相对位置
    for idx in 0..<len(ctx_slice) {
        // 命中区间用红色包裹：先打印颜色码，再打印字节，最后重置。
        if use_color && idx >= int(pos) && idx < int(pos + pat_len) {
            fmt.print(COLOR_RED)
            fmt.printf("%02x ", ctx_slice[idx])
            fmt.print(COLOR_RESET)
        } else {
            fmt.printf("%02x ", ctx_slice[idx])
        }
    }
    fmt.println()
}

// ---------------------------------------------------------------------------
// dump 输出名清洗
// ---------------------------------------------------------------------------

// 判断字节是否为"不能直接进文件名"的字符：
//   / \ : 是路径分隔符与盘符分隔符（会把单层文件名变成子目录路径）；
//   * ? " < > | 是 Windows 保留字符。
// 只做单字节判断，不动 UTF-8 高字节，因此中文文件名原样保留。
dump_name_unsafe :: proc(c: u8) -> bool {
    switch c {
    case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
        return true
    }
    return false
}

// 把输入路径清洗成可安全拼接的文件名片段：不安全字节 → '_'。
// 长度与入参一致（逐字节替换，不删字符），因此同名输入恒定产生同名输出。
// 例："./data/file.bin" → "._data_file.bin"，最终 dump 名为 "<prefix>._data_file.bin.txt"。
// 返回由当前 allocator 分配的切片，调用方负责 delete。
sanitize_dump_name :: proc(path: string) -> []u8 {
    out := make([]u8, len(path))
    for i in 0..<len(path) {
        c := path[i]
        out[i] = dump_name_unsafe(c) ? '_' : c
    }
    return out
}

// ---------------------------------------------------------------------------
// 落盘
// ---------------------------------------------------------------------------

// 把命中偏移写入 dump 文件；offset_hex 为真时输出 0x 前缀的十六进制。
//   append_mode=false（默认）— 覆盖写（os.create 语义）
//   append_mode=true            — 追加写（--dump-append），文件不存在则创建
// 返回是否全部写入成功：打开失败或写入失败都返回 false（并已打印错误到 stderr）。
// 注意：空匹配列表也会创建一个空文件（保持既有行为，便于脚本判断"已执行过"）；
//       若需跳过空文件，由调用方（--skip-empty）决定不调用本函数。
dump_matches :: proc(path: string, matches: []Match_Result, offset_hex: bool, append_mode := false) -> bool {
    f: ^os.File
    err: os.Error
    if append_mode {
        // 追加写：文件存在则续写，不存在则创建；不使用 Trunc。
        f, err = os.open(path, {.Write, .Append, .Create}, os.Permissions_Default_File)
    } else {
        f, err = os.create(path)
    }
    if err != nil {
        fmt.fprintf(os.stderr, "Failed to open dump file %s: %v\n", path, err)
        return false
    }
    defer os.close(f)
    for m in matches {
        line: string
        if offset_hex {
            line = fmt.tprintf("0x%x\n", m.offset)
        } else {
            line = fmt.tprintf("%d\n", m.offset)
        }
        _, werr := os.write_string(f, line)
        if werr != nil {
            fmt.fprintf(os.stderr, "Write dump error: %v\n", werr)
            return false
        }
    }
    return true
}

// 把 data[offset, offset+pat_len) 打成连续的两位十六进制（无分隔符，形如 `74657374`）。
// 用途：`-o/--only-matching` 与 JSON 的 `match` 字段 —— 二进制安全且可直接嵌字符串。
// 越界自动夹取，调用方无需先做边界检查。
print_hex_bytes :: proc(data: []u8, offset: u64, pat_len: uint) {
    start := uint(offset)
    if start >= uint(len(data)) {
        return
    }
    end := start + pat_len
    if end > uint(len(data)) {
        end = uint(len(data))
    }
    for i in start..<end {
        fmt.printf("%02x", data[i])
    }
}

// ---------------------------------------------------------------------------
// 行号索引（-n / 行导向输出）
// ---------------------------------------------------------------------------

// 构建"换行位置表"：返回的 idx 中，idx[i] 是第 i 个 '\n' 的字节偏移（升序）。
// 偏移 o 所在行号 = "严格小于 o 的换行数" + 1（1-based）。
//
// 为什么先建表：流式输出线程可能按分片完成的乱序拿到命中，若每条命中都从头
// 数换行，单文件代价是 O(命中数 × 文件长度)。建表一次是 O(文件长度)，
// 之后每条命中 O(log 换行数)。
//
// 内存代价：换行数 × 8B（100MB 文本约 250 万行 → 20MB）。因此**只在真正需要
// 行号时才构建**（见 scan.odin 的 line_index_needed）。
// 返回切片由调用方 delete。
build_line_index :: proc(data: []u8) -> []u64 {
    count := 0
    for b in data {
        if b == '\n' {
            count += 1
        }
    }
    idx := make([]u64, count)
    k := 0
    for b, i in data {
        if b == '\n' {
            idx[k] = u64(i)
            k += 1
        }
    }
    return idx
}

// 行号（1-based）：二分查找第一个 >= offset 的换行位置，其下标即"前面的换行数"。
line_of :: proc(index: []u64, offset: u64) -> u64 {
    lo := 0
    hi := len(index)
    for lo < hi {
        mid := (lo + hi) / 2
        if index[mid] < offset {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return u64(lo) + 1
}

// ---------------------------------------------------------------------------
// JSON 输出（--json / --jsonl）
// ---------------------------------------------------------------------------

// 0..15 → 小写十六进制字符。
// 用算术而非查表字符串：Odin 不允许用一个变量下标去索引常量字符串。
hex_digit :: proc(v: u8) -> u8 {
    if v < 10 {
        return '0' + v
    }
    return 'a' + (v - 10)
}

// 把字符串转义为可安全嵌入 JSON 双引号之间的内容。
// 按**字节**遍历而非按 rune：路径可能含非 UTF-8 字节，原样透传才能保证
// 输出始终是可解析的 JSON（JSON 允许任意 UTF-8，非法字节按字节输出）。
// 返回新分配字符串，调用方负责 delete。
json_escape :: proc(s: string) -> string {
    b: strings.Builder
    strings.builder_init(&b)
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case '"':
            strings.write_string(&b, "\\\"")
        case '\\':
            strings.write_string(&b, "\\\\")
        case '\n':
            strings.write_string(&b, "\\n")
        case '\r':
            strings.write_string(&b, "\\r")
        case '\t':
            strings.write_string(&b, "\\t")
        case:
            if c < 0x20 {
                // 其余控制字符统一走 \u00XX。
                strings.write_string(&b, "\\u00")
                strings.write_byte(&b, hex_digit((c >> 4) & 0xF))
                strings.write_byte(&b, hex_digit(c & 0xF))
            } else {
                strings.write_byte(&b, c)
            }
        }
    }
    return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// 颜色
// ---------------------------------------------------------------------------

// 把 --color=WHEN 解析为布尔值：Auto 以 stdout 是否为终端为准。
// 纯函数（除 Auto 分支的一次 os.is_tty 查询），便于单测 Always/Never。
resolve_color :: proc(mode: Color_Mode) -> bool {
    switch mode {
    case .Always:
        return true
    case .Never:
        return false
    case .Auto:
        return os.is_tty(os.stdout)
    }
    return false
}
