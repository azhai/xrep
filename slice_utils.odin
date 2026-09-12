package main

// ============================================================================
// slice_utils.odin — 泛型切片工具
//
// 职责：对切片做 map / fold / filter / take / drop / sort 的函数式封装，
//       统一为本包其余模块可用的形式（Odin 泛型以 $T / $U 显式实例化类型）。
//
// 依赖：core:slice（仅 slice_sort 转发）。
// 注意：map / filter 返回的切片由当前 context.allocator 分配，调用方负责释放；
//       take / drop 仅做视图切分，不拷贝底层数组。
// ============================================================================

import "core:slice"

slice_map :: proc($T: typeid, $U: typeid, s: []T, f: proc(item: T) -> U) -> []U {
    res := make([dynamic]U, 0, len(s))
    for item in s {
        append(&res, f(item))
    }
    return res[:]
}

slice_fold :: proc($T: typeid, $Acc: typeid, s: []T, init: Acc, f: proc(acc: Acc, item: T) -> Acc) -> Acc {
    acc := init
    for item in s {
        acc = f(acc, item)
    }
    return acc
}

slice_filter :: proc($T: typeid, s: []T, pred: proc(item: T) -> bool) -> []T {
    res := make([dynamic]T, 0, len(s))
    for item in s {
        if pred(item) {
            append(&res, item)
        }
    }
    return res[:]
}

// 取前 n 个元素；n 越界（>= 长度）时返回原切片本身（视图，不拷贝）。
slice_take :: proc($T: typeid, s: []T, n: uint) -> []T {
    if n >= uint(len(s)) {
        return s
    }
    return s[:n]
}

// 丢弃前 n 个元素；n 越界（>= 长度）时返回空切片（不同于 take 的"返回全量"语义）。
slice_drop :: proc($T: typeid, s: []T, n: uint) -> []T {
    if n >= uint(len(s)) {
        return []T{}
    }
    return s[n:]
}

// 按 less 全序排序（转发 core:slice.sort_by，原地排序）。
slice_sort :: proc($T: typeid, s: []T, less: proc(a: T, b: T) -> bool) {
    slice.sort_by(s, less)
}
