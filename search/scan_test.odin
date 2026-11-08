package search

// ============================================================================
// scan_test.odin — `index_either` 的逐字节对拍
//
// 为什么必须对拍：`index_either` 是唯一手写 SIMD 的地方，它要回答"第一个满足
// 两者之一的字节在哪"，而 SIMD 版本先按 64 字节块判"块内有没有"，再块内逐字节
// 定位。块与块之间的边界、块内命中位置、尾部不足 64 字节——任何一处差一位，
// 结果就从"正确"变成"漏一条命中且不报错"。用朴素实现做**逐位置**对拍，
// 比肉眼读向量掩码可靠。
//
// 数据形状刻意覆盖三类：
//   1. 完全无命中（最短路径，只走路块扫描）；
//   2. 每个可能的位置单独命中（边界：0、63、64、n-1）；
//   3. 随机字节 + 两个候选的高密度混合（块内多处命中，取最早）。
// ============================================================================

import "core:fmt"
import "core:testing"

// 朴素参照：逐字节，取最早。
naive_either :: proc(s: []u8, a, b: u8) -> int {
    for c, i in s {
        if c == a || c == b {
            return i
        }
    }
    return -1
}

@(test)
test_index_either_matches_naive :: proc(t: ^testing.T) {
    // 1) 无命中
    miss := make([]u8, 300)
    defer delete(miss)
    for i in 0..<len(miss) {
        miss[i] = 0xff
    }
    testing.expect_value(t, index_either(miss, 'a', 'A'), -1)

    // 2) 单点命中，覆盖块边界与尾部
    positions := [?]int{0, 1, 15, 16, 17, 62, 63, 64, 65, 127, 128, 255, 298, 299}
    for at in positions {
        buf := make([]u8, 300)
        for i in 0..<len(buf) {
            buf[i] = '.'
        }
        // 交替放置 a / b，两个候选都要能命中
        buf[at] = at % 2 == 0 ? 'a' : 'A'
        got := index_either(buf, 'a', 'A')
        if got != at {
            fmt.eprintfln("single hit at %d: got %d", at, got)
        }
        testing.expect_value(t, got, at)
        delete(buf)
    }

    // 3) 随机混排：同一份数据，SIMD 与朴素逐位置一致
    size := 4096
    rnd: u32 = 0x1234_5678
    for _ in 0..<64 {
        buf := make([]u8, size)
        for i in 0..<size {
            rnd = rnd * 1664525 + 1013904223
            r := u8(rnd >> 24)
            buf[i] = r < 8 ? 'x' : (r < 16 ? 'X' : r)
        }
        want := naive_either(buf, 'x', 'X')
        got := index_either(buf, 'x', 'X')
        if got != want {
            fmt.eprintfln("random: want %d, got %d", want, got)
        }
        testing.expect_value(t, got, want)
        delete(buf)
    }

    // 4) 两候选相同：走 core 的快路径，结果仍必须一致
    same := []u8{'.', '.', 'q', '.'}
    testing.expect_value(t, index_either(same, 'q', 'q'), 2)
    testing.expect_value(t, index_either(same, 'z', 'z'), -1)

    // 5) 空切片：不能越界
    testing.expect_value(t, index_either([]u8{}, 'a', 'A'), -1)
}

// 穷举「长度 × 命中位置」：长度 0..199 覆盖了 16 字节块的不足一段、整段、
// 多段，以及 64 字节块的三种边界；位置上每一处单独命中一次。
//
// 为什么必须穷举而不是抽样：第三版把块内定位从"逐字节重扫"换成了
// `select + reduce_min`。这个改动最危险的失败模式是**道号偏移算错一位**
// 或**在最后一段不足 16 字节时返回越界下标** —— 抽样很容易刚好避开。
@(test)
test_index_exhaustive_lengths_and_positions :: proc(t: ^testing.T) {
    buf := make([]u8, 200)
    defer delete(buf)

    for n in 0 ..< 200 {
        for at in 0 ..< n {
            // 整段重置（200 字节 × 2 万轮，代价可以忽略；不做"只擦上一个位置"
            // 的微优化，免得测试本身也埋一个下标错误）。
            for i in 0 ..< n {
                buf[i] = '.'
            }
            // 交替放置 a / b 与大写形式：三个分支（折叠路径 / 双向量路径 /
            // 两候选相同）都要被"命中在最前"覆盖到。
            if at % 3 == 0 {
                buf[at] = 'a'
            } else if at % 3 == 1 {
                buf[at] = 'A'
            } else {
                buf[at] = 'a'
            }
            got := index_either(buf[:n], 'a', 'A')
            if got != at {
                fmt.eprintfln("n=%d at=%d: index_either got %d", n, at, got)
            }
            testing.expect_value(t, got, at)

            got_folded := index_folded(buf[:n], 'a')
            if got_folded != at {
                fmt.eprintfln("n=%d at=%d: index_folded got %d", n, at, got_folded)
            }
            testing.expect_value(t, got_folded, at)
        }

        // 同一份长度下"完全没有命中"：确认循环在每一段都不会误报。
        for i in 0 ..< n {
            buf[i] = '.'
        }
        testing.expect_value(t, index_either(buf[:n], 'a', 'A'), -1)
        testing.expect_value(t, index_folded(buf[:n], 'a'), -1)
    }
}

// 非字母的折叠路径：`alt_case` 对非字母返回自身，于是 `a == b` 直接落到
// core 的 `index_byte`；这里只确认那条转接是通的（core 的实现由 core 自己测）。
@(test)
test_index_either_same_candidate_delegates :: proc(t: ^testing.T) {
    buf := []u8{'.', '.', '.', '\n', '.', '.', '\n'}
    testing.expect_value(t, index_either(buf, '\n', '\n'), 3)
    testing.expect_value(t, index_either(buf, '\r', '\r'), -1)
}

