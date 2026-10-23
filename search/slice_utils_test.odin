package search

// ============================================================================
// slice_utils_test.odin — 泛型切片工具单元测试
//
// 覆盖：map / fold / filter / take / drop / sort 的常规路径与**边界**
//       （空切片、单元素、n=0、n=len、n>len、重复键）。
//
// 内存：slice_map / slice_filter 的返回值由调用方拥有（用当前 context.allocator
//       分配），因此这里每个用例都显式 delete —— 否则内存追踪器会把它们报成泄漏。
//       slice_take / slice_drop 只做视图切分，不能（也不该）释放。
//       slice_fold / slice_sort 不分配。
// ============================================================================

import "core:slice"
import "core:testing"
import "xrep:lib"

@(test)
test_slice_map :: proc(t: ^testing.T) {
    sq :: proc(x: int) -> int { return x * x }
    is_even :: proc(x: int) -> bool { return x % 2 == 0 }

    // 常规
    m1 := slice_map(int, int, []int{1, 2, 3}, sq)
    testing.expect(t, slice.equal(m1, []int{1, 4, 9}))
    delete(m1)
    // 边界：空切片 → 空结果（长度 0，非 nil 判定用长度）
    m2 := slice_map(int, int, []int{}, sq)
    testing.expect_value(t, len(m2), 0)
    delete(m2)
    // 边界：单元素
    m3 := slice_map(int, int, []int{3}, sq)
    testing.expect(t, slice.equal(m3, []int{9}))
    delete(m3)
    // 类型转换场景（int → bool）
    m4 := slice_map(int, bool, []int{1, 2, 3, 4}, is_even)
    testing.expect(t, slice.equal(m4, []bool{false, true, false, true}))
    delete(m4)
}

@(test)
test_slice_fold :: proc(t: ^testing.T) {
    add :: proc(acc: int, x: int) -> int { return acc + x }
    testing.expect_value(t, slice_fold(int, int, []int{1, 2, 3}, 0, add), 6)
    // 边界：空切片 → 返回初值本身
    testing.expect_value(t, slice_fold(int, int, []int{}, 42, add), 42)
    // 边界：单元素
    testing.expect_value(t, slice_fold(int, int, []int{7}, 0, add), 7)
    // 非交换运算应保持左到右顺序
    sub :: proc(acc: int, x: int) -> int { return acc - x }
    testing.expect_value(t, slice_fold(int, int, []int{1, 2, 3}, 10, sub), 4)
}

@(test)
test_slice_filter :: proc(t: ^testing.T) {
    even :: proc(x: int) -> bool { return x % 2 == 0 }

    f1 := slice_filter(int, []int{1, 2, 3, 4}, even)
    testing.expect(t, slice.equal(f1, []int{2, 4}))
    delete(f1)
    // 边界：空输入
    f2 := slice_filter(int, []int{}, even)
    testing.expect_value(t, len(f2), 0)
    delete(f2)
    // 边界：全部不匹配
    f3 := slice_filter(int, []int{1, 3, 5}, even)
    testing.expect_value(t, len(f3), 0)
    delete(f3)
    // 边界：全部匹配
    f4 := slice_filter(int, []int{2, 4, 6}, even)
    testing.expect(t, slice.equal(f4, []int{2, 4, 6}))
    delete(f4)
    // 保持相对顺序
    f5 := slice_filter(int, []int{4, 1, 2, 3}, even)
    testing.expect(t, slice.equal(f5, []int{4, 2}))
    delete(f5)
}

@(test)
test_slice_take_drop_boundaries :: proc(t: ^testing.T) {
    s := []int{10, 20, 30, 40}
    // 常规
    testing.expect(t, slice.equal(slice_take(int, s, 2), []int{10, 20}))
    testing.expect(t, slice.equal(slice_drop(int, s, 2), []int{30, 40}))
    // 边界：n = 0 → take 给空、drop 给全量
    testing.expect_value(t, len(slice_take(int, s, 0)), 0)
    testing.expect(t, slice.equal(slice_drop(int, s, 0), []int{10, 20, 30, 40}))
    // 边界：n = len → take 返回全量、drop 返回空
    testing.expect(t, slice.equal(slice_take(int, s, 4), []int{10, 20, 30, 40}))
    testing.expect_value(t, len(slice_drop(int, s, 4)), 0)
    // 边界：n > len → 与 n = len 同语义（take 全量视图、drop 空）
    testing.expect(t, slice.equal(slice_take(int, s, 99), []int{10, 20, 30, 40}))
    testing.expect_value(t, len(slice_drop(int, s, 99)), 0)
    // 边界：空切片上的任意 n
    testing.expect_value(t, len(slice_take(int, []int{}, 3)), 0)
    testing.expect_value(t, len(slice_drop(int, []int{}, 3)), 0)
    // take 是视图：修改结果会影响原切片
    v := slice_take(int, s, 1)
    v[0] = 99
    testing.expect_value(t, s[0], 99)
}

@(test)
test_slice_sort :: proc(t: ^testing.T) {
    less :: proc(a, b: int) -> bool { return a < b }
    // 逆序输入
    s := []int{5, 1, 3}
    slice_sort(int, s, less)
    testing.expect(t, slice.equal(s, []int{1, 3, 5}))
    // 边界：已有序
    a := []int{1, 2, 3}
    slice_sort(int, a, less)
    testing.expect(t, slice.equal(a, []int{1, 2, 3}))
    // 边界：空 / 单元素
    e := []int{}
    slice_sort(int, e, less)
    testing.expect_value(t, len(e), 0)
    one := []int{7}
    slice_sort(int, one, less)
    testing.expect(t, slice.equal(one, []int{7}))
    // 重复键：不丢元素
    dup := []int{2, 2, 1, 2}
    slice_sort(int, dup, less)
    testing.expect(t, slice.equal(dup, []int{1, 2, 2, 2}))
    // 结构体场景（Match_Result 按 offset 排序）
    mr_less :: proc(x, y: lib.Match_Result) -> bool { return x.offset < y.offset }
    ms := []lib.Match_Result{{offset = 9}, {offset = 0}, {offset = 4}, {offset = 4}}
    slice_sort(lib.Match_Result, ms, mr_less)
    testing.expect_value(t, ms[0].offset, u64(0))
    testing.expect_value(t, ms[1].offset, u64(4))
    testing.expect_value(t, ms[2].offset, u64(4))
    testing.expect_value(t, ms[3].offset, u64(9))
}
