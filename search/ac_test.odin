package search

// ============================================================================
// ac_test.odin — Aho-Corasick 自动机单元测试
//
// 核心判据：AC 只是 multi_match 的**加速实现**，不是另一种语义。因此所有用例
// 都以 multi_match（它本身已与 naive_match 做过差分）为参考，要求
// **偏移序列与 pat_len 逐条一致**，而不只是"命中集合相同"。
//
// 顺序为什么值得单独测：AC 按"结束位置"产出，而契约是"起点偏移升序、同起点
// 按模式序号升序"。长短悬殊的模式组合会让"后结束的长模式"起点更小，这正是
// 延迟线要修的情形（见 ac.odin 的 multi_ac_match）。
//
// 内存：本文件在循环里批量造数据/模式，**一律显式 delete** —— 写在循环体里的
//       defer 会在该轮迭代结束时执行，把还在用的 pats[k] 释放掉（悬垂指针）。
// ============================================================================

import "core:fmt"
import "core:testing"
import "xrep:lib"

// 逐条比对两个命中序列（偏移 + pat_len）。标签在内部构造并就地释放，
// 因此调用点不需要再管标签的生存期。
expect_same_hits :: proc(t: ^testing.T, idx: int, ci: bool, got: []lib.Match_Result, want: []lib.Match_Result) {
    what := fmt.aprintf("case#%d ci=%v", idx, ci)
    defer delete(what)
    testing.expectf(t, len(got) == len(want), "%s: AC %d 条，参考 %d 条", what, len(got), len(want))
    lim := len(got)
    if len(want) < lim {
        lim = len(want)
    }
    for i in 0..<lim {
        testing.expectf(
            t,
            got[i].offset == want[i].offset && got[i].pat_len == want[i].pat_len,
            "%s: 第 %d 条 AC=(%d,%d) 参考=(%d,%d)",
            what,
            i,
            got[i].offset,
            got[i].pat_len,
            want[i].offset,
            want[i].pat_len,
        )
    }
}

@(test)
test_ac_matches_multi_match :: proc(t: ^testing.T) {
    p := test_progress()
    // 字母表只有 a..c → 命中密集，容易撞出"同一起点多模式""长模式起点更小"等形态
    rng: u32 = 0x9E3779B9
    data := make([]u8, 4096)
    for i in 0..<len(data) {
        rng = rng * 1664525 + 1013904223
        data[i] = u8('a' + (rng >> 16) % 3)
    }
    copy(data[512:517], lib.s2b("abcab"))
    copy(data[4091:4096], lib.s2b("ccccc"))

    sets := [][][]u8{
        // 前缀重叠：同一偏移两条命中，顺序必须按模式序号
        {lib.s2b("ab"), lib.s2b("abc"), lib.s2b("abcd")},
        // 长短悬殊：后结束的长模式起点更小 —— 延迟线必须把它们排好
        {lib.s2b("c"), lib.s2b("abcab"), lib.s2b("a")},
        // 重复模式：同一模式出现两次，应各报一条（不去重）
        {lib.s2b("ab"), lib.s2b("ab")},
        // 含空模式（应被跳过）
        {lib.s2b("ab"), lib.s2b(""), lib.s2b("bc")},
        // 与数据尾部对齐
        {lib.s2b("ccccc"), lib.s2b("ccc"), lib.s2b("c")},
        // 全不命中
        {lib.s2b("zz"), lib.s2b("aaaaaaaa"), lib.s2b("q")},
        // 只有一个非空模式（自动机退化成一条链）
        {lib.s2b("abcab"), lib.s2b("")},
    }
    ci_cases := []bool{false, true}
    for set, si in sets {
        for ci in ci_cases {
            ctx := lib.Match_Ctx{pattern = set[0], extra = set[1:], case_insensitive = ci}
            want := multi_match(data, ctx, &p)
            got := multi_ac_match(data, ctx, &p)
            expect_same_hits(t, si, ci, got, want)
            delete(got)
            delete(want)
        }
    }
    delete(data)
}

