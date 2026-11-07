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
