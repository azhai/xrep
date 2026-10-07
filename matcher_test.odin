package main

// ============================================================================
// matcher_test.odin — 匹配算法层单元测试
//
// 覆盖：
//   * select_matcher 的长度区间边界（1 / 2 / 16 / 17 / 64 / 65 / 0）与空表回退
//   * single_match / naive_match 的正确性（重叠命中、大小写、空数据、模式超长）
//   * bndm_match 与 naive_match 的委托一致性
//   * 三种算法在同一输入上的结果一致性
//   * **差分测试**：把各算法与一个"独立参考实现"（core:strings 的 index）
//     在确定性伪随机数据上逐条比对 —— 覆盖 8 种模式 × 大小写两态
//   * multi_match 的命中集合 == 各单模式命中集合的多重集并集
//   * 各算法向 Progress 上报的已扫字节数
//
// 内存约定：命中数组由默认分配器（堆）承载，不再由 arena 承载 —— arena 定长，
//           超容量时 append 会静默丢命中（见 matcher.odin 文件头 / ADR 0004）。
//           返回值归调用方所有，故每个用例都用 defer delete 释放。
// 初始化： alg_table 是编译期常量；lower_table 由 `@(init)` 在启动时填充。
//           两者都不需要用例手动初始化（main 与 `odin test` 启动路径一致）。
// ============================================================================


import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

// 构造一个关闭渲染的进度条，避免测试输出被进度条干扰。
// （enabled=false 时 progress_add 不累加、不渲染。）
test_progress :: proc() -> Progress {
    p: Progress
    progress_init(&p, 0, false, false)
    return p
}

@(test)
test_select_matcher_boundaries :: proc(t: ^testing.T) {
    // 区间边界逐一验证：1 → single；2..16 → bndm；17..64 → naive
    testing.expect(t, select_matcher(1) == single_match, "len=1 应选 single_match")
    testing.expect(t, select_matcher(2) == bndm_match, "len=2 应选 bndm_match")
    testing.expect(t, select_matcher(16) == bndm_match, "len=16 应选 bndm_match")
    testing.expect(t, select_matcher(17) == naive_match, "len=17 应选 naive_match")
    testing.expect(t, select_matcher(64) == naive_match, "len=64 应选 naive_match")

    // 区间外：0 与 >64 都回退 naive_match
    testing.expect(t, select_matcher(0) == naive_match, "len=0 应回退 naive_match")
    testing.expect(t, select_matcher(65) == naive_match, "len=65 应回退 naive_match")
    testing.expect(t, select_matcher(4096) == naive_match, "超长模式应回退 naive_match")

    // 说明：alg_table 现为**编译期常量**，"空表回退"这一状态已不可能出现，
    // 故不再有对应断言；回退分支只在这里的区间外长度上被覆盖。
}

