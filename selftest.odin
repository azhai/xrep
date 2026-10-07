package main

// ============================================================================
// selftest.odin — 内建自测（`xrep --test`）
//
// 职责：进程内冒烟自测，随二进制一起分发，用于部署后快速确认核心工具函数、
//       匹配算法与输出辅助函数可用。**不是**完整的单元测试套件 —— 完整套件见
//       `*_test.odin` 与 `./test.sh`（`odin test` 驱动）。
//
// 覆盖项：slice 工具族、朴素匹配、多模式匹配、多路归并、glob 匹配、
//       JSON 字符串转义、dump 文件名清洗。
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
        s := []Match_Result{{offset = 5}, {offset = 1}, {offset = 3}}
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
        ctx := Match_Ctx{pattern = s2b("ab"), case_insensitive = false}
        data := s2b("xxabxx")
        p: Progress
        progress_init(&p, 0, false, false)
        matches := naive_match(data, ctx, &p)
        defer delete(matches) // 返回值归调用方所有（堆分配，见 matcher.odin）
        if len(matches) != 1 || matches[0].offset != 2 {
            fmt.println("FAIL naive_match")
            ok = false
        } else {
            fmt.println("OK naive_match")
        }
    }
    {
        // 多模式冒烟：主模式 "test" 命中 2 处（@4 / @13），额外模式 "foo" 命中 2 处
        // （@0 / @17），合计 4 条。
        ctx := Match_Ctx{pattern = s2b("test"), extra = [][]u8{s2b("foo")}}
        data := s2b("foo test bar testfoo")
        p: Progress
        progress_init(&p, 0, false, false)
        matches := multi_match(data, ctx, &p)
        defer delete(matches)
        // 语义：结果按"偏移升序、同偏移再按模式表顺序"产出，不做去重。
        pass := len(matches) == 4 && matches[0].offset == 0 && matches[3].offset == 17
        if !pass {
            fmt.println("FAIL multi_match")
            ok = false
        } else {
            fmt.println("OK multi_match")
        }
    }
    {
        // 多路归并冒烟：两个乱序分片合并后必须全局升序且一条不少。
        a := []Match_Result{{offset = 30}, {offset = 40}}
        b := []Match_Result{{offset = 10}, {offset = 50}}
        merged := merge_ordered_matches([][]Match_Result{a, b})
        defer delete(merged)
        pass :=
            len(merged) == 4 &&
            merged[0].offset == 10 &&
            merged[1].offset == 30 &&
            merged[2].offset == 40 &&
            merged[3].offset == 50
        if !pass {
            fmt.println("FAIL merge_ordered_matches")
            ok = false
        } else {
            fmt.println("OK merge_ordered_matches")
        }
    }
    {
        // glob 冒烟：`*` 不跨 `/`，`**` 跨 `/`；无 `/` 的模式只比 basename。
        pass :=
            glob_match("*.bin", "deep/dir/a.bin") &&
            glob_match("src/*", "src/a.c") &&
            !glob_match("src/*", "src/sub/a.c") &&
            glob_match("src/**", "src/sub/a.c") &&
            !glob_match("*.bin", "a.txt")
        if !pass {
            fmt.println("FAIL glob_match")
            ok = false
        } else {
            fmt.println("OK glob_match")
        }
    }
    {
        // JSON 转义冒烟：引号 / 反斜杠 / 换行 / 控制字符。
        esc := json_escape("a\"b\\c\nd\x01")
        defer delete(esc)
        if esc != "a\\\"b\\\\c\\nd\\u0001" {
            fmt.println("FAIL json_escape")
            ok = false
        } else {
            fmt.println("OK json_escape")
        }
    }
    {
        // dump 文件名清洗冒烟：路径分隔符与 Windows 保留字符 → '_'，长度不变。
        safe := sanitize_dump_name("./a:b*c.bin")
        defer delete(safe)
        if string(safe) != "._a_b_c.bin" {
            fmt.println("FAIL sanitize_dump_name")
            ok = false
        } else {
            fmt.println("OK sanitize_dump_name")
        }
    }
    if ok {
        fmt.println("=== All tests passed ===\n")
    } else {
        fmt.println("=== Some tests FAILED ===\n")
    }
    return ok
}
