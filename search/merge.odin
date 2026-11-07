package search

import "base:runtime"
import "xrep:lib"

// ============================================================================
// merge.odin — 多路有序归并（最小堆 + 可切分区间）
//
// 职责：把 N 个"各自已按 offset 升序"的命中列表合并成一个全局升序列表；
//       并把这件事切成 p 个**互不重叠、全局有序**的区间，好让多个线程各归并一段。
//
// 为什么不是原来的线性扫描：
//   旧实现在每条输出上线性扫过全部列表找最小游标，复杂度 O(总命中数 × 列表数)。
//   列表数 = 分片数（64 MiB / 2 MiB = 32），稠密命中（8.4 M 条）下就是 2.7 亿次
//   带分支的比较 —— 实测 287 ms，占整次扫描的 82%，且线程数 1→10 完全无扩展
//   （这段是串行的）。这里换成最小堆：每条输出只走 O(log 列表数) 层，
//   32 路时是 5 层而不是 32 次比较。
//
// 为什么能安全地切分：
//   各列表已排序，所以"全局第 T 条"这个位置**只由数据决定**，可以被精确定位：
//   先二分出边界值 v（使"偏移 ≤ v 的条目数 ≥ T"的最小 v），再按列表下标顺序
//   分配"偏移恰好等于 v"的条目，补足到恰好 T 条。于是
//     * 每个分区的输出落在一个已知的全局 rank 区间里，可以直接写进最终数组
//       的对应位置（不需要 merge 之后再拼接、也不需要额外的拷贝）；
//     * 输出与串行归并**逐条相同**，且与分区数无关 —— 换线程数不会改变结果，
//       这一点是 golden 输出能继续比对的前提。
//
// 平局规则（决定"逐条相同"是否成立）：
//   偏移相同时，旧的线性扫描用严格 `<` 从左往右找最小，因此**列表下标小的先出**，
//   同一列表内保持原序。堆的比较键是 (offset, 列表下标)，rank 切分的补足顺序
//   也是"按下标从小到大各取一段"，两者一致。
//
// 依赖：lib/base.odin（Match_Result）。本文件**不含任何线程代码**，
//       线程编排在 engine/merge.odin（这样这里可以纯函数式地被单测覆盖）。
// ============================================================================

