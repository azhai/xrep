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
//       都 `defer options_destroy(&x)`；否则内存追踪器会报 leak。
// ============================================================================

import "core:os"
import "core:testing"

// 便捷断言：把解析出的 pattern（[]u8）以字符串形式与期望比较。
// （[]u8 → string 不提供隐式转换，只能 transmute，与 s2b 相反方向一致。）
pattern_of :: proc(opts: Options) -> string {
    return transmute(string)opts.pattern
}

@(test)
test_parse_args_defaults :: proc(t: ^testing.T) {
    opts, outcome, msg := parse_args([]string{})
    defer options_destroy(&opts)
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
    // 目录遍历 / 输出类新增选项的默认值
    testing.expect(t, !opts.recursive)
    testing.expect(t, !opts.hidden)
    testing.expect(t, !opts.line_numbers)
    testing.expect(t, !opts.only_matching)
    testing.expect(t, !opts.json)
    testing.expect(t, !opts.stats)
    testing.expect_value(t, opts.max_count, uint(0))
    testing.expect_value(t, opts.list_mode, List_Mode.None)
    // 颜色默认 always：与加 --color 之前 use_color 恒为 true 的行为一致
    testing.expect_value(t, opts.color_mode, Color_Mode.Always)
    testing.expect_value(t, len(opts.patterns), 0)
    testing.expect_value(t, len(opts.globs), 0)
    testing.expect_value(t, len(opts.excludes), 0)
}

@(test)
test_parse_args_new_flags :: proc(t: ^testing.T) {
    // 新增开关：--skip-empty / --dump-append 是布尔；--max-size 取值
    opts, outcome, _ := parse_args([]string{"pat", "f", "--skip-empty", "--dump-append", "--max-size", "1024"})
    defer options_destroy(&opts)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect(t, opts.skip_empty)
    testing.expect(t, opts.dump_append)
    testing.expect_value(t, opts.max_size, u64(1024))

    // --max-size 0 表示不限制
    o0, _, _ := parse_args([]string{"pat", "f", "--max-size", "0"})
    defer options_destroy(&o0)
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
    defer options_destroy(&opts)
    testing.expect_value(t, o1, Parse_Outcome.Ok)
    testing.expect_value(t, opts.thread_count, uint(0))

    opts2, _, _ := parse_args([]string{"pat", "f", "--threads", "999999"})
    defer options_destroy(&opts2)
    testing.expect_value(t, opts2.thread_count, uint(999999))
}

@(test)
test_parse_args_positional_assignment :: proc(t: ^testing.T) {
    // 第一个非 flag 为模式，其余为文件列表（顺序保持）
    opts, outcome, _ := parse_args([]string{"needle", "a.bin", "b.bin"})
    defer options_destroy(&opts)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "needle")
    testing.expect_value(t, len(opts.file_list), 2)
    testing.expect_value(t, opts.file_list[0], "a.bin")
    testing.expect_value(t, opts.file_list[1], "b.bin")

    // flag 与位置参数交错时，位置参数语义不变
    opts2, o2, _ := parse_args([]string{"--count", "pat", "--quiet", "f1"})
    defer options_destroy(&opts2)
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
    defer options_destroy(&opts)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "--nope")
    testing.expect_value(t, len(opts.file_list), 0)
}

@(test)
test_parse_args_empty_string_argument :: proc(t: ^testing.T) {
    // 边界（既有语义）：空字符串被写入 pattern 后长度仍为 0，因此"模式位"并未被占用，
    // 下一个位置参数会顶替成为模式，file_list 仍为空。
    opts, outcome, _ := parse_args([]string{"", "file.bin"})
    defer options_destroy(&opts)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(opts), "file.bin")
    testing.expect_value(t, len(opts.file_list), 0)
    // 若首个非空串在第二位，则它成为模式，其后才是文件
    opts2, _, _ := parse_args([]string{"", "pat", "file.bin"})
    defer options_destroy(&opts2)
    testing.expect_value(t, pattern_of(opts2), "pat")
    testing.expect_value(t, len(opts2.file_list), 1)
    testing.expect_value(t, opts2.file_list[0], "file.bin")
}

