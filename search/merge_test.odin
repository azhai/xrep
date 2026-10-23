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