// 列表内二分：第一个 offset >= v 的下标。
// 用于 rank 切分。"等于 v 的连续段" = [lower_bound(v), upper_bound(v))。
lower_bound :: proc(l: []lib.Match_Result, v: u64) -> int {
	lo := 0
	hi := len(l)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if l[mid].offset < v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// 列表内二分：第一个 offset > v 的下标。
upper_bound :: proc(l: []lib.Match_Result, v: u64) -> int {
	lo := 0
	hi := len(l)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if l[mid].offset <= v {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// 堆序：先比当前游标处的偏移，平局比列表下标（原因见文件头"平局规则"）。
// 只比较头部，是因为堆里存的是**列表下标**而不是条目 —— 条目本身不进堆，
// 每次取最小者只是读一次 lists[i][cur[i]]，没有搬动 16 字节结构的开销。
@(private = "file")
head_less :: proc(lists: [][]lib.Match_Result, cur: []int, a, b: int) -> bool {
	oa := lists[a][cur[a]].offset
	ob := lists[b][cur[b]].offset
	if oa != ob {
		return oa < ob
	}
	return a < b
}

// 下滤（sift-down）。heap 里是"未耗尽列表"的下标，堆顶即当前最小者。
// （Odin 的过程参数不可赋值，因此下标走一个局部副本。）
@(private = "file")
heap_down :: proc(lists: [][]lib.Match_Result, cur, heap: []int, i, n: int) {
	pos := i
	for {
		l := 2 * pos + 1
		if l >= n {
			return
		}
		small := l
		r := l + 1
		if r < n && head_less(lists, cur, heap[r], heap[l]) {
			small = r
		}
		if !head_less(lists, cur, heap[small], heap[pos]) {
			return
		}
		heap[pos], heap[small] = heap[small], heap[pos]
		pos = small
	}
}

// 归并一个区间：把 lists[i][from[i]:to[i]] 合并后**顺序填满** out。
//
// out 的长度必须等于 Σ (to[i] - from[i])；这里不做追加，直接按下标写入 ——
// 分区边界事先已知，因此没有扩容、没有容量检查，也没有"先算一遍再搬一遍"。
//
// from / to / cur / heap 都是调用方提供的临时缓冲（长度 = 列表数）：
// cur 是游标，由本函数从 from 拷入后自行推进。让调用方分配是为了让
// 并行路径能在起线程**之前**把内存备好，线程里零分配（多线程同时走
// 追踪分配器会写坏它的内部 map，见 engine/worker.odin 的并发约定）。
merge_range :: proc(lists: [][]lib.Match_Result, from, to, cur, heap: []int, out: []lib.Match_Result) {
	k := len(lists)
	n := 0 // 堆中元素个数：只有本区间内还有剩余的列表进堆
	for i in 0..<k {
		cur[i] = from[i]
		if from[i] < to[i] {
			heap[n] = i
			n += 1
		}
	}
	// 自底向上建堆：n 通常 ≤ 32，比逐个 push 便宜也更简单。
	for i := n / 2 - 1; i >= 0; i -= 1 {
		heap_down(lists, cur, heap, i, n)
	}
	w := 0
	for n > 0 {
		i := heap[0]
		out[w] = lists[i][cur[i]]
		w += 1
		cur[i] += 1
		if cur[i] >= to[i] {
			// 该列表在本区间内耗尽：把堆尾换到堆顶再下滤，等价于"删堆顶"。
			n -= 1
			heap[0] = heap[n]
		}
		if n > 0 {
			heap_down(lists, cur, heap, 0, n)
		}
	}
}

// 定位"全局第 target 条之前"的边界，把各列表在边界处的**右侧起点**写入 out。
//
// 两步：
//   1. 二分出边界值 v —— 使 Σ_i upper_bound(lists[i], v) >= target 的最小 v。
//      这样"偏移 < v"的条目数 < target ≤ "偏移 ≤ v"的条目数，v 必然取自实际数据
//      （count_le 只在碰到真实偏移值时才跳变），不会落空。
//   2. 按列表下标从小到大，为每个列表分配它"等于 v"的那一段里需要留在左侧的条目，
//      补足到恰好 target 条。剩下的起点就是 out[i] = lower_bound + 已分配数。
//      这一步的顺序就是平局规则本身：下标小的列表先把 v 排空。
@(private = "file")
rank_split :: proc(lists: [][]lib.Match_Result, target: int, out: []int) {
	k := len(lists)
	// 值域上界取全体最大偏移（避免用 u64 上限做 64 轮二分；取实际上界更快，
	// 且只有一侧可能为空时才需要额外一趟——这里直接用最后元素，列表已排序）。
	hi := u64(0)
	for i in 0..<k {
		n := len(lists[i])
		if n > 0 && lists[i][n - 1].offset > hi {
			hi = lists[i][n - 1].offset
		}
	}
	lo := u64(0)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		cnt := 0
		for i in 0..<k {
			cnt += upper_bound(lists[i], mid)
		}
		if cnt >= target {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	v := lo

	need := target
	for i in 0..<k {
		need -= lower_bound(lists[i], v)
	}
	// need 现在等于"还需要从 v 这一段里拿走的条数"，1 ≤ need ≤ 偏移等于 v 的总数。
	for i in 0..<k {
		lb := lower_bound(lists[i], v)
		ub := upper_bound(lists[i], v)
		take := ub - lb
		if take > need {
			take = need
		}
		need -= take
		out[i] = lb + take
	}
}

// 计算 p 个分区的边界。starts 长度 (p+1)*列表数：
// starts[part*k + i] 是第 part 个分区在 lists[i] 中的起点，
// 因此第 part 个分区读 lists[i][starts[part*k+i] : starts[(part+1)*k+i]]。
// 第 0 个分区恒从 0 起，第 p 个分区恒到 len(lists[i]) 止。
merge_split_starts :: proc(lists: [][]lib.Match_Result, p, total: int, starts: []int) {
	k := len(lists)
	for i in 0..<k {
		starts[i] = 0
		starts[p * k + i] = len(lists[i])
	}
	for part in 1..<p {
		// total*part/p 不会溢出 int（total ≤ 条目数 × 16 字节以内的量级），
		// 且 p ≤ total 时严格递增，因此各分区的 rank 区间非空且不重合。
		rank_split(lists, total * part / p, starts[part * k:])
	}
}

// 串行归并：单线程、单区间。保留这个入口给单元测试、自检与小规模调用 ——
// 输出与并行版本逐条相同（并行版本在数据量不足时也走这里）。
// 返回的切片由调用方拥有。
merge_ordered_matches :: proc(lists: [][]lib.Match_Result) -> []lib.Match_Result {
	k := len(lists)
	total := 0
	for l in lists {
		total += len(l)
	}
	if total == 0 {
		return nil
	}
	// 不清零：每个位置都必然被 merge_range 写到，清零 134 MB 是纯粹的浪费。
	out := runtime.non_zero_make_slice([]lib.Match_Result, total)
	from := make([]int, k)
	to := make([]int, k)
	cur := make([]int, k)
	heap := make([]int, k)
	defer delete(from)
	defer delete(to)
	defer delete(cur)
	defer delete(heap)
	for i in 0..<k {
		from[i] = 0
		to[i] = len(lists[i])
	}
	merge_range(lists, from, to, cur, heap, out)
	return out
}