@(test)
test_parse_args_numeric_flags :: proc(t: ^testing.T) {
    opts, outcome, _ := parse_args([]string{"pat", "f", "--threads", "8", "--limit", "3", "--context", "16"})
    defer options_destroy(&opts)
    testing.expect_value(t, outcome, Parse_Outcome.Ok)
    testing.expect_value(t, opts.thread_count, uint(8))
    testing.expect_value(t, opts.limit, uint(3))
    testing.expect_value(t, opts.context_bytes, uint(16))

    // --after / --before 使用 base 0：接受十进制与 0x 十六进制
    opts2, _, _ := parse_args([]string{"pat", "f", "--after", "10", "--before", "0x20"})
    defer options_destroy(&opts2)
    testing.expect_value(t, opts2.after, u64(10))
    testing.expect_value(t, opts2.before, u64(0x20))

    // 边界：--limit 0 表示不截断
    opts3, _, _ := parse_args([]string{"pat", "f", "--limit", "0"})
    defer options_destroy(&opts3)
    testing.expect_value(t, opts3.limit, uint(0))
    // 边界：--threads 0 在解析层原样保留（0），合法性由 main 的 clamp 负责
    opts4, o4, _ := parse_args([]string{"pat", "f", "--threads", "0"})
    defer options_destroy(&opts4)
    testing.expect_value(t, o4, Parse_Outcome.Ok)
    testing.expect_value(t, opts4.thread_count, uint(0))
}

@(test)
test_parse_args_boolean_and_string_flags :: proc(t: ^testing.T) {
    opts, outcome, _ := parse_args([]string{"pat", "f", "--ignore-case", "--count", "--offset-hex", "--quiet", "--test", "--bench", "--dump", "out.txt"})
    defer options_destroy(&opts)
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
    defer options_destroy(&opts2)
    testing.expect_value(t, o2, Parse_Outcome.Ok)
    testing.expect_value(t, opts2.dump_prefix, "p_")
    // --no-color 现在**真的生效**了：等价 --color=never（历史上是 no-op，见 README 契约#4）。
    testing.expect_value(t, opts2.color_mode, Color_Mode.Never)
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
    defer options_destroy(&mx)
    testing.expect_value(t, outcome, Parse_Outcome.Error)
    testing.expect_value(t, msg, "Error: --dump and --dump-prefix are mutually exclusive")

    // 单独使用任一选项都不冲突
    o1a, o1, _ := parse_args([]string{"pat", "f", "--dump", "a.txt"})
    defer options_destroy(&o1a)
    testing.expect_value(t, o1, Parse_Outcome.Ok)
    o2a, o2, _ := parse_args([]string{"pat", "f", "--dump-prefix", "p_"})
    defer options_destroy(&o2a)
    testing.expect_value(t, o2, Parse_Outcome.Ok)

    // 互斥检查晚于 --test/--bench 之后的位置参数处理：--test 单独出现仍为 Ok
    opts3, o3, _ := parse_args([]string{"--test"})
    defer options_destroy(&opts3)
    testing.expect_value(t, o3, Parse_Outcome.Ok)
    testing.expect(t, opts3.run_test)
}

// ---------------------------------------------------------------------------
// 参数规范化：--flag=value / 短别名 / 布尔捆绑
// ---------------------------------------------------------------------------

@(test)
test_normalize_args_forms :: proc(t: ^testing.T) {
    // 长 flag 的 `=` 写法拆成两个 token
    n1 := normalize_args([]string{"--threads=8"})
    defer delete(n1)
    testing.expect_value(t, len(n1), 2)
    testing.expect_value(t, n1[0], "--threads")
    testing.expect_value(t, n1[1], "8")

    // 布尔短 flag 捆绑：-rn → -r -n
    n2 := normalize_args([]string{"-rn"})
    defer delete(n2)
    testing.expect_value(t, len(n2), 2)
    testing.expect_value(t, n2[0], "--recursive")
    testing.expect_value(t, n2[1], "--line-number")

    // 取值短 flag：紧凑写法 `-t8`
    n3 := normalize_args([]string{"-t8"})
    defer delete(n3)
    testing.expect_value(t, n3[0], "--threads")
    testing.expect_value(t, n3[1], "8")

    // 取值短 flag：分离写法 `-t 8`（值留在下一个 token）
    n4 := normalize_args([]string{"-t", "8"})
    defer delete(n4)
    testing.expect_value(t, n4[0], "--threads")
    testing.expect_value(t, n4[1], "8")

    // 未知短 flag：整体原样保留（从而仍落到"位置参数"分支，与历史一致）
    n5 := normalize_args([]string{"-Zx"})
    defer delete(n5)
    testing.expect_value(t, len(n5), 1)
    testing.expect_value(t, n5[0], "-Zx")

    // 单破折号与 `--` 不受影响
    n6 := normalize_args([]string{"-", "--", "-"})
    defer delete(n6)
    testing.expect_value(t, len(n6), 3)
    testing.expect_value(t, n6[1], "--")
}

