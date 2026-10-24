package engine

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

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "xrep:lib"

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
//   sb        — 非 nil 时写入该缓冲（输出线程的攒批路径），否则直接写 stdout
// 输出形如：`  context hex: 61 62 <红色>74 65 73 74<重置> 63 64`
print_context :: proc(file_data: []u8, offset: u64, pat_len: uint, ctx: uint, use_color: bool, sb: ^strings.Builder = nil) {
    start_ctx, end_ctx := context_range(uint(len(file_data)), offset, pat_len, ctx)
    ctx_slice := file_data[start_ctx:end_ctx]
    out :: proc(sb: ^strings.Builder, s: string) {
        if sb != nil {
            strings.write_string(sb, s)
        } else {
            fmt.print(s)
        }
    }
    outf :: proc(sb: ^strings.Builder, format: string, args: ..any) {
        if sb != nil {
            fmt.sbprintf(sb, format, ..args)
        } else {
            fmt.printf(format, ..args)
        }
    }
    out(sb, "  context hex: ")
    pos := uint(offset) - start_ctx // 命中在窗口内的相对位置
    for idx in 0..<len(ctx_slice) {
        // 命中区间用红色包裹：先打印颜色码，再打印字节，最后重置。
        if use_color && idx >= int(pos) && idx < int(pos + pat_len) {
            out(sb, lib.COLOR_RED)
            outf(sb, "%02x ", ctx_slice[idx])
            out(sb, lib.COLOR_RESET)
        } else {
            outf(sb, "%02x ", ctx_slice[idx])
        }
    }
    out(sb, "\n")
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
// 落盘缓冲的阈值：攒到这么多字节才真正 write 一次。
// 逐条 `os.write_string` 意味着"每条命中一次系统调用" —— 稠密命中（百万条）
// 下 syscall 开销远超格式化本身（实测 1M 条从 1.17s 降到 ~0.2s）。
DUMP_FLUSH_BYTES :: 64 * 1024

dump_matches :: proc(path: string, matches: []lib.Match_Result, offset_hex: bool, append_mode := false) -> bool {
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

    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    // 攒批写出：内容逐字节不变（同一条记录同一行），只是 write 次数少了。
    flush_buf :: proc(f: ^os.File, sb: ^strings.Builder) -> bool {
        if len(sb.buf) == 0 {
            return true
        }
        if _, werr := os.write(f, sb.buf[:]); werr != nil {
            fmt.fprintf(os.stderr, "Write dump error: %v\n", werr)
            return false
        }
        strings.builder_reset(sb)
        return true
    }

    for m in matches {
        if offset_hex {
            fmt.sbprintf(&sb, "0x%x\n", m.offset)
        } else {
            fmt.sbprintf(&sb, "%d\n", m.offset)
        }
        if len(sb.buf) >= DUMP_FLUSH_BYTES {
            if !flush_buf(f, &sb) {
                return false
            }
        }
    }
    return flush_buf(f, &sb)
}

// 把 data[offset, offset+pat_len) 打成连续的两位十六进制（无分隔符，形如 `74657374`）。
// 用途：`-o/--only-matching` 与 JSON 的 `match` 字段 —— 二进制安全且可直接嵌字符串。
// 越界自动夹取，调用方无需先做边界检查。
// sb 非 nil 时写入该缓冲（输出线程的攒批路径），否则直接写 stdout。
print_hex_bytes :: proc(data: []u8, offset: u64, pat_len: uint, sb: ^strings.Builder = nil) {
    start := uint(offset)
    if start >= uint(len(data)) {
        return
    }
    end := start + pat_len
    if end > uint(len(data)) {
        end = uint(len(data))
    }
    for i in start..<end {
        if sb != nil {
            fmt.sbprintf(sb, "%02x", data[i])
        } else {
            fmt.printf("%02x", data[i])
        }
    }
}

// ---------------------------------------------------------------------------
// 行号索引（-n / 行导向输出）
// ---------------------------------------------------------------------------

// 稀疏换行索引的标记上限。每标记 8 B，上限 256K 标记 → 最多约 2 MB。
// 定这条线的理由：索引是为"命中多、文件大"的场景准备的（-n 打在 100 MB 文本上），
// 稠密表是 换行数 × 8 B（300 万行 → 24 MB）。抽稀后每块要回扫"相邻两标记之间"
// 的那段字节，块越小回扫越省 —— 但标记越多内存越大，2 MB 是实测下来的折中
// （300 万行 → stride 12 → 每块约 500 B）。
LINE_INDEX_MAX_MARKS :: 1 << 18

// 稀疏换行索引。
//   marks[j] — 第 `j*stride` 个 '\n'（0-based）的字节偏移
//   stride   — 抽样步长；1 表示全量（换行数 ≤ 上限时就是全量）
//   data     — 原数据视图（**不拥有**，用于块内回扫）
Line_Index :: struct {
    marks:  []u64,
    stride: u64,
    data:   []u8,
}

// 行号查询的定位提示：上次查到哪儿、那个位置之前有几个换行。
//
// 为什么需要它：只做"二分 + 块内回扫"时，稠密命中（-n 打印几百万行）每条命中
// 都要重扫一整块 —— 300 万行文本上实测让 `-n` 从 1.0 s 掉到 2.2 s，比全量表
// 还慢。而输出线程拿到的命中基本是**按偏移递增**的，所以沿上次位置往前数
// 就是 O(增量)。提示失效（命中乱序、跨块）时才回到二分。
//
// 归属：调用方持有（见 output_data.line_hint），因此 Line_Index 本身保持只读。
Line_Hint :: struct {
    valid: bool,
    mark:  int, // marks 下标；-1 = 位于第一个标记之前
    pos:   u64, // 上次查询的位置（扫描从这里继续）
    count: u64, // 严格小于 pos 的换行数
}

// 构建稀疏"换行位置表"。
//
// 语义：偏移 o 所在行号 = "严格小于 o 的换行数" + 1（1-based）。
//
// 一次遍历完成（`bytes.index_byte` 是 core 的 SIMD 实现）：边扫边按 stride 抽样，
// 一旦标记数超过 LINE_INDEX_MAX_MARKS 就把**偶数下标留下**、stride 翻倍 ——
// 于是 marks[j] 始终等于"第 j*stride 个换行"，内存有界而精度自动退化到
// 每 stride 行一个标记。稠密表（stride=1）与稀疏表的 line_of 是同一条代码路径。
//
// 内存：换行数 × 8B 降到 min(换行数, 2×上限) × 8B。
// 返回的 Line_Index 用 line_index_destroy 释放（data 是视图，不释放）。
build_line_index :: proc(data: []u8) -> Line_Index {
    li := Line_Index {
        data   = data,
        stride = 1,
    }
    marks := make([dynamic]u64, 0, 1024)
    i := 0
    ordinal := u64(0) // 这是第几个换行（0-based）
    for i < len(data) {
        rel := bytes.index_byte(data[i:], '\n')
        if rel < 0 {
            break
        }
        p := i + rel
        if ordinal % li.stride == 0 {
            append(&marks, u64(p))
            if len(marks) > LINE_INDEX_MAX_MARKS {
                // 抽稀：marks[j] = 旧 marks[2j] = 第 2j*stride 个换行
                k := 0
                for j := 0; j < len(marks); j += 2 {
                    marks[k] = marks[j]
                    k += 1
                }
                resize(&marks, k)
                li.stride *= 2
            }
        }
        ordinal += 1
        i = p + 1
    }
    li.marks = marks[:]
    return li
}

line_index_destroy :: proc(li: ^Line_Index) {
    delete(li.marks)
    li^ = {}
}

// 行号（1-based）。
//
// 慢路径：二分定位到最后一个偏移 < o 的标记（它是第 j*stride 个换行），
// 于是"严格小于 o 的换行数" = j*stride + 1 + (marks[j], o) 区间里的换行数 ——
// 后者靠块内回扫数出来。稠密表 stride=1 时该区间为空（零回扫）。
//
// 快路径：hint 有效且 o 没跨出当前块时，从 hint.pos 继续往前数，
// 只扫"新增的那一段"（见 Line_Hint 的说明）。
//
// o 超过数据长度时按数据长度截断（与旧的全量表一致：返回"末尾行"的行号）。
line_of :: proc(li: Line_Index, offset: u64, hint: ^Line_Hint = nil) -> u64 {
    end := offset
    n := u64(len(li.data))
    if end > n {
        end = n
    }

    // ---- 快路径：沿用上次定位点 ----
    if hint != nil && hint.valid && end >= hint.pos {
        // 块的右边界：下一个标记。跨过它就说明这次查询离开了当前块。
        next_mark := ~u64(0)
        mi := hint.mark + 1
        if mi >= 0 && mi < len(li.marks) {
            next_mark = li.marks[mi]
        }
        if end <= next_mark {
            count := hint.count
            for i in hint.pos..<end {
                if li.data[i] == '\n' {
                    count += 1
                }
            }
            hint.pos = end
            hint.count = count
            return count + 1
        }
    }

    // ---- 慢路径：二分 + 块内回扫 ----
    lo := 0
    hi := len(li.marks)
    for lo < hi {
        mid := (lo + hi) / 2
        if li.marks[mid] < end {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    count := u64(0) // 严格小于 end 的换行数
    start := u64(0)
    mark := -1
    if lo > 0 {
        mark = lo - 1
        count = u64(mark) * li.stride + 1 // 含 marks[mark] 这个换行本身
        start = li.marks[mark] + 1
    }
    for i in start..<end {
        if li.data[i] == '\n' {
            count += 1
        }
    }
    if hint != nil {
        hint^ = Line_Hint {
            valid = true,
            mark  = mark,
            pos   = end,
            count = count,
        }
    }
    return count + 1
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
resolve_color :: proc(mode: lib.Color_Mode) -> bool {
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
