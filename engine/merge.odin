#+dialect hela
package engine

// ============================================================================
// merge.odin — 并行多路归并的线程编排
//
// 职责：把 search/merge.odin 的"可切分区间归并"真正铺到多个线程上。
//       算法、切分与平局规则都在 search 包里（那里没有线程代码，可被纯单测覆盖）；
//       本文件只负责三件事：决定切几段、备好每段的内存、起线程并等待。
//
// 为什么放在 engine 而不是 search：
//   search 是纯算法层，单测希望不依赖线程调度；engine 已经承载了 worker /
//   output_thread 的线程生命周期，线程编排留在这里层次一致。
//
// 为什么切分是精确的：
//   search.merge_split_starts 用全局 rank 定位边界，所以每个分区的输出落在
//   一个**已知的** rank 区间里 —— 直接写进最终数组的对应位置。因此：
//     * 不需要"先各算一段再拼接"，输出数组只分配一次；
//     * 输出与串行归并逐条相同，**且与分区数无关**（换线程数不改结果）；
//     * 各分区长度差不超过 1，天然负载均衡，不需要工作窃取。
//
// 线程里的分配：为零。所有缓冲（starts / scratch / out）都由主线程备好再传进去。
//   原因见 worker.odin 的并发约定：`odin test` 下主线程的分配器是
//   mem.Tracking_Allocator（内部无锁 map），多线程同时分配会写坏它。归并线程
//   只写内存、不申请内存，这条约束就不可能被踩到。
// ============================================================================

import "base:runtime"
import "core:thread"
import "xrep:lib"
import "xrep:search"

// 每个分区至少要有这么多条命中，才值得为它起一个线程。
// 线程创建+销毁约 50–80 µs，归并 6.5 万条大约 1 ms —— 低于这个量级时，
// 起线程的固定开销会把收益吃掉（小文件仍然走串行路径，行为与旧版一致）。
MERGE_MIN_PER_PART :: 1 << 16

// 分区数上限。超过物理核数后加线程只会增加争抢；归并是纯内存带宽+分支的活，
// 16 已经足够喂满本机（10 逻辑核 / 4 性能核），再多没有意义。
MERGE_MAX_PARTITIONS :: 16

// 一个分区的全部输入/输出/临时缓冲。地址全部由主线程给出，线程内不复用。
merge_slice :: struct {
	lists:   [][]lib.Match_Result,
	from:    []int, // 各列表在本分区内的起点
	to:      []int, // 各列表在本分区内的终点（不含）
	scratch: []int, // 长度 2*k：前 k 个是游标，后 k 个是堆
	out:     []lib.Match_Result, // 本分区要填满的全局输出区间
}

merge_slice_run :: proc(data: rawptr) {
	// 同 worker_steal：线程入口先归一化上下文。本函数不分配内存，这一步是为了
	// 让"归并线程与创建者的 context 无关"成为显式契约，而不是依赖当前实现恰好不分配。
	context = runtime.default_context()
	j := cast(^merge_slice)data
	k := len(j.lists)
	search.merge_range(j.lists, j.from, j.to, j.scratch[:k], j.scratch[k:2 * k], j.out)
}

// 并行归并：lists 各段已升序，返回全局升序的合并结果（调用方拥有）。
// threads ≤ 1、数据量不足或只有 0/1 个列表时退化为串行 —— 结果完全相同。
merge_ordered_matches_parallel :: proc(lists: [][]lib.Match_Result, threads: int) -> []lib.Match_Result {
	total := 0
	for l in lists {
		total += len(l)
	}
	k := len(lists)
	if total == 0 || k == 0 {
		return nil
	}
	p := threads
	if p > MERGE_MAX_PARTITIONS {
		p = MERGE_MAX_PARTITIONS
	}
	if p > total {
		p = total
	}
	if p <= 1 || total / p < MERGE_MIN_PER_PART {
		return search.merge_ordered_matches(lists)
	}

	out := runtime.non_zero_make_slice([]lib.Match_Result, total)
	starts := make([]int, (p + 1) * k)
	defer delete(starts)
	search.merge_split_starts(lists, p, total, starts)

	// 每个分区的输出起点 = 该分区之前已经被消费的条目数 = 各列表游标之和。
	// 这个和必然等于 total*part/p —— 切分若出错，这里立刻会写出错位的结果，
	// 所以单测里直接断言这个恒等式（见 merge_test.odin 的 partition 用例）。
	out_pos := make([]int, p + 1)
	defer delete(out_pos)
	for part in 0..<p + 1 {
		s := 0
		for i in 0..<k {
			s += starts[part * k + i]
		}
		out_pos[part] = s
	}

	scratch := make([]int, p * 2 * k)
	defer delete(scratch)
	jobs := make([]merge_slice, p)
	defer delete(jobs)
	ths := make([]^thread.Thread, p)
	defer delete(ths)

	for part in 0..<p {
		jobs[part] = merge_slice{
			lists   = lists,
			from    = starts[part * k:(part + 1) * k],
			to      = starts[(part + 1) * k:(part + 2) * k],
			scratch = scratch[part * 2 * k:(part + 1) * 2 * k],
			out     = out[out_pos[part]:out_pos[part + 1]],
		}
		ths[part] = thread.create_and_start_with_data(&jobs[part], merge_slice_run)
	}
	for t in ths {
		thread.join(t)
		thread.destroy(t)
	}
	return out
}
