package main

// ============================================================================
// selftest.odin — 内建自测（`xrep --test`）
//
// 职责：进程内冒烟自测，随二进制一起分发，用于部署后快速确认核心工具函数与
//       朴素匹配可用。**不是**完整的单元测试套件 —— 完整套件见 `*_test.odin`
//       与 `./test.sh`（`odin test` 驱动）。
//
// 依赖：core:fmt、core:mem、core:slice。
// 注意：文件名刻意不采用 `_test.odin` 后缀，以免被测试构建模式特殊处理。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:slice"

// 顺序执行各项自检，全部通过返回 true。
// 不使用断言中断：逐项打印 OK/FAIL，便于一次性看到哪些项失败。
run_tests :: proc() -> bool {
    ok := true
    fmt.println("=== Running Unit Tests ===")
    {
        s := []int{1, 2, 3}
        f :: proc(x: int) -> int { return x * x }
        res := slice_map(int, int, s, f)
        if !slice.equal(res, []int{1, 4, 9}) {
            fmt.println("FAIL slice_map")
            ok = false
        } else {
            fmt.println("OK slice_map")
        }
    }
    {
        s := []int{1, 2, 3}
        f :: proc(acc: int, x: int) -> int { return acc + x }
        res := slice_fold(int, int, s, 0, f)
        if res != 6 {
            fmt.println("FAIL slice_fold")
            ok = false
        } else {
            fmt.println("OK slice_fold")
        }
    }
    {
        s := []int{1, 2, 3, 4}
        pred :: proc(x: int) -> bool { return x % 2 == 0 }
        res := slice_filter(int, s, pred)
        if !slice.equal(res, []int{2, 4}) {
            fmt.println("FAIL slice_filter")
            ok = false
        } else {
            fmt.println("OK slice_filter")
        }
    }
    {
        s := []int{10, 20, 30, 40}
        t := slice_take(int, s, 2)
        d := slice_drop(int, s, 2)
        if !slice.equal(t, []int{10, 20}) || !slice.equal(d, []int{30, 40}) {
            fmt.println("FAIL take/drop")
            ok = false
        } else {
            fmt.println("OK take/drop")
        }
    }
    {
        s := []Match_Result{{5}, {1}, {3}}
        less :: proc(a, b: Match_Result) -> bool { return a.offset < b.offset }
        slice_sort(Match_Result, s, less)
        if s[0].offset != 1 || s[1].offset != 3 || s[2].offset != 5 {
            fmt.println("FAIL slice_sort")
            ok = false
        } else {
            fmt.println("OK slice_sort")
        }
    }
    {
        // 朴素匹配冒烟：在 "xxabxx" 中命中 "ab"（偏移 2），且进度条关闭。
        arena: mem.Arena
        arena_make(&arena, mem.Megabyte)
        defer arena_free(&arena)
        ctx := Match_Ctx{pattern = s2b("ab"), case_insensitive = false}
        data := s2b("xxabxx")
        p: Progress
        progress_init(&p, 0, false, false)
        matches := naive_match(data, ctx, &arena, &p)
        if len(matches) != 1 || matches[0].offset != 2 {
            fmt.println("FAIL naive_match")
            ok = false
        } else {
            fmt.println("OK naive_match")
        }
    }
    if ok {
        fmt.println("=== All tests passed ===\n")
    } else {
        fmt.println("=== Some tests FAILED ===\n")
    }
    return ok
}