@(test)
test_parse_args_equals_and_short_forms :: proc(t: ^testing.T) {
    // 长 flag 的 `=` 写法
    o1, r1, _ := parse_args([]string{"pat", "f", "--threads=6", "--context=4"})
    defer options_destroy(&o1)
    testing.expect_value(t, r1, Parse_Outcome.Ok)
    testing.expect_value(t, o1.thread_count, uint(6))
    testing.expect_value(t, o1.context_bytes, uint(4))

    // 短别名，含取值型短 flag
    o2, r2, _ := parse_args([]string{"-i", "-c", "-t", "3", "-e", "pat", "f"})
    defer options_destroy(&o2)
    testing.expect_value(t, r2, Parse_Outcome.Ok)
    testing.expect(t, o2.ignore_case && o2.only_count)
    testing.expect_value(t, o2.thread_count, uint(3))
    testing.expect_value(t, len(o2.patterns), 1)
    testing.expect_value(t, o2.patterns[0], "pat")
    // 有 -e 时**所有**位置参数都是文件（grep 语义）
    testing.expect_value(t, len(o2.file_list), 1)
    testing.expect_value(t, o2.file_list[0], "f")

    // 布尔捆绑 -rn
    o3, r3, _ := parse_args([]string{"pat", "-rn", "d"})
    defer options_destroy(&o3)
    testing.expect_value(t, r3, Parse_Outcome.Ok)
    testing.expect(t, o3.recursive && o3.line_numbers)
}

// ---------------------------------------------------------------------------
// 多模式（-e / -f）
// ---------------------------------------------------------------------------

@(test)
test_parse_args_multi_pattern_flags :: proc(t: ^testing.T) {
    o, r, _ := parse_args([]string{"-e", "foo", "--pattern", "bar", "f1", "f2"})
    defer options_destroy(&o)
    testing.expect_value(t, r, Parse_Outcome.Ok)
    testing.expect_value(t, len(o.patterns), 2)
    testing.expect_value(t, o.patterns[0], "foo")
    testing.expect_value(t, o.patterns[1], "bar")
    // 主模式 = patterns[0]
    testing.expect_value(t, pattern_of(o), "foo")
    testing.expect_value(t, len(o.file_list), 2)
    testing.expect_value(t, o.file_list[0], "f1")

    _, r2, m2 := parse_args([]string{"--pattern"})
    testing.expect_value(t, r2, Parse_Outcome.Error)
    testing.expect_value(t, m2, "--pattern requires a value")
}

@(test)
test_parse_args_pattern_file :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_cli_patterns.txt"
    // CRLF 行尾要剥掉 \r；空行跳过（与 grep -f 一致）。
    // 显式经由 string 变量再转 []byte：避免 os.write_entire_file 的重载歧义
    // （[]byte 与 string 两个版本对无类型常量均匹配）。
    content: string = "foo\r\n\nbar\n"
    _ = os.write_entire_file(path, transmute([]byte)content)
    defer os.remove(path)

    o, r, _ := parse_args([]string{"-f", path, "f1"})
    defer options_destroy(&o)
    testing.expect_value(t, r, Parse_Outcome.Ok)
    testing.expect_value(t, len(o.patterns), 2)
    testing.expect_value(t, o.patterns[0], "foo")
    testing.expect_value(t, o.patterns[1], "bar")
    testing.expect_value(t, pattern_of(o), "foo")
    testing.expect_value(t, len(o.file_list), 1)

    // 文件不存在 → 参数错误（不是静默忽略）
    _, r2, m2 := parse_args([]string{"-f", "/tmp/xrep_ut_no_such_patterns_zz"})
    testing.expect_value(t, r2, Parse_Outcome.Error)
    testing.expect_value(t, m2, "cannot read pattern file: /tmp/xrep_ut_no_such_patterns_zz")
}

@(test)
test_match_ctx_from_options_multi :: proc(t: ^testing.T) {
    o, _, _ := parse_args([]string{"-e", "foo", "-e", "bar", "--ignore-case", "f"})
    defer options_destroy(&o)
    ctx := match_ctx_from_options(&o)
    testing.expect_value(t, transmute(string)ctx.pattern, "foo")
    testing.expect(t, ctx.case_insensitive)
    testing.expect_value(t, len(ctx.extra), 1)
    testing.expect_value(t, transmute(string)ctx.extra[0], "bar")
    testing.expect_value(t, ctx_pattern_count(ctx), 2)
    testing.expect_value(t, transmute(string)ctx_pattern_at(ctx, 0), "foo")
    testing.expect_value(t, transmute(string)ctx_pattern_at(ctx, 1), "bar")
}

