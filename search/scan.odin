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
//
// 块内定位：**不用**逐字节重扫。第二版在"块命中"之后从块起点标量重扫到命中处，
// 稀疏数据上完全看不出来，密集数据（平均每 36 字节一次命中）上却是纯损失：
// 每次调用平均多走 18 次标量分支。第三版改用 `select + reduce_min`（与
// `core:bytes` 同一套手法），实测把 `-i` 与 `-c` 的差距从 24 ms 抹平。
// ============================================================================

import "base:intrinsics"

import "core:bytes"
import "core:simd"

// 块内定位用的下标向量与哨兵：与 `core:bytes` 的扫描器同一套手法 ——
// `select(cmp, INDICES, SENTINEL_MAX)` 把不匹配的道变成 0xFF，`reduce_min`
// 于是给出**最小的匹配道号**，一次向量归约就拿到块内偏移。
@(private)
INDICES_128: simd.u8x16 : {
	0,  1,  2,  3,  4,  5,  6,  7,
	8,  9, 10, 11, 12, 13, 14, 15,
}
@(private)
SENTINEL_MAX_128: simd.u8x16 : u8(0xFF)

// index_folded 找第一个 `c | 0x20 == lower` 的字节，即 {lower, lower-0x20} 之一。
// 调用方保证 `lower` 是 'a'..'z'，因此这个集合恰好是同一字母的两种写法。
//
// 为什么撤销折叠（`| 0x20`）只做一次比较：`c | 0x20` 对同一字母的两种写法落到
// 同一个值，所以"两个候选"变成"一个候选"，每 16 字节少一条 `lanes_eq`。
//
// 第三版的块内定位改成向量归约（此前是标量重扫）。为什么值得：密集命中时
// （实测 `z` 在 256 MiB 语料里平均每 36 字节一次）每一次调用都从 64 字节块的
// 起点重扫到命中处，平均 18 次标量比较 —— 7.47M 次命中 × 18 次 ≈ 1.3 亿次
// 分支，实测让 `-i` 比大小写敏感多花 24 ms（46.0 → 70.1 ms，`-o:speed`）。
// 向量归约把它压成常数条指令，`-i` 的差距随之消失（见 ADR 0013 的实测表）。
index_folded :: proc "contextless" (s: []u8, lower: u8) -> int #no_bounds_check {
	l := len(s)
	// 与 core 一致：短切片直接标量，向量启动开销在 16 字节以下不划算。
	if l < 16 {
		for i in 0 ..< l {
			if s[i] | 0x20 == lower {
				return i
			}
		}
		return -1
	}

	vl := simd.u8x16(lower)
	fold := simd.u8x16(0x20)
	i := 0

	// 64 字节 / 4 个 128 位向量：主流路径。
	for ; i + 64 <= l; i += 64 {
		vs: [4]simd.u8x16
		cs: [4]simd.u8x16
		ms: [4]u8
		#unroll for j in 0 ..< 4 {
			vs[j] = intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i + j * 16:]))
			cs[j] = simd.lanes_eq(vs[j] | fold, vl)
			ms[j] = simd.reduce_or(cs[j])
		}
		if ms[0] | ms[1] | ms[2] | ms[3] != 0 {
			#unroll for j in 0 ..< 4 {
				if ms[j] != 0 {
					off := simd.reduce_min(simd.select(cs[j], INDICES_128, SENTINEL_MAX_128))
					return i + j * 16 + int(off)
				}
			}
		}
	}

	// 16 字节块：命中密集时（相邻命中只隔几十字节）上一步的 64 字节块会
	// "看到"命中却跨过它 —— 这里按单向量推进，尾部不浪费。
	for ; i + 16 <= l; i += 16 {
		v := intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i:]))
		c := simd.lanes_eq(v | fold, vl)
		if simd.reduce_or(c) != 0 {
			off := simd.reduce_min(simd.select(c, INDICES_128, SENTINEL_MAX_128))
			return i + int(off)
		}
	}

	// 尾部（不足 16 字节）：标量即可，长度上界是 15。
	for ; i < l; i += 1 {
		if s[i] | 0x20 == lower {
			return i
		}
	}
	return -1
}

