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
//
// 依赖：core:fmt、core:os。
// ============================================================================

import "core:fmt"
import "core:os"

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