@(test)
test_single_match :: proc(t: ^testing.T) {
    p := test_progress()

    // 常规：单字节模式在数据中多次出现
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 3)
        testing.expect_value(t, got[0].offset, u64(1))
        testing.expect_value(t, got[1].offset, u64(3))
        testing.expect_value(t, got[2].offset, u64(5))
    }
    // 边界：无命中
    {
        ctx := Match_Ctx{pattern = s2b("z"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 边界：空数据
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := single_match(s2b(""), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 大小写不敏感：大写模式也能命中
    {
        ctx := Match_Ctx{pattern = s2b("B"), case_insensitive = true}
        got := single_match(s2b("banana"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
    // 大小写敏感：大写模式不应命中
    {
        ctx := Match_Ctx{pattern = s2b("B"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 非 ASCII 字节必须按原始字节匹配（不被 lower 表改写）
    {
        data := []u8{0xC3, 0x80, 0xC3, 0x80} // UTF-8 "ÀÀ"
        ctx := Match_Ctx{pattern = []u8{0xC3}, case_insensitive = true}
        got := single_match(data, ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 2)
    }
}

@(test)
test_naive_match :: proc(t: ^testing.T) {
    p := test_progress()

    // 常规：单次命中
    {
        ctx := Match_Ctx{pattern = s2b("ab"), case_insensitive = false}
        got := naive_match(s2b("xxabxx"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(2))
    }
    // 重叠命中：模式 "aa" 在 "aaaa" 中产生 3 个位置（0/1/2）
    {
        ctx := Match_Ctx{pattern = s2b("aa"), case_insensitive = false}
        got := naive_match(s2b("aaaa"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 3)
        testing.expect_value(t, got[0].offset, u64(0))
        testing.expect_value(t, got[1].offset, u64(1))
        testing.expect_value(t, got[2].offset, u64(2))
    }
    // 边界：空模式 → 空结果（不得死循环或越界）
    {
        ctx := Match_Ctx{pattern = s2b(""), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 边界：模式比数据长 → 空结果
    {
        ctx := Match_Ctx{pattern = s2b("abcdef"), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 边界：模式与数据等长 → 命中一次（偏移 0）
    {
        ctx := Match_Ctx{pattern = s2b("abc"), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
    // 边界：空数据
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := naive_match(s2b(""), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 大小写不敏感：混合大小写互相命中
    {
        ctx := Match_Ctx{pattern = s2b("AbC"), case_insensitive = true}
        got := naive_match(s2b("xxaBcxx"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(2))
    }
    // 大小写敏感：混合大小写不应命中
    {
        ctx := Match_Ctx{pattern = s2b("AbC"), case_insensitive = false}
        got := naive_match(s2b("xxaBcxx"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 0)
    }
    // 边界：命中出现在数据末尾
    {
        ctx := Match_Ctx{pattern = s2b("test"), case_insensitive = false}
        got := naive_match(s2b("aaaa test"), ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(5))
    }
    // 含 NUL 的二进制数据必须可匹配（不能按 C 字符串处理）
    {
        data := []u8{0x00, 0x01, 0x41, 0x00, 0x41}
        ctx := Match_Ctx{pattern = []u8{0x00, 0x41}, case_insensitive = false}
        got := naive_match(data, ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        // 仅偏移 3 处对齐（偏移 0 处第二字节为 0x01，不匹配）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(3))
    }
    // 边界：命中位于模式长度不足的尾部 → 不产生命中（上界保护）
    {
        data := []u8{0x00, 0x41, 0x00}
        ctx := Match_Ctx{pattern = []u8{0x00, 0x41}, case_insensitive = false}
        got := naive_match(data, ctx, &p)
        defer delete(got)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
}

@(test)
test_bndm_matches_naive :: proc(t: ^testing.T) {
    p := test_progress()

    // bndm_match 当前委托 naive_match，两者结果必须逐项一致（含偏移顺序）。
    data := s2b("abcabcabXabc")
    ctx := Match_Ctx{pattern = s2b("abc"), case_insensitive = false}
    a := bndm_match(data, ctx, &p)
    defer delete(a)  // 返回值归调用方所有（堆分配，见 matcher.odin）
    testing.expect_value(t, len(a), 3)
    b := naive_match(data, ctx, &p)
    defer delete(b)  // 返回值归调用方所有（堆分配，见 matcher.odin）
    testing.expect_value(t, len(b), 3)
    for i in 0..<len(a) {
        testing.expect_value(t, a[i].offset, b[i].offset)
    }
}

@(test)
test_matchers_agree_across_algorithms :: proc(t: ^testing.T) {
    p := test_progress()

    // 合成一段可预测的数据：周期 7 的字节序列，并埋入若干模式实例。
    data := make([]u8, 512)
    for i in 0..<len(data) {
        data[i] = u8('a' + (i % 7))
    }
    copy(data[100:104], s2b("aaaa"))
    copy(data[300:304], s2b("aaaa"))

    // 单字节模式：single 与 naive 结果必须一致
    {
        pat := s2b("d")
        ctx := Match_Ctx{pattern = pat, case_insensitive = false}
        s1 := single_match(data, ctx, &p)
        defer delete(s1)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        n1 := naive_match(data, ctx, &p)
        defer delete(n1)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(s1), len(n1))
        for i in 0..<len(s1) {
            testing.expect_value(t, s1[i].offset, n1[i].offset)
        }
    }
    // 4 字节模式：bndm（委托 naive）与 naive 必须一致，且命中数符合埋点
    {
        ctx := Match_Ctx{pattern = s2b("aaaa"), case_insensitive = false}
        b1 := bndm_match(data, ctx, &p)
        defer delete(b1)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        n1 := naive_match(data, ctx, &p)
        defer delete(n1)  // 返回值归调用方所有（堆分配，见 matcher.odin）
        testing.expect_value(t, len(b1), len(n1))
        // 偏移 100 与 300 处各埋入 "aaaa"，其中偏移 100 处的 a 也存在于周期序列中，
        // 因此只断言"至少包含这两处"，避免依赖周期数据的巧合匹配。
        found_100, found_300 := false, false
        for m in b1 {
            if m.offset == 100 { found_100 = true }
            if m.offset == 300 { found_300 = true }
        }
        testing.expect(t, found_100 && found_300, "应命中埋入的 100/300 两处")
    }
    delete(data)
}

// ---------------------------------------------------------------------------
// 多模式（-e / -f）：select_matcher_for 与 multi_match
// ---------------------------------------------------------------------------

@(test)
test_select_matcher_for_dispatch :: proc(t: ^testing.T) {
    // 单模式：走长度分派，结果必须与 select_matcher 完全一致（零回退）
    single := Match_Ctx{pattern = s2b("ab")}
    testing.expect(t, select_matcher_for(single) == select_matcher(2), "单模式应走长度分派")
    single1 := Match_Ctx{pattern = s2b("a")}
    testing.expect(t, select_matcher_for(single1) == single_match, "1 字节应选 single_match")

    // 多模式：统一走 multi_match
    multi := Match_Ctx{pattern = s2b("ab"), extra = [][]u8{s2b("cd")}}
    testing.expect(t, select_matcher_for(multi) == multi_match, "多模式应走 multi_match")
}

@(test)
test_multi_match_correctness :: proc(t: ^testing.T) {
    p := test_progress()

    // "foo test bar testfoo" 中：foo@0、test@4、test@13、foo@17
    data := s2b("foo test bar testfoo")
    ctx := Match_Ctx{pattern = s2b("test"), extra = [][]u8{s2b("foo")}}
    got := multi_match(data, ctx, &p)
    defer delete(got)
    testing.expect_value(t, len(got), 4)
    testing.expect_value(t, got[0].offset, u64(0))
    testing.expect_value(t, got[0].pat_len, u32(3)) // 命中 foo
    testing.expect_value(t, got[1].offset, u64(4))
    testing.expect_value(t, got[1].pat_len, u32(4)) // 命中 test
    testing.expect_value(t, got[2].offset, u64(13))
    testing.expect_value(t, got[2].pat_len, u32(4))
    testing.expect_value(t, got[3].offset, u64(17))
    testing.expect_value(t, got[3].pat_len, u32(3))
}

@(test)
test_multi_match_case_insensitive :: proc(t: ^testing.T) {
    p := test_progress()

    data := s2b("FOO Test")
    ctx := Match_Ctx{pattern = s2b("test"), case_insensitive = true, extra = [][]u8{s2b("foo")}}
    got := multi_match(data, ctx, &p)
    defer delete(got)
    testing.expect_value(t, len(got), 2)
    testing.expect_value(t, got[0].offset, u64(0))
    testing.expect_value(t, got[1].offset, u64(4))
}

@(test)
test_multi_match_empty_pattern_skipped :: proc(t: ^testing.T) {
    p := test_progress()

    // 空模式不产生命中（与 naive_match 对空模式的约定一致）
    data := s2b("abc")
    ctx := Match_Ctx{pattern = s2b(""), extra = [][]u8{s2b("b")}}
    got := multi_match(data, ctx, &p)
    defer delete(got)
    testing.expect_value(t, len(got), 1)
    testing.expect_value(t, got[0].offset, u64(1))
    testing.expect_value(t, got[0].pat_len, u32(1))
}

// ---------------------------------------------------------------------------
// 回归：命中数组不得因分配器容量上限而静默丢命中（ADR 0004）
// ---------------------------------------------------------------------------

// 历史缺陷：命中数组曾从定长 arena 分配。适配器内部按 2 倍扩容，
// 而扩容需要"旧缓冲 + 新缓冲"同时在世，因此峰值占用 ≈ 最终容量的 2 倍。
// 当峰值超过 arena 块（当时 16 MiB）时，Odin 的 append **静默失败**：
// 不报错、不 panic，只是后续命中全部丢失。
// 该用例的规模（60 万条单字节命中，结果区约 9.6 MiB，扩容峰值约 19.2 MiB）
// 恰好越过旧的 16 MiB 上限 —— 因此它能真正区分修复前后。
@(test)
test_dense_results_not_truncated :: proc(t: ^testing.T) {
    p := test_progress()

    N :: 600_000
    data := make([]u8, N)
    defer delete(data)
    for i in 0..<len(data) {
        data[i] = 'a'
    }

    ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
    got := single_match(data, ctx, &p)
    defer delete(got)

    testing.expect_value(t, len(got), N)
    // 首尾命中偏移必须正确（防止"数量对但内容错"的伪修复）
    testing.expect_value(t, got[0].offset, u64(0))
    testing.expect_value(t, got[N - 1].offset, u64(N - 1))
}

// ---------------------------------------------------------------------------
// 差分测试：与独立参考实现逐条比对
//
// 为什么要差分而不是再手写一遍期望值：把"手写的朴素比较"再抄一遍当断言，
// 等于把同一处理解错误复制两份。这里改用 core:strings 的 index 作为**预言机**
// —— 它与被测实现没有共享代码路径，因此任何一边写错都会立刻暴露。
// ---------------------------------------------------------------------------

// 参考实现：反复用标准库子串查找定位下一个命中，保留重叠。
// 前提：调用方已把两侧的大小写统一（大小写不敏感时先整体小写化）。
ref_offsets :: proc(data: []u8, pat: []u8) -> [dynamic]u64 {
    out: [dynamic]u64
    n := len(data)
    m := len(pat)
    if m == 0 || m > n {
        return out
    }
    hay := transmute(string)data
    needle := transmute(string)pat
    start := 0
    for start + m <= n {
        rel := strings.index(hay[start:], needle)
        if rel < 0 {
            break
        }
        abs := start + rel
        append(&out, u64(abs))
        start = abs + 1 // +1：保留重叠命中（"aaaa" 匹配 "aa" 有 3 处）
    }
    return out
}

// 断言 got 与参考实现的偏移序列（含顺序与 pat_len）逐条一致。
expect_same_offsets :: proc(t: ^testing.T, what: string, got: []Match_Result, want: []u64, pat_len: uint) {
    testing.expectf(t, len(got) == len(want), "%s: 命中 %d 条，参考实现 %d 条", what, len(got), len(want))
    if len(got) != len(want) {
        return
    }
    for i in 0..<len(got) {
        testing.expectf(t, got[i].offset == want[i], "%s: 第 %d 条偏移 %d，参考 %d", what, i, got[i].offset, want[i])
        testing.expectf(t, uint(got[i].pat_len) == pat_len, "%s: 第 %d 条 pat_len=%d，期望 %d", what, i, got[i].pat_len, pat_len)
    }
}

@(test)
test_matchers_agree_with_reference_search :: proc(t: ^testing.T) {
    p := test_progress()

    // 确定性伪随机数据（LCG，固定种子）：字母表刻意小 → 模式会反复命中；
    // 再手工埋三处实例，覆盖重叠（ababa）、大小写（AAAAA）与数据末尾（abab）。
    rng: u32 = 0x2468ACE1
    data := make([]u8, 4096)
    defer delete(data)
    for i in 0..<len(data) {
        rng = rng * 1664525 + 1013904223
        data[i] = u8('a' + (rng >> 16) % 5) // a..e
    }
    copy(data[100:105], s2b("ababa"))
    copy(data[2000:2005], s2b("AAAAA"))
    copy(data[4092:4096], s2b("abab"))

    // 大小写不敏感时整体小写化的数据（等价于 lower_table，但走标准库路径）。
    // 声明在循环之外 → defer 落在函数体顶层，生存期覆盖整个用例。
    low_data := strings.to_lower(transmute(string)data)
    defer delete(low_data)

    patterns := [][]u8{
        s2b("a"), // 1 字节 → single_match
        s2b("b"),
        s2b("ab"), // 2..16 → bndm_match（委托 naive）
        s2b("aba"),
        s2b("bab"),
        s2b("ababa"),
        s2b("bcbc"),
        s2b("abc"), // 无命中
        s2b("abababababab"), // 12 字节
        s2b("e"), // 末字母，逼近数据尾部
    }
    ci_cases := []bool{false, true}

    for pat in patterns {
        for ci in ci_cases {
            want: [dynamic]u64
            if ci {
                // low_pat 的生存期只覆盖这一次 ref_offsets 调用，因此**手工 delete**：
                // 写在 if 里的 defer 会在 if 块结束时立即释放（Odin defer 是块作用域），
                // 而低写的 ref_data 还要给后面三条比对用 —— 提前 free 会让断言读到
                // 已释放内存（曾表现为"参考实现少报一半命中"）。
                low_pat := strings.to_lower(transmute(string)pat)
                want = ref_offsets(transmute([]u8)low_data, transmute([]u8)low_pat)
                delete(low_pat)
            } else {
                want = ref_offsets(data, pat)
            }
            defer delete(want)

            label := fmt.aprintf("pat=%q ci=%v", transmute(string)pat, ci)
            defer delete(label)

            ctx := Match_Ctx{pattern = pat, case_insensitive = ci}

            // 1) 真实分派路径（select_matcher_for）：这是 worker 实际调用的东西
            dispatch := select_matcher_for(ctx)
            got_dispatch := dispatch(data, ctx, &p)
            defer delete(got_dispatch)
            expect_same_offsets(t, label, got_dispatch, want[:], uint(len(pat)))

            // 2) naive_match：任意长度的兜底实现必须始终正确
            got_naive := naive_match(data, ctx, &p)
            defer delete(got_naive)
            expect_same_offsets(t, label, got_naive, want[:], uint(len(pat)))

            // 3) multi_match：无 extra 时等价于单模式（模式表长度为 1）
            got_multi := multi_match(data, ctx, &p)
            defer delete(got_multi)
            expect_same_offsets(t, label, got_multi, want[:], uint(len(pat)))
        }
    }
}

@(test)
test_multi_match_equals_union_of_single_matches :: proc(t: ^testing.T) {
    // 多模式不是"某种合并"，而是各单模式命中结果的**多重集并集**：
    // 同一偏移被多个模式命中就出现多条（不去重，与分片重叠的重复语义一致）。
    p := test_progress()
    data := s2b("foo test bar testfoo") // test@4 foo@0/17 bar@9
    pats := [][]u8{s2b("test"), s2b("foo"), s2b("bar")}
    ctx := Match_Ctx{pattern = pats[0], extra = [][]u8{pats[1], pats[2]}}

    got := multi_match(data, ctx, &p)
    defer delete(got)

    n := len(data)
    from_multi := make([]int, n)
    defer delete(from_multi)
    from_union := make([]int, n)
    defer delete(from_union)
    for m in got {
        from_multi[m.offset] += 1
    }
    for pat in pats {
        one := naive_match(data, Match_Ctx{pattern = pat, case_insensitive = false}, &p)
        defer delete(one)
        for r in one {
            from_union[r.offset] += 1
        }
    }
    for i in 0..<n {
        testing.expectf(
            t,
            from_multi[i] == from_union[i],
            "偏移 %d: multi_match=%d，单模式并集=%d",
            i,
            from_multi[i],
            from_union[i],
        )
    }

    // 每条命中的 pat_len 必须与"确实在该偏移命中的某个模式"长度相符
    for m in got {
        off := int(m.offset)
        plen := int(m.pat_len)
        matched := false
        for pat in pats {
            if len(pat) == plen && slice.equal(data[off:off + plen], pat) {
                matched = true
            }
        }
        testing.expectf(t, matched, "偏移 %d 的 pat_len=%d 与任何模式都对不上", m.offset, m.pat_len)
    }

    // 表里多出的模式本身无命中 → 结果不受影响（"test" 在 data 里出现两次）
    long_ctx := Match_Ctx{pattern = s2b("test"), extra = [][]u8{s2b("0123456789abcdef")}}
    got_long := multi_match(data, long_ctx, &p)
    defer delete(got_long)
    testing.expect_value(t, len(got_long), 2) // 只剩 "test"@4
}

@(test)
test_matchers_report_scanned_bytes :: proc(t: ^testing.T) {
    // 契约：算法在返回前调用 progress_add(len(data)) —— 进度条的分子是
    // 各分片实际扫过的字节数（因重叠窗口会略大于文件大小，这是既有的。
    // "偶尔超过 100%"的来源）。
    p: Progress
    progress_init(&p, 100, false, true) // enabled=true → scanned 才累加

    r1 := single_match(s2b("aaaaa"), Match_Ctx{pattern = s2b("a")}, &p)
    defer delete(r1)
    testing.expect_value(t, p.scanned, u64(5))

    r2 := naive_match(s2b("aaaaa"), Match_Ctx{pattern = s2b("aa")}, &p)
    defer delete(r2)
    testing.expect_value(t, p.scanned, u64(10))

    r3 := multi_match(s2b("aaaaa"), Match_Ctx{pattern = s2b("a")}, &p)
    defer delete(r3)
    testing.expect_value(t, p.scanned, u64(15))

    r4 := single_match(s2b(""), Match_Ctx{pattern = s2b("a")}, &p)
    defer delete(r4)
    testing.expect_value(t, p.scanned, u64(15)) // 空数据也上报 0

    // 边界：naive_match 遇空模式**提前返回**，因此不上报字节数（既有行为）。
    // 该分支不可达于生产（-f 会忽略空行，且 select_matcher(0) 也不会选到
    // naive 之外的算法），这里只把现状钉住。
    r5 := naive_match(s2b("aaaaa"), Match_Ctx{pattern = s2b("")}, &p)
    defer delete(r5)
    testing.expect_value(t, p.scanned, u64(15))
}