@(test)
test_ac_random_pattern_sets :: proc(t: ^testing.T) {
    // 随机模式集 × 随机数据：覆盖手工列不出的数据/模式组合。
    p := test_progress()
    rng: u32 = 0xC0FFEE01
    ci_cases := []bool{false, true}

    for trial in 0..<40 {
        n := 1 + int((rng >> 16) % 600)
        rng = rng * 1664525 + 1013904223
        data := make([]u8, n)
        for i in 0..<n {
            rng = rng * 1664525 + 1013904223
            data[i] = u8('a' + (rng >> 16) % 3)
        }
        npat := 1 + int((rng >> 16) % 8)
        rng = rng * 1664525 + 1013904223
        pats := make([][]u8, npat)
        for k in 0..<npat {
            rng = rng * 1664525 + 1013904223
            plen := int((rng >> 16) % 6) // 0..5，含空模式
            pat := make([]u8, plen)
            for j in 0..<plen {
                rng = rng * 1664525 + 1013904223
                pat[j] = u8('a' + (rng >> 16) % 3)
            }
            pats[k] = pat
        }
        for ci in ci_cases {
            ctx := lib.Match_Ctx{pattern = pats[0], extra = pats[1:], case_insensitive = ci}
            want := multi_match(data, ctx, &p)
            got := multi_ac_match(data, ctx, &p)
            expect_same_hits(t, trial, ci, got, want)
            delete(got)
            delete(want)
        }
        for k in 0..<npat {
            delete(pats[k])
        }
        delete(pats)
        delete(data)
    }
}

@(test)
test_ac_order_long_and_short :: proc(t: ^testing.T) {
    // 最容易被延迟线漏掉的一例：短模式先结束（起点 2），长模式后结束（起点 0）。
    // multi_match 的顺序是"起点升序"：0（aacde）在前、2（c）在后。
    p := test_progress()
    data := lib.s2b("aacde")
    ctx := lib.Match_Ctx{pattern = lib.s2b("c"), extra = [][]u8{lib.s2b("aacde")}}
    got := multi_ac_match(data, ctx, &p)
    defer delete(got)
    want := multi_match(data, ctx, &p)
    defer delete(want)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0].offset, u64(0))
    testing.expect_value(t, got[0].pat_len, u32(5))
    testing.expect_value(t, got[1].offset, u64(2))
    testing.expect_value(t, got[1].pat_len, u32(1))
}

@(test)
test_ac_same_start_two_patterns :: proc(t: ^testing.T) {
    // 同一起点被两个前缀相关的模式命中：顺序按**模式序号**，不是按长度。
    p := test_progress()
    data := lib.s2b("test")
    // 模式 0 = "tes"（短），模式 1 = "test"（长）
    ctx := lib.Match_Ctx{pattern = lib.s2b("tes"), extra = [][]u8{lib.s2b("test")}}
    got := multi_ac_match(data, ctx, &p)
    defer delete(got)
    want := multi_match(data, ctx, &p)
    defer delete(want)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0].offset, u64(0))
    testing.expect_value(t, got[0].pat_len, u32(3)) // "tes" 先
    testing.expect_value(t, got[1].offset, u64(0))
    testing.expect_value(t, got[1].pat_len, u32(4)) // "test" 后
}

@(test)
test_ac_edges :: proc(t: ^testing.T) {
    p := test_progress()
    // 空数据
    {
        ctx := lib.Match_Ctx{pattern = lib.s2b("a"), extra = [][]u8{lib.s2b("b"), lib.s2b("c"), lib.s2b("d")}}
        got := multi_ac_match([]u8{}, ctx, &p)
        defer delete(got)
        testing.expect_value(t, len(got), 0)
    }
    // 全空模式 → 自动机只有根，max_len = 0
    {
        ctx := lib.Match_Ctx{pattern = lib.s2b(""), extra = [][]u8{lib.s2b(""), lib.s2b(""), lib.s2b("")}}
        got := multi_ac_match(lib.s2b("aaa"), ctx, &p)
        defer delete(got)
        testing.expect_value(t, len(got), 0)
    }
    // 模式比数据长：无命中，但仍要上报扫描量
    {
        ctx := lib.Match_Ctx{pattern = lib.s2b("abcdef"), extra = [][]u8{lib.s2b("x"), lib.s2b("y"), lib.s2b("z")}}
        got := multi_ac_match(lib.s2b("abc"), ctx, &p)
        defer delete(got)
        testing.expect_value(t, len(got), 0)
    }
    // 数据长度 < max_len：延迟线的"收尾"分支（起点都没到倒出时机）
    {
        ctx := lib.Match_Ctx{pattern = lib.s2b("b"), extra = [][]u8{lib.s2b("a"), lib.s2b("abab"), lib.s2b("a")}}
        got := multi_ac_match(lib.s2b("ab"), ctx, &p)
        defer delete(got)
        want := multi_match(lib.s2b("ab"), ctx, &p)
        defer delete(want)
        testing.expect_value(t, len(got), len(want))
    }
}

