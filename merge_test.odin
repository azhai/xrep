package main

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

@(test)
test_merge_ordered_matches_empty :: proc(t: ^testing.T) {
    // 边界：没有任何列表
    r0 := merge_ordered_matches([][]Match_Result{})
    testing.expect_value(t, len(r0), 0)
    delete(r0)
    // 边界：列表数 >0 但全部为空
    r1 := merge_ordered_matches([][]Match_Result{ {}, {}, {} })
    testing.expect_value(t, len(r1), 0)
    delete(r1)
    // 边界：nil 列表（与空列表等价）
    r2 := merge_ordered_matches([][]Match_Result{ nil, nil })
    testing.expect_value(t, len(r2), 0)
    delete(r2)
}

@(test)
test_merge_ordered_matches_single_list :: proc(t: ^testing.T) {
    one := []Match_Result{{offset = 1}, {offset = 5}, {offset = 9}}
    r := merge_ordered_matches([][]Match_Result{ one })
    testing.expect_value(t, len(r), 3)
    testing.expect_value(t, r[0].offset, u64(1))
    testing.expect_value(t, r[1].offset, u64(5))
    testing.expect_value(t, r[2].offset, u64(9))
    delete(r)
}

@(test)
test_merge_ordered_matches_interleaved :: proc(t: ^testing.T) {
    // 三路交错：验证全局升序（各输入自身已升序）
    a := []Match_Result{{offset = 0}, {offset = 7}, {offset = 100}}
    b := []Match_Result{{offset = 1}, {offset = 8}}
    c := []Match_Result{{offset = 3}, {offset = 9}, {offset = 101}, {offset = 102}}
    r := merge_ordered_matches([][]Match_Result{ a, b, c })
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
    a := []Match_Result{{offset = 2}}
    empty: []Match_Result
    b := []Match_Result{{offset = 4}}
    r := merge_ordered_matches([][]Match_Result{ a, empty, b })
    testing.expect_value(t, len(r), 2)
    testing.expect_value(t, r[0].offset, u64(2))
    testing.expect_value(t, r[1].offset, u64(4))
    delete(r)

    // 重复偏移必须全部保留（分片重叠会产生重复命中，由调用方决定是否处理）
    d1 := []Match_Result{{offset = 5}, {offset = 5}}
    d2 := []Match_Result{{offset = 5}}
    rd := merge_ordered_matches([][]Match_Result{ d1, d2 })
    testing.expect_value(t, len(rd), 3)
    for m in rd {
        testing.expect_value(t, m.offset, u64(5))
    }
    delete(rd)

    // 极端：某一列表整体小于另一列表
    big := []Match_Result{{offset = 100}, {offset = 200}, {offset = 300}}
    small := []Match_Result{{offset = 1}}
    rs := merge_ordered_matches([][]Match_Result{ big, small })
    testing.expect_value(t, len(rs), 4)
    testing.expect_value(t, rs[0].offset, u64(1))
    testing.expect_value(t, rs[3].offset, u64(300))
    delete(rs)
}
