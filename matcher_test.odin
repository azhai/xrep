package main

// ============================================================================
// matcher_test.odin — 匹配算法层单元测试
//
// 覆盖：
//   * select_matcher 的长度区间边界（1 / 2 / 16 / 17 / 64 / 65 / 0）与空表回退
//   * single_match / naive_match 的正确性（重叠命中、大小写、空数据、模式超长）
//   * bndm_match 与 naive_match 的委托一致性
//   * 三种算法在同一输入上的结果一致性
//
// 内存约定：匹配算法**不再**改写 context.allocator，改为把 arena 分配器显式
//           传给 make（见 matcher.odin 文件头）。因此用例无需再保存/恢复分配器。
// 初始化： alg_table 是编译期常量；lower_table 由 `@(init)` 在启动时填充。
//           两者都不需要用例手动初始化（main 与 `odin test` 启动路径一致）。
// ============================================================================

import "core:mem"
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
    arena: mem.Arena
    arena_make(&arena, mem.Megabyte)
    defer arena_free(&arena)
    p := test_progress()

    // 常规：单字节模式在数据中多次出现
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 3)
        testing.expect_value(t, got[0].offset, u64(1))
        testing.expect_value(t, got[1].offset, u64(3))
        testing.expect_value(t, got[2].offset, u64(5))
    }
    // 边界：无命中
    {
        ctx := Match_Ctx{pattern = s2b("z"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 边界：空数据
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := single_match(s2b(""), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 大小写不敏感：大写模式也能命中
    {
        ctx := Match_Ctx{pattern = s2b("B"), case_insensitive = true}
        got := single_match(s2b("banana"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
    // 大小写敏感：大写模式不应命中
    {
        ctx := Match_Ctx{pattern = s2b("B"), case_insensitive = false}
        got := single_match(s2b("banana"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 非 ASCII 字节必须按原始字节匹配（不被 lower 表改写）
    {
        data := []u8{0xC3, 0x80, 0xC3, 0x80} // UTF-8 "ÀÀ"
        ctx := Match_Ctx{pattern = []u8{0xC3}, case_insensitive = true}
        got := single_match(data, ctx, &arena, &p)
        testing.expect_value(t, len(got), 2)
    }
}

@(test)
test_naive_match :: proc(t: ^testing.T) {
    arena: mem.Arena
    arena_make(&arena, mem.Megabyte)
    defer arena_free(&arena)
    p := test_progress()

    // 常规：单次命中
    {
        ctx := Match_Ctx{pattern = s2b("ab"), case_insensitive = false}
        got := naive_match(s2b("xxabxx"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(2))
    }
    // 重叠命中：模式 "aa" 在 "aaaa" 中产生 3 个位置（0/1/2）
    {
        ctx := Match_Ctx{pattern = s2b("aa"), case_insensitive = false}
        got := naive_match(s2b("aaaa"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 3)
        testing.expect_value(t, got[0].offset, u64(0))
        testing.expect_value(t, got[1].offset, u64(1))
        testing.expect_value(t, got[2].offset, u64(2))
    }
    // 边界：空模式 → 空结果（不得死循环或越界）
    {
        ctx := Match_Ctx{pattern = s2b(""), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 边界：模式比数据长 → 空结果
    {
        ctx := Match_Ctx{pattern = s2b("abcdef"), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 边界：模式与数据等长 → 命中一次（偏移 0）
    {
        ctx := Match_Ctx{pattern = s2b("abc"), case_insensitive = false}
        got := naive_match(s2b("abc"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
    // 边界：空数据
    {
        ctx := Match_Ctx{pattern = s2b("a"), case_insensitive = false}
        got := naive_match(s2b(""), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 大小写不敏感：混合大小写互相命中
    {
        ctx := Match_Ctx{pattern = s2b("AbC"), case_insensitive = true}
        got := naive_match(s2b("xxaBcxx"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(2))
    }
    // 大小写敏感：混合大小写不应命中
    {
        ctx := Match_Ctx{pattern = s2b("AbC"), case_insensitive = false}
        got := naive_match(s2b("xxaBcxx"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 0)
    }
    // 边界：命中出现在数据末尾
    {
        ctx := Match_Ctx{pattern = s2b("test"), case_insensitive = false}
        got := naive_match(s2b("aaaa test"), ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(5))
    }
    // 含 NUL 的二进制数据必须可匹配（不能按 C 字符串处理）
    {
        data := []u8{0x00, 0x01, 0x41, 0x00, 0x41}
        ctx := Match_Ctx{pattern = []u8{0x00, 0x41}, case_insensitive = false}
        got := naive_match(data, ctx, &arena, &p)
        // 仅偏移 3 处对齐（偏移 0 处第二字节为 0x01，不匹配）
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(3))
    }
    // 边界：命中位于模式长度不足的尾部 → 不产生命中（上界保护）
    {
        data := []u8{0x00, 0x41, 0x00}
        ctx := Match_Ctx{pattern = []u8{0x00, 0x41}, case_insensitive = false}
        got := naive_match(data, ctx, &arena, &p)
        testing.expect_value(t, len(got), 1)
        testing.expect_value(t, got[0].offset, u64(0))
    }
}

@(test)
test_bndm_matches_naive :: proc(t: ^testing.T) {
    arena: mem.Arena
    arena_make(&arena, mem.Megabyte)
    defer arena_free(&arena)
    p := test_progress()

    // bndm_match 当前委托 naive_match，两者结果必须逐项一致（含偏移顺序）。
    data := s2b("abcabcabXabc")
    ctx := Match_Ctx{pattern = s2b("abc"), case_insensitive = false}
    a := bndm_match(data, ctx, &arena, &p)
    testing.expect_value(t, len(a), 3)
    b := naive_match(data, ctx, &arena, &p)
    testing.expect_value(t, len(b), 3)
    for i in 0..<len(a) {
        testing.expect_value(t, a[i].offset, b[i].offset)
    }
}

@(test)
test_matchers_agree_across_algorithms :: proc(t: ^testing.T) {
    arena: mem.Arena
    arena_make(&arena, mem.Megabyte)
    defer arena_free(&arena)
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
        s1 := single_match(data, ctx, &arena, &p)
        n1 := naive_match(data, ctx, &arena, &p)
        testing.expect_value(t, len(s1), len(n1))
        for i in 0..<len(s1) {
            testing.expect_value(t, s1[i].offset, n1[i].offset)
        }
    }
    // 4 字节模式：bndm（委托 naive）与 naive 必须一致，且命中数符合埋点
    {
        ctx := Match_Ctx{pattern = s2b("aaaa"), case_insensitive = false}
        b1 := bndm_match(data, ctx, &arena, &p)
        n1 := naive_match(data, ctx, &arena, &p)
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
