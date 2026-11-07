package search

// ============================================================================
// scan.odin — 首字节预筛的"两个候选、一趟走完"
//
// 为什么单独一个文件：这里是整个匹配层唯一真正吃内存带宽的地方，改动它必须能被
// 单测和基准直接盯住（`scan_test.odin` 用朴素实现做逐字节对拍）。
//
// 背景（实测，不是推断）：
//   * `bytes.index_byte` 已经是 SIMD 的（core 里每轮 64 字节、4 个 128 位向量）。
//     所以"上 SIMD"不是这里的优化空间 —— 空间在**趟数**。
//   * 大小写不敏感搜索需要两个候选字节（`t` 与 `T`）。旧写法是
//     `min(index_byte(d,'t'), index_byte(d,'T'))`，即**两趟完整扫描**。
//     稀疏命中（最常见的情况）时两趟都要扫到结尾，于是内存流量翻倍：
//     256 MiB 全 0xFF 上实测 30.3 GB/s vs 单趟 62.5 GB/s。
//   * 一趟里同时比两个候选，代价只是每 16 字节多一条向量比较（ALU 远未饱和），
//     换来的是把流量砍一半。
// ============================================================================

import "base:intrinsics"

import "core:bytes"
import "core:simd"

// 返回第一个满足 s[i] == a 或 s[i] == b 的 i，没有则 -1。
//
// 形状与 core:bytes 的 128 位路径一致：每轮 64 字节 = 4 个 16 字节向量。
// 命中之后再在块内逐字节定位 —— 块命中要到"有人要这个结果"时才发生，
// 用向量掩码提取下标（select + reduce_min）在这里不划算：调用方拿到下标后
// 通常立刻进入"密集消费"循环，块内扫描的 64 字节几乎总在第 0..8 字节就命中。
index_either :: proc "contextless" (s: []u8, a, b: u8) -> int {
	// 两个候选相同（大小写不敏感的字母以外，或大小写敏感路径）时没有第二趟可省，
	// 直接交给 core 的实现，避免在同一份代码里维护两条等价路径。
	if a == b {
		return bytes.index_byte(s, a)
	}

	n := len(s)
	va := simd.u8x16(a)
	vb := simd.u8x16(b)
	hits: [4]u8
	i := 0
	for ; i + 64 <= n; i += 64 {
		#unroll for j in 0..<4 {
			v := intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i + j * 16:]))
			hits[j] = simd.reduce_or(simd.lanes_eq(v, va)) | simd.reduce_or(simd.lanes_eq(v, vb))
		}
		if hits[0] | hits[1] | hits[2] | hits[3] != 0 {
			for k := i; k < i + 64; k += 1 {
				if s[k] == a || s[k] == b {
					return k
				}
			}
		}
	}
	// 尾部（不足 64 字节）：标量即可，长度上界是 63。
	for ; i < n; i += 1 {
		if s[i] == a || s[i] == b {
			return i
		}
	}
	return -1
}
