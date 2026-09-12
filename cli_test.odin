package main

// ============================================================================
// cli_test.odin — 命令行解析单元测试
//
// 覆盖：位置参数分配（模式/文件列表）、全部 flag 的解析、默认值、
//       错误分支（缺参/非法数值/互斥冲突）、--help 的"即时退出"语义，
//       以及"未知 flag 被当作模式"这一既有行为。
//
// 说明：parse_args 已把 os.exit 剥离为三态返回值，因此这些用例可以
//       直接断言解析结果 —— 这正是本次拆分引入的可测试性收益。
//
// 内存：Options.file_list 是 parse_args 分配、**由调用方拥有**的动态数组
//       （见 cli.odin）。测试同样是调用方，因此凡是参数里带了文件名的用例
//       都 `defer delete(x.file_list)`；否则内存追踪器会报 leak。
// ============================================================================

import "core:testing"

// 便捷断言：把解析出的 pattern（[]u8）以字符串形式与期望比较。
// （[]u8 → string 不提供隐式转换，只能 transmute，与 s2b 相反方向一致。）
pattern_of :: proc(opts: Options) -> string {
    return transmute(string)opts.pattern
}

@(test)
test_parse_args_defaults :: proc(t: ^testing.T) {
    opts, outcome, msg := parse_args([]string{})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, msg, "")
    // 默认值：线程 4；before 为 u64 上界；其余为 0/false/空
    testing.expect_value(t, opts.thread_count, uint(4))
    testing.expect_value(t, opts.before, u64(0xFFFFFFFFFFFFFFFF))
    testing.expect_value(t, opts.after, u64(0))
    testing.expect_value(t, opts.limit, uint(0))
    testing.expect_value(t, opts.context_bytes, uint(0))
    testing.expect_value(t, len(opts.pattern), 0)
    testing.expect_value(t, len(opts.file_list), 0)
    testing.expect(t, !opts.ignore_case)
    testing.expect(t, !opts.run_test)
    testing.expect(t, !opts.do_bench)
    testing.expect(t, !opts.only_count)
    testing.expect(t, !opts.offset_hex)
    testing.expect(t, !opts.quiet)
    testing.expect_value(t, len(opts.dump_path), 0)
    testing.expect_value(t, len(opts.dump_prefix), 0)
    // 新增选项的默认值：一律"关闭"
    testing.expect(t, !opts.skip_empty)
    testing.expect(t, !opts.dump_append)
    testing.expect_value(t, opts.max_size, u64(0))
}