// 返回第一个满足 s[i] == a 或 s[i] == b 的 i，没有则 -1。
//
// 形状与 `core:bytes.index_byte` 一致：64 字节块 → 16 字节块 → 标量尾巴，
// 块内定位一律走 `select + reduce_min`（不做标量重扫）。
index_either :: proc "contextless" (s: []u8, a, b: u8) -> int #no_bounds_check {
	// 两个候选相同（大小写不敏感的字母以外，或大小写敏感路径）时没有第二趟可省，
	// 直接交给 core 的实现，避免在同一份代码里维护两条等价路径。
	if a == b {
		return bytes.index_byte(s, a)
	}

	// ---- 同字母的两种写法：折叠向量，只比一次 ----
	//
	// 大小写不敏感搜索的两个候选几乎总是 'a' 与 'A' 这种配对，而这类配对可以化简成
	// 一次比较：对 ascii 小写字母 l，`(c | 0x20) == l` 恰好等价于 `c ∈ {l, l-32}`
	// —— 只有这两个字节 |0x20 之后等于 l。（`c | 0x20` 对其它字符不是单射，但这里
	// 不构成问题：非字母时 `alt_case` 返回自身，调用方根本不会传进来一对非字母。）
	//
	// 为什么值得：两次 `lanes_eq` + 两次 `reduce_or` 让这条循环变成**算力受限**。
	// 数据在缓存里时（多 worker 各扫 1/8 的上下文）实测比单候选慢 60%，
	// 而单候选路径只做一次比较。折叠之后 ALU 与 `index_byte` 持平。
	lo, hi := a, b
	if lo > hi {
		lo, hi = hi, lo
	}
	// 排完序后两个候选里较小的一定是**大写**形式（'A'=0x41 < 'a'=0x61）。
	// 第一版写成了 `lo >= 'a' && hi == lo - 32`，永远为假 —— 于是这段快路径
	// 一次都没跑过，而基准也没有变化。改完之后 `-i` 才真正回到单候选的水平。
	if lo >= 'A' && lo <= 'Z' && hi == lo + 32 {
		return index_folded(s, hi)
	}

	l := len(s)
	if l < 16 {
		for i in 0 ..< l {
			if s[i] == a || s[i] == b {
				return i
			}
		}
		return -1
	}

	va := simd.u8x16(a)
	vb := simd.u8x16(b)
	i := 0

	for ; i + 64 <= l; i += 64 {
		cs: [4]simd.u8x16
		ms: [4]u8
		#unroll for j in 0 ..< 4 {
			v := intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i + j * 16:]))
			cs[j] = simd.lanes_eq(v, va) | simd.lanes_eq(v, vb)
			ms[j] = simd.reduce_or(cs[j])
		}
		if ms[0] | ms[1] | ms[2] | ms[3] != 0 {
			#unroll for j in 0 ..< 4 {
				if ms[j] != 0 {
					off := simd.reduce_min(simd.select(cs[j], INDICES_128, SENTINEL_MAX_128))
					return i + j * 16 + int(off)
				}
			}
		}
	}

	for ; i + 16 <= l; i += 16 {
		v := intrinsics.unaligned_load(cast(^simd.u8x16)raw_data(s[i:]))
		c := simd.lanes_eq(v, va) | simd.lanes_eq(v, vb)
		if simd.reduce_or(c) != 0 {
			off := simd.reduce_min(simd.select(c, INDICES_128, SENTINEL_MAX_128))
			return i + int(off)
		}
	}

	for ; i < l; i += 1 {
		if s[i] == a || s[i] == b {
			return i
		}
	}
	return -1
}
