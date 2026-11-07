package search

// ============================================================================
// merge_test.odin — 多路归并单元测试
//
// 覆盖：无序输入的有序化、空列表集合、包含空列表、重复偏移、单列表直通、
//       以及"输出长度 = 输入总长度（不去重）"这一关键不变量。
//
// 内存：merge_ordered_matches 返回的切片由调用方拥有（scan_file 结束时会 delete），
//       因此每个用例断言完必须 delete —— 否则内存追踪器会把归并输出报成泄漏。
// ============================================================================

import "core:testing"
import "xrep:lib"

@(test)
test_merge_ordered_matches_empty :: proc(t: ^testing.T) {
    // 边界：没有任何列表
    r0 := merge_ordered_matches([][]lib.Match_Result{})
    testing.expect_value(t, len(r0), 0)
    delete(r0)
    // 边界：列表数 >0 但全部为空
    r1 := merge_ordered_matches([][]lib.Match_Result{ {}, {}, {} })
    testing.expect_value(t, len(r1), 0)
    delete(r1)
    // 边界：nil 列表（与空列表等价）
    r2 := merge_ordered_matches([][]lib.Match_Result{ nil, nil })
    testing.expect_value(t, len(r2), 0)
    delete(r2)
}

@(test)
test_merge_ordered_matches_single_list :: proc(t: ^testing.T) {
    one := []lib.Match_Result{{offset = 1}, {offset = 5}, {offset = 9}}
    r := merge_ordered_matches([][]lib.Match_Result{ one })
    testing.expect_value(t, len(r), 3)
    testing.expect_value(t, r[0].offset, u64(1))
    testing.expect_value(t, r[1].offset, u64(5))
    testing.expect_value(t, r[2].offset, u64(9))
    delete(r)
}

@(test)
test_merge_ordered_matches_interleaved :: proc(t: ^testing.T) {
    // 三路交错：验证全局升序（各输入自身已升序）
    a := []lib.Match_Result{{offset = 0}, {offset = 7}, {offset = 100}}
    b := []lib.Match_Result{{offset = 1}, {offset = 8}}
    c := []lib.Match_Result{{offset = 3}, {offset = 9}, {offset = 101}, {offset = 102}}
    r := merge_ordered_matches([][]lib.Match_Result{ a, b, c })
    testing.expect_value(t, len(r), 9)
    want := []u64{0, 1, 3, 7, 8, 9, 100, 101, 102}
    for i in 0..<len(want) {
        testing.expect_value(t, r[i].offset, want[i])
    }
    // 不变量：总长度 = 各输入长度之和（不去重、不丢失）
    testing.expect_value(t, len(r), len(a) + len(b) + len(c))
    delete(r)
}

@(test)
test_merge_ordered_matches_empty_entries_and_duplicates :: proc(t: ^testing.T) {
    // 混合空列表与非空列表
    a := []lib.Match_Result{{offset = 2}}
    empty: []lib.Match_Result
    b := []lib.Match_Result{{offset = 4}}
    r := merge_ordered_matches([][]lib.Match_Result{ a, empty, b })
    testing.expect_value(t, len(r), 2)
    testing.expect_value(t, r[0].offset, u64(2))
    testing.expect_value(t, r[1].offset, u64(4))
    delete(r)

    // 重复偏移必须全部保留（分片重叠会产生重复命中，由调用方决定是否处理）
    d1 := []lib.Match_Result{{offset = 5}, {offset = 5}}
    d2 := []lib.Match_Result{{offset = 5}}
    rd := merge_ordered_matches([][]lib.Match_Result{ d1, d2 })
    testing.expect_value(t, len(rd), 3)
    for m in rd {
        testing.expect_value(t, m.offset, u64(5))
    }
    delete(rd)

    // 极端：某一列表整体小于另一列表
    big := []lib.Match_Result{{offset = 100}, {offset = 200}, {offset = 300}}
    small := []lib.Match_Result{{offset = 1}}
    rs := merge_ordered_matches([][]lib.Match_Result{ big, small })
    testing.expect_value(t, len(rs), 4)
    testing.expect_value(t, rs[0].offset, u64(1))
    testing.expect_value(t, rs[3].offset, u64(300))
    delete(rs)
}

