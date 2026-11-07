#+dialect hela
package engine

// ============================================================================
// merge_test.odin — 并行归并的等价性测试
//
// 核心断言只有一条：**并行版与串行版逐条相同**，且与分区数无关。
// 这是 ADR 0011 能替换掉旧实现的前提 —— golden 输出、`--dump`、
// `--after/--before` 全部建立在"归并结果确定"之上。
//
// 数据规模刻意超过 MERGE_MIN_PER_PART × p，确保真的走到了多线程路径
// （否则测的只是退化后的串行分支，等于什么都没测）。
// ============================================================================

import "core:testing"
import "xrep:lib"
import "xrep:search"

@(private = "file")
build_merge_fixture :: proc(per_list: int, n_lists: int, seed: u32) -> [][]lib.Match_Result {
    lists := make([][]lib.Match_Result, n_lists)
    rng := seed
    for l in 0..<n_lists {
        row := make([]lib.Match_Result, per_list)
        prev := u64(0)
        for k in 0..<per_list {
            rng = rng * 1664525 + 1013904223
            // 步进 0..6：既有大量相等偏移（步进为 0 时），也有单调递增，
            // 让"平局"和"正常交错"两种情形都被反复走到。
            off := prev + u64(rng % 7)
            row[k] = lib.Match_Result{offset = off, pat_len = u32(l + 1)}
            prev = off
        }
        lists[l] = row
    }
    return lists
}

@(test)
test_merge_parallel_matches_serial :: proc(t: ^testing.T) {
    // 8 个列表 × 6 万条 = 48 万条；p=4 时每分区 12 万条，稳过并行阈值。
    PER_LIST :: 60_000
    LISTS :: 8
    lists := build_merge_fixture(PER_LIST, LISTS, 0xC0FFEE)
    defer {
        for row in lists {
            delete(row)
        }
        delete(lists)
    }

    want := search.merge_ordered_matches(lists)
    defer delete(want)
    testing.expect_value(t, len(want), PER_LIST * LISTS)

    for p in 1..=8 {
        got := merge_ordered_matches_parallel(lists, p)
        defer delete(got)
        testing.expectf(t, len(got) == len(want), "p=%d: 条数 %d != 串行 %d", p, len(got), len(want))
        n := min(len(got), len(want))
        bad := 0
        for i in 0..<n {
            if got[i].offset != want[i].offset || got[i].pat_len != want[i].pat_len {
                bad += 1
                if bad <= 3 {
                    testing.expectf(
                        t,
                        false,
                        "p=%d 第 %d 条: (off=%d,src=%d) != 串行 (off=%d,src=%d)",
                        p,
                        i,
                        got[i].offset,
                        got[i].pat_len,
                        want[i].offset,
                        want[i].pat_len,
                    )
                }
            }
        }
        if bad > 0 {
            testing.expectf(t, false, "p=%d 共有 %d 条不一致", p, bad)
        }
    }
}

@(test)
test_merge_parallel_edge_cases :: proc(t: ^testing.T) {
    // 空输入 / 全空列表：返回 nil，不分配。
    testing.expect_value(t, len(merge_ordered_matches_parallel(nil, 4)), 0)
    empty := [][]lib.Match_Result{{}, {}, {}}
    testing.expect_value(t, len(merge_ordered_matches_parallel(empty, 4)), 0)

    // 单列表：直通，顺序不变。
    one := []lib.Match_Result{{offset = 3}, {offset = 3}, {offset = 9}}
    got := merge_ordered_matches_parallel([][]lib.Match_Result{one}, 4)
    defer delete(got)
    testing.expect_value(t, len(got), 3)
    testing.expect_value(t, got[0].offset, u64(3))
    testing.expect_value(t, got[2].offset, u64(9))

    // 数据量不足阈值 → 走串行分支，结果照旧正确。
    small := [][]lib.Match_Result{{ {offset = 2}, {offset = 8} }, { {offset = 5} }}
    got2 := merge_ordered_matches_parallel(small, 16)
    defer delete(got2)
    testing.expect_value(t, len(got2), 3)
    testing.expect_value(t, got2[0].offset, u64(2))
    testing.expect_value(t, got2[1].offset, u64(5))
    testing.expect_value(t, got2[2].offset, u64(8))

    // 分区数远大于数据量（p 会被夹到 total）也不能崩、不能漏。
    got3 := merge_ordered_matches_parallel(small, 1000)
    defer delete(got3)
    testing.expect_value(t, len(got3), 3)
}
