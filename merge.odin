package main

// ============================================================================
// merge.odin — 多路有序归并
//
// 职责：把 N 个"各自已按 offset 升序"的命中列表合并成一个全局升序列表。
//       各 worker 只负责自己分片内的顺序，跨分片的全局顺序由本模块恢复。
//
// 依赖：common.odin（Match_Result）。
// 复杂度：O(总命中数 × 列表数)，列表数为线程数（个位数），可接受；
//         k 路堆优化收益有限，故不引入（遵循"最小可用实现"）。
// ============================================================================

merge_ordered_matches :: proc(lists: [][]Match_Result) -> []Match_Result {
    total := 0
    for l in 0..<len(lists) {
        total += len(lists[l])
    }
    out := make([dynamic]Match_Result, 0, total)
    // ptrs 记录每个列表的读取游标；non_empty 剪枝已耗尽的列表。
    // 这两个是**函数内临时缓冲**，用完必须释放（长度 = 列表数 = 线程数，
    // 进程内每次归并都会分配一次，不释放会持续累积）。
    // 返回的 out 由调用方拥有（scan_file 负责 delete），此处不要 defer 释放它。
    ptrs := make([]uint, len(lists))
    non_empty := make([]bool, len(lists))
    defer delete(ptrs)
    defer delete(non_empty)
    for i in 0..<len(lists) {
        non_empty[i] = len(lists[i]) > 0
    }
    for {
        // 每轮在"未耗尽"的列表中挑 offset 最小者，取走其当前元素。
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