// ---------------------------------------------------------------------------
// 目录遍历 / 输出类 flag
// ---------------------------------------------------------------------------

@(test)
test_parse_args_walk_and_output_flags :: proc(t: ^testing.T) {
    o, r, _ := parse_args(
        []string{"pat", "d", "-r", "--hidden", "-g", "*.c", "--exclude", "build", "-l", "--json", "--stats", "-m", "5", "-n", "-o"},
    )
    defer options_destroy(&o)
    testing.expect_value(t, r, Parse_Outcome.Ok)
    testing.expect(t, o.recursive)
    testing.expect(t, o.hidden)
    testing.expect_value(t, len(o.globs), 1)
    testing.expect_value(t, o.globs[0], "*.c")
    testing.expect_value(t, len(o.excludes), 1)
    testing.expect_value(t, o.excludes[0], "build")
    testing.expect_value(t, o.list_mode, List_Mode.Files_With)
    testing.expect(t, o.json)
    testing.expect(t, o.stats)
    testing.expect_value(t, o.max_count, uint(5))
    testing.expect(t, o.line_numbers)
    testing.expect(t, o.only_matching)

    // -L 会覆盖先出现的 -l
    o2, _, _ := parse_args([]string{"pat", "d", "-l", "-L"})
    defer options_destroy(&o2)
    testing.expect_value(t, o2.list_mode, List_Mode.Files_Without)
}

@(test)
test_parse_args_new_missing_values :: proc(t: ^testing.T) {
    cases := []struct {
        args: []string,
        msg:  string,
    }{
        {[]string{"--max-count"}, "--max-count requires number"},
        {[]string{"--glob"}, "--glob requires a pattern"},
        {[]string{"--exclude"}, "--exclude requires a pattern"},
        {[]string{"--pattern"}, "--pattern requires a value"},
        {[]string{"--file"}, "--file requires a path"},
        {[]string{"--color"}, "--color requires WHEN (always|never|auto)"},
    }
    for c in cases {
        _, outcome, msg := parse_args(c.args)
        testing.expectf(t, outcome == Parse_Outcome.Error, "%v 应报错", c.args)
        testing.expectf(t, msg == c.msg, "缺参提示应为 %q，实际 %q", c.msg, msg)
    }
}

@(test)
test_parse_args_max_count_invalid :: proc(t: ^testing.T) {
    _, o, m := parse_args([]string{"--max-count", "abc"})
    testing.expect_value(t, o, Parse_Outcome.Error)
    testing.expect_value(t, m, "invalid max-count: abc")
}

@(test)
test_parse_args_color_modes :: proc(t: ^testing.T) {
    // 默认 always：与加 --color 之前 use_color 恒为 true 一致（不是 auto！）
    o0, _, _ := parse_args([]string{"pat", "f"})
    defer options_destroy(&o0)
    testing.expect_value(t, o0.color_mode, Color_Mode.Always)

    cases := []struct {
        args: []string,
        mode: Color_Mode,
    }{
        {[]string{"pat", "f", "--color=never"}, Color_Mode.Never},
        {[]string{"pat", "f", "--color=auto"}, Color_Mode.Auto},
        {[]string{"pat", "f", "--color", "always"}, Color_Mode.Always},
        {[]string{"pat", "f", "--no-color"}, Color_Mode.Never},
    }
    for c in cases {
        o, r, _ := parse_args(c.args)
        defer options_destroy(&o)
        testing.expectf(t, r == Parse_Outcome.Ok, "%v 应解析成功", c.args)
        testing.expectf(t, o.color_mode == c.mode, "%v 的颜色模式应为 %v，实际 %v", c.args, c.mode, o.color_mode)
    }

    // 非法值
    _, r1, m1 := parse_args([]string{"--color", "pink"})
    testing.expect_value(t, r1, Parse_Outcome.Error)
    testing.expect_value(t, m1, "invalid color mode: pink")
}

@(test)
test_unknown_short_cluster_still_positional :: proc(t: ^testing.T) {
    // 未知短 flag 簇不被展开，原样成为模式 —— 保证加短别名没有改变旧行为。
    o, r, _ := parse_args([]string{"-Zx"})
    defer options_destroy(&o)
    testing.expect_value(t, r, Parse_Outcome.Ok)
    testing.expect_value(t, pattern_of(o), "-Zx")
    testing.expect_value(t, len(o.file_list), 0)
}