@(test)
test_merge_ordered_matches_many_lists_multiset :: proc(t: ^testing.T) {
    // 多路（= 线程数）压力：8 个分片各含若干命中，要求
    //   1. 输出全局非降序；
    //   2. 输出与输入是同一个**多重集**（既不丢也不多）。
    // 用确定性伪随机构造各分片（偏移刻意大量重叠，模拟分片重叠窗口的重复命中）。
    LISTS :: 8
    PER_LIST :: 60
    OFFSET_MAX :: 200

    rng: u32 = 0x9E3779B9
    lists := make([][]lib.Match_Result, LISTS)
    defer delete(lists)
    expected := make([]int, OFFSET_MAX)
    defer delete(expected)
    total := 0
    for l in 0..<LISTS {
        // 每个分片内的偏移按构造即升序（归并的前提）
        row := make([dynamic]lib.Match_Result, 0, PER_LIST)
        prev := u64(0)
        for _ in 0..<PER_LIST {
            rng = rng * 1664525 + 1013904223
            off := u64((rng >> 16) % OFFSET_MAX)
            if off < prev {
                off = prev // 保证本分片升序
            }
            append(&row, lib.Match_Result{offset = off, pat_len = 4})
            expected[off] += 1
            prev = off
        }
        lists[l] = row[:]
        total += len(lists[l])
    }

    r := merge_ordered_matches(lists)
    defer delete(r)

    testing.expect_value(t, len(r), total)
    for i in 1..<len(r) {
        testing.expectf(t, r[i - 1].offset <= r[i].offset, "第 %d 条(%d) > 第 %d 条(%d)", i - 1, r[i - 1].offset, i, r[i].offset)
    }
    got := make([]int, OFFSET_MAX)
    defer delete(got)
    for m in r {
        testing.expectf(t, m.offset < u64(OFFSET_MAX), "偏移 %d 超出构造范围", m.offset)
        if m.offset < u64(OFFSET_MAX) {
            got[m.offset] += 1
        }
    }
    for i in 0..<OFFSET_MAX {
        testing.expectf(t, got[i] == expected[i], "偏移 %d: 输出 %d 次，输入 %d 次", i, got[i], expected[i])
    }

    // 释放各分片（它们由当前分配器分配，归并只读取不接管所有权）
    for lst in lists {
        delete(lst)
    }
}

@(test)
test_merge_ordered_matches_all_identical_offsets :: proc(t: ^testing.T) {
    // 全部命中偏移相同时，长度必须守恒（相等偏移之间的先后由实现决定，
    // 但一条都不能少 —— 这正是"重叠窗口重复命中"的极限形态）。
    same := []lib.Match_Result{{offset = 7}, {offset = 7}, {offset = 7}}
    r := merge_ordered_matches([][]lib.Match_Result{ same, same, same })
    testing.expect_value(t, len(r), 9)
    for m in r {
        testing.expect_value(t, m.offset, u64(7))
    }
    delete(r)
}

// ---------------------------------------------------------------------------
// 以下用例针对 ADR 0011 的新实现（最小堆 + rank 精确切分）。
//
// 核心是一个**独立参照实现**：把旧的"线性扫最小游标"逐字复刻一份放在测试里。
// 新实现必须与它在每一条上都相同 —— 不只是"有序"和"条数守恒"，还包括
// **相等偏移之间的先后**（按下标小的列表先出）。只断言有序性的话，
// 平局顺序错了也测不出来，而那正是并行切分最容易出错的地方。
// ---------------------------------------------------------------------------

// 旧算法的逐字复刻（严格 `<`，从下标 0 往右找最小者 → 平局时下标小的先出）。
@(private = "file")
merge_linear_reference :: proc(lists: [][]lib.Match_Result) -> []lib.Match_Result {
    total := 0
    for l in 0..<len(lists) {
        total += len(lists[l])
    }
    out := make([dynamic]lib.Match_Result, 0, total)
    ptrs := make([]uint, len(lists))
    non_empty := make([]bool, len(lists))
    defer delete(ptrs)
    defer delete(non_empty)
    for i in 0..<len(lists) {
        non_empty[i] = len(lists[i]) > 0
    }
    for {
        min_idx := -1
        min_off := u64(0xFFFFFFFFFFFFFFFF)
        for i in 0..<len(lists) {
            if non_empty[i] && lists[i][ptrs[i]].offset < min_off {
                min_off = lists[i][ptrs[i]].offset
                min_idx = i
            }
        }
        if min_idx == -1 {
            break
        }
        append(&out, lists[min_idx][ptrs[min_idx]])
        ptrs[min_idx] += 1
        if ptrs[min_idx] >= uint(len(lists[min_idx])) {
            non_empty[min_idx] = false
        }
    }
    return out[:]
}

@(private = "file")
lcg_next :: proc(s: ^u32) -> u32 {
    s^ = s^ * 1664525 + 1013904223
    return s^
}