@(test)
test_parse_args_new_flags :: proc(t: ^testing.T) {
    // 新增开关：--skip-empty / --dump-append 是布尔；--max-size 取值
    opts, outcome, _ := parse_args([]string{"pat", "f", "--skip-empty", "--dump-append", "--max-size", "1024"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect(t, opts.skip_empty)
    testing.expect(t, opts.dump_append)
    testing.expect_value(t, opts.max_size, u64(1024))

    // --max-size 0 表示不限制
    o0, _, _ := parse_args([]string{"pat", "f", "--max-size", "0"})
    defer delete(o0.file_list)
    testing.expect_value(t, o0.max_size, u64(0))
}

@(test)
test_parse_args_max_size_errors :: proc(t: ^testing.T) {
    // 错误路径在写入 file_list 之前就返回，故这两个用例不产生需释放的分配。
    _, o1, m1 := parse_args([]string{"--max-size"})
    testing.expect_value(t, o1, Parse_Outcome.Error)
    testing.expect_value(t, m1, "--max-size requires byte count")

    _, o2, m2 := parse_args([]string{"--max-size", "abc"})
    testing.expect_value(t, o2, Parse_Outcome.Error)
    testing.expect_value(t, m2, "invalid max-size: abc")
}

@(test)
test_parse_args_version_outcome_and_immediacy :: proc(t: ^testing.T) {
    // --version / -v 返回 Version，且与 --help 一样"即时生效"
    // （Version/Help 在写入 file_list 之前返回，故无需释放）。
    _, o1, _ := parse_args([]string{"--version"})
    testing.expect_value(t, o1, Parse_Outcome.Version)
    _, o2, _ := parse_args([]string{"-v"})
    testing.expect_value(t, o2, Parse_Outcome.Version)

    opts3, o3, _ := parse_args([]string{"--version", "pat", "f"})
    testing.expect_value(t, o3, Parse_Outcome.Version)
    testing.expect_value(t, len(opts3.pattern), 0)

    // 先撞上的错误优先（与 --help 一致）
    _, o4, m4 := parse_args([]string{"--max-size", "x", "--version"})
    testing.expect_value(t, o4, Parse_Outcome.Error)
    testing.expect_value(t, m4, "invalid max-size: x")

    // --version 出现在非法旗标之前 → 仍然 Version
    _, o5, _ := parse_args([]string{"--version", "--max-size"})
    testing.expect_value(t, o5, Parse_Outcome.Version)
}

@(test)
test_parse_args_thread_count_passthrough_unclamped :: proc(t: ^testing.T) {
    // parse_args 刻意不夹取线程数（保持纯数据、断言可确定）；
    // 夹取发生在 main，见 common.clamp_thread_count。
    opts, o1, _ := parse_args([]string{"pat", "f", "--threads", "0"})
    defer delete(opts.file_list)
    testing.expect_value(t, o1, Parse_Outcome.Ok)
    testing.expect_value(t, opts.thread_count, uint(0))

    opts2, _, _ := parse_args([]string{"pat", "f", "--threads", "999999"})
    defer delete(opts2.file_list)
    testing.expect_value(t, opts2.thread_count, uint(999999))
}

@(test)
test_parse_args_positional_assignment :: proc(t: ^testing.T) {
    // 第一个非 flag 为模式，其余为文件列表（顺序保持）
    opts, outcome, _ := parse_args([]string{"needle", "a.bin", "b.bin"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "needle")
    testing.expect_value(t, len(opts.file_list), 2)
    testing.expect_value(t, opts.file_list[0], "a.bin")
    testing.expect_value(t, opts.file_list[1], "b.bin")

    // flag 与位置参数交错时，位置参数语义不变
    opts2, o2, _ := parse_args([]string{"--count", "pat", "--quiet", "f1"})
    defer delete(opts2.file_list)
    testing.expect_value(t, o2, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts2), "pat")
    testing.expect_value(t, len(opts2.file_list), 1)
    testing.expect_value(t, opts2.file_list[0], "f1")
    testing.expect(t, opts2.only_count && opts2.quiet)
}

@(test)
test_parse_args_unknown_flag_becomes_pattern :: proc(t: ^testing.T) {
    // 既有行为：无法识别的选项落入 default 分支，被当作模式处理。
    opts, outcome, _ := parse_args([]string{"--nope"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "--nope")
    testing.expect_value(t, len(opts.file_list), 0)
}

@(test)
test_parse_args_empty_string_argument :: proc(t: ^testing.T) {
    // 边界（既有语义）：空字符串被写入 pattern 后长度仍为 0，因此"模式位"并未被占用，
    // 下一个位置参数会顶替成为模式，file_list 仍为空。
    opts, outcome, _ := parse_args([]string{"", "file.bin"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "file.bin")
    testing.expect_value(t, len(opts.file_list), 0)
    // 若首个非空串在第二位，则它成为模式，其后才是文件
    opts2, _, _ := parse_args([]string{"", "pat", "file.bin"})
    defer delete(opts2.file_list)
    testing.expect_value(t, pattern_of(opts2), "pat")
    testing.expect_value(t, len(opts2.file_list), 1)
    testing.expect_value(t, opts2.file_list[0], "file.bin")
}

@(test)
test_parse_args_numeric_flags :: proc(t: ^testing.T) {
    opts, outcome, _ := parse_args([]string{"pat", "f", "--threads", "8", "--limit", "3", "--context", "16"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, opts.thread_count, uint(8))
    testing.expect_value(t, opts.limit, uint(3))
    testing.expect_value(t, opts.context_bytes, uint(16))

    // --after / --before 使用 base 0：接受十进制与 0x 十六进制
    opts2, _, _ := parse_args([]string{"pat", "f", "--after", "10", "--before", "0x20"})
    defer delete(opts2.file_list)
    testing.expect_value(t, opts2.after, u64(10))
    testing.expect_value(t, opts2.before, u64(0x20))

    // 边界：--limit 0 表示不截断
    opts3, _, _ := parse_args([]string{"pat", "f", "--limit", "0"})
    defer delete(opts3.file_list)
    testing.expect_value(t, opts3.limit, uint(0))
    // 边界：--threads 0 在解析层原样保留（0），合法性由 main 的 clamp 负责
    opts4, o4, _ := parse_args([]string{"pat", "f", "--threads", "0"})
    defer delete(opts4.file_list)
    testing.expect_value(t, o4, Parse_Outcome.Ok)
    testing.expect_value(t, opts4.thread_count, uint(0))
}

@(test)
test_parse_args_boolean_and_string_flags :: proc(t: ^testing.T) {
    opts, outcome, _ := parse_args([]string{"pat", "f", "--ignore-case", "--count", "--offset-hex", "--quiet", "--test", "--bench", "--dump", "out.txt"})
    defer delete(opts.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect(t, opts.ignore_case)
    testing.expect(t, opts.only_count)
    testing.expect(t, opts.offset_hex)
    testing.expect(t, opts.quiet)
    testing.expect(t, opts.run_test)
    testing.expect(t, opts.do_bench)
    testing.expect_value(t, opts.dump_path, "out.txt")

    // --dump-prefix 与 --no-color
    opts2, o2, _ := parse_args([]string{"pat", "f", "--dump-prefix", "p_", "--no-color"})
    defer delete(opts2.file_list)
    testing.expect_value(t, o2, Parse_Outcome.Ok)
    testing.expect_value(t, opts2.dump_prefix, "p_")
    // --no-color 是已接受的 no-op：不得报错、不得改变其它字段
    testing.expect_value(t, len(opts2.dump_path), 0)
    testing.expect_value(t, opts2.thread_count, uint(4))
}

@(test)
test_parse_args_help_outcome_and_immediacy :: proc(t: ^testing.T) {
    // --help / -h 均返回 Help（同样在写入 file_list 之前返回，无需释放）
    _, o1, _ := parse_args([]string{"--help"})
    testing.expect_value(t, o1, Parse_Outcome.Help)
    _, o2, _ := parse_args([]string{"-h"})
    testing.expect_value(t, o2, Parse_Outcome.Help)

    // 即时生效：--help 之后的参数不再解析（因此 pattern 仍为空）
    opts3, o3, _ := parse_args([]string{"--help", "pat", "f"})
    testing.expect_value(t, o3, Parse_Outcome.Help)
    testing.expect_value(t, len(opts3.pattern), 0)

    // 即时生效的反向证明：--help 之前已发生的错误优先，进程应以错误退出
    _, o4, msg4 := parse_args([]string{"--threads", "abc", "--help"})
    testing.expect_value(t, o4, Parse_Outcome.Error)
    testing.expect_value(t, msg4, "invalid threads: abc")

    // --help 出现在非法旗标之前 → 仍然 Help
    _, o5, _ := parse_args([]string{"--help", "--threads"})
    testing.expect_value(t, o5, Parse_Outcome.Help)
}

@(test)
test_parse_args_missing_values :: proc(t: ^testing.T) {
    // 每个"需要取值"的选项在缺参时都必须报错，且信息与拆分前逐字一致。
    // 这些 args 都不含文件名位置参数，故不会分配 file_list。
    cases := []struct {
        args: []string,
        msg:  string,
    }{
        {[]string{"--threads"}, "--threads requires number"},
        {[]string{"--limit"}, "--limit requires number"},
        {[]string{"--after"}, "--after requires offset"},
        {[]string{"--before"}, "--before requires offset"},
        {[]string{"--context"}, "--context requires byte count"},
        {[]string{"--dump"}, "--dump requires output file"},
        {[]string{"--dump-prefix"}, "--dump-prefix requires prefix string"},
    }
    for c in cases {
        _, outcome, msg := parse_args(c.args)
        testing.expectf(t, outcome == Parse_Outcome.Error, "%v 应报错", c.args)
        testing.expectf(t, msg == c.msg, "缺参提示应为 %q，实际 %q", c.msg, msg)
    }
}

@(test)
test_parse_args_invalid_values :: proc(t: ^testing.T) {
    // 同上：非法值在遍历中即返回，用例参数不含文件名位置参数。
    cases := []struct {
        args: []string,
        msg:  string,
    }{
        {[]string{"--threads", "abc"}, "invalid threads: abc"},
        {[]string{"--limit", "xx"}, "invalid limit: xx"},
        {[]string{"--after", "zz"}, "invalid after offset: zz"},
        {[]string{"--before", "qq"}, "invalid before offset: qq"},
        {[]string{"--context", "yy"}, "invalid context: yy"},
    }
    for c in cases {
        _, outcome, msg := parse_args(c.args)
        testing.expectf(t, outcome == Parse_Outcome.Error, "%v 应报错", c.args)
        testing.expectf(t, msg == c.msg, "非法值提示应为 %q，实际 %q", c.msg, msg)
    }
}

@(test)
test_parse_args_dump_conflict :: proc(t: ^testing.T) {
    // --dump 与 --dump-prefix 互斥：检查发生在遍历结束之后
    // （互斥错误在遍历结束后才抛出，因此 file_list 已经分配，必须释放）
    mx, outcome, msg := parse_args([]string{"pat", "f", "--dump", "a.txt", "--dump-prefix", "p_"})
    defer delete(mx.file_list)
    testing.expect_value(t, outcome, Parse_Outcome.Error)
    testing.expect_value(t, msg, "Error: --dump and --dump-prefix are mutually exclusive")

    // 单独使用任一选项都不冲突
    o1a, o1, _ := parse_args([]string{"pat", "f", "--dump", "a.txt"})
    defer delete(o1a.file_list)
    testing.expect_value(t, o1, Parse_Outcome.Ok)
    o2a, o2, _ := parse_args([]string{"pat", "f", "--dump-prefix", "p_"})
    defer delete(o2a.file_list)
    testing.expect_value(t, o2, Parse_Outcome.Ok)

    // 互斥检查晚于 --test/--bench 之后的位置参数处理：--test 单独出现仍为 Ok
    opts3, o3, _ := parse_args([]string{"--test"})
    defer delete(opts3.file_list)
    testing.expect_value(t, o3, Parse_Outcome.Ok)
    testing.expect(t, opts3.run_test)
}