@(test)
test_ac_reports_scanned_bytes :: proc(t: ^testing.T) {
    p: lib.Progress
    lib.progress_init(&p, 100, false, true)
    ctx := lib.Match_Ctx{
        pattern = lib.s2b("ab"),
        extra   = [][]u8{lib.s2b("bc"), lib.s2b("ca"), lib.s2b("abc")},
    }
    r := multi_ac_match(lib.s2b("abcabc"), ctx, &p)
    defer delete(r)
    testing.expect_value(t, p.scanned, u64(6))
}

@(test)
test_ac_worth_it_threshold :: proc(t: ^testing.T) {
    // 少于 AC_MIN_PATTERNS 个模式：不值得建自动机
    few := lib.Match_Ctx{pattern = lib.s2b("a"), extra = [][]u8{lib.s2b("b")}}
    testing.expect(t, !ac_worth_it(few), "2 个模式不应启用 AC")

    // 刚好达到阈值：用两字节模式凑够个数（总长度远低于 AC_MAX_STATES）
    pats := make([][]u8, AC_MIN_PATTERNS)
    defer delete(pats)
    for k in 0..<AC_MIN_PATTERNS {
        pats[k] = []u8{u8('a' + k % 26), u8('a' + (k * 7) % 26)}
    }
    at_threshold := lib.Match_Ctx{pattern = pats[0], extra = pats[1:]}
    testing.expect(t, ac_worth_it(at_threshold), "达到阈值应启用 AC")
    testing.expect(
        t,
        select_matcher_for(at_threshold) == multi_ac_match,
        "达到阈值应分派到 multi_ac_match",
    )
    testing.expect(t, select_matcher_for(few) == multi_match, "未达阈值应仍是 multi_match")

    // 阈值以下一个（多模式）也应退回 multi_match
    below := lib.Match_Ctx{pattern = pats[0], extra = pats[1:len(pats) - 1]}
    testing.expect(t, !ac_worth_it(below), "少一个模式不应启用 AC")

    // 模式很多但总长度超限：退回 multi_match（保护单次构建的内存开销）
    big := make([][]u8, AC_MAX_STATES / 8 + 2)
    defer {
        for p in big {
            delete(p)
        }
        delete(big)
    }
    for k in 0..<len(big) {
        p := make([]u8, 8)
        for j in 0..<8 {
            p[j] = u8('a' + (k + j) % 26)
        }
        big[k] = p
    }
    huge := lib.Match_Ctx{pattern = big[0], extra = big[1:]}
    testing.expect(t, !ac_worth_it(huge), "总长度超限应退回 multi_match")

    // 单模式永远不该走 AC
    single := lib.Match_Ctx{pattern = lib.s2b("ab")}
    testing.expect(t, select_matcher_for(single) == select_matcher(2), "单模式走长度分派")
}

@(test)
test_ac_many_patterns :: proc(t: ^testing.T) {
    // 64 个模式：AC 的主场。结果与 multi_match 必须逐条一致。
    p := test_progress()
    rng: u32 = 0xABCDEF01
    data := make([]u8, 8192)
    for i in 0..<len(data) {
        rng = rng * 1664525 + 1013904223
        data[i] = u8('a' + (rng >> 16) % 5)
    }

    npat := 64
    pats := make([][]u8, npat)
    for k in 0..<npat {
        pat := make([]u8, 2 + k % 5)
        for j in 0..<len(pat) {
            rng = rng * 1664525 + 1013904223
            pat[j] = u8('a' + (rng >> 16) % 5)
        }
        pats[k] = pat
    }

    ctx := lib.Match_Ctx{pattern = pats[0], extra = pats[1:]}
    testing.expect(t, ac_worth_it(ctx), "64 个短模式应启用 AC")
    got := multi_ac_match(data, ctx, &p)
    want := multi_match(data, ctx, &p)
    expect_same_hits(t, 0, false, got, want)
    delete(got)
    delete(want)

    for k in 0..<npat {
        delete(pats[k])
    }
    delete(pats)
    delete(data)
}