@(test)
test_merge_matches_linear_reference :: proc(t: ^testing.T) {
    // 偏移值域刻意压到 0..15：制造大量相等偏移，把平局规则逼到极限。
    // pat_len 按列表取不同常量，这样"跨列表换序"即使偏移相同也能被发现。
    ROUNDS :: 40
    rng: u32 = 0x5EED1234
    for round in 0..<ROUNDS {
        n_lists := int(lcg_next(&rng) % 12) + 1
        lists := make([][]lib.Match_Result, n_lists)
        defer delete(lists)
        for l in 0..<n_lists {
            n := int(lcg_next(&rng) % 41)
            row := make([]lib.Match_Result, n)
            prev := u64(0)
            for k in 0..<n {
                off := u64(lcg_next(&rng) % 16)
                if off < prev {
                    off = prev // 各分片自身必须升序（归并前提）
                }
                row[k] = lib.Match_Result{offset = off, pat_len = u32(l + 1)}
                prev = off
            }
            lists[l] = row
        }

        got := merge_ordered_matches(lists)
        want := merge_linear_reference(lists)
        testing.expectf(t, len(got) == len(want), "第 %d 轮: 条数 %d != 参照 %d", round, len(got), len(want))
        n := min(len(got), len(want))
        bad := 0
        for i in 0..<n {
            if got[i].offset != want[i].offset || got[i].pat_len != want[i].pat_len {
                bad += 1
                if bad <= 3 {
                    testing.expectf(
                        t,
                        false,
                        "第 %d 轮 第 %d 条: 堆得 (off=%d,src=%d)，参照 (off=%d,src=%d)",
                        round,
                        i,
                        got[i].offset,
                        got[i].pat_len,
                        want[i].offset,
                        want[i].pat_len,
                    )
                }
            }
        }
        delete(got)
        delete(want)
        for row in lists {
            delete(row)
        }
    }
}

@(test)
test_merge_split_starts_cover_each_list_exactly :: proc(t: ^testing.T) {
    // 切分的不变量（对任意分区数）：
    //   1. 第 0 个分区从 0 起，第 p 个分区到 len 止 —— 没有条目被漏掉；
    //   2. 同一列表在各分区上的起点非降 —— 区间不重叠、不倒退；
    //   3. 各列表游标之和 == total*part/p —— 分区 rank 精确（输出位置由此推出，
    //      所以这条不成立就等于并行版本会写错位置）。
    LISTS :: 7
    lens := [LISTS]int{0, 1, 5, 13, 40, 3, 0}
    lists := make([][]lib.Match_Result, LISTS)
    defer {
        for row in lists {
            delete(row)
        }
        delete(lists)
    }
    total := 0
    for l in 0..<LISTS {
        row := make([]lib.Match_Result, lens[l])
        for k in 0..<lens[l] {
            row[k] = lib.Match_Result{offset = u64(k * 3)}
        }
        lists[l] = row
        total += lens[l]
    }

    for p in 1..=16 {
        starts := make([]int, (p + 1) * LISTS)
        merge_split_starts(lists, p, total, starts)
        for i in 0..<LISTS {
            testing.expectf(t, starts[i] == 0, "p=%d 列表 %d: 起点 %d != 0", p, i, starts[i])
            testing.expectf(t, starts[p * LISTS + i] == lens[i], "p=%d 列表 %d: 终点 %d != %d", p, i, starts[p * LISTS + i], lens[i])
            for part in 0..<p {
                a := starts[part * LISTS + i]
                b := starts[(part + 1) * LISTS + i]
                testing.expectf(t, b >= a, "p=%d 列表 %d 分区 %d: 起点倒退 %d -> %d", p, i, part, a, b)
            }
        }
        for part in 0..<p + 1 {
            s := 0
            for i in 0..<LISTS {
                s += starts[part * LISTS + i]
            }
            testing.expectf(t, s == total * part / p, "p=%d 分区 %d: 游标和 %d != rank %d", p, part, s, total * part / p)
        }
        delete(starts)
    }
}

@(test)
test_merge_split_breaks_ties_by_list_index :: proc(t: ^testing.T) {
    // 平局规则的可判定例子：两个列表的偏移完全相同（都为 5）。
    // 稳定序是"[列表 0 的全部 5] 再接 [列表 1 的全部 5]"，
    // 因此 rank=2 的切分必须把列表 0 读空、列表 1 一条不取。
    a := []lib.Match_Result{{offset = 5}, {offset = 5}}
    b := []lib.Match_Result{{offset = 5}, {offset = 5}}
    lists := [][]lib.Match_Result{a, b}
    starts := make([]int, 3 * 2)
    defer delete(starts)
    merge_split_starts(lists, 2, 4, starts)
    testing.expect_value(t, starts[0 * 2 + 0], 0)
    testing.expect_value(t, starts[0 * 2 + 1], 0)
    testing.expect_value(t, starts[1 * 2 + 0], 2) // 列表 0 的两条都归左半
    testing.expect_value(t, starts[1 * 2 + 1], 0) // 列表 1 一条都不归左半
    testing.expect_value(t, starts[2 * 2 + 0], 2)
    testing.expect_value(t, starts[2 * 2 + 1], 2)
}
