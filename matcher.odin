package main

// ============================================================================
// matcher.odin — 匹配算法层
//
// 职责：提供"按模式长度自动选择算法"的匹配能力。所有算法共享 Match_Fn 签名，
//       通过 alg_table 注册；新增算法只需在表中加一行（capability seam），
//       调用方（worker_steal）不必改动。
//
// 依赖：common.odin（类型与查表）、progress.odin（进度上报）。
//
// 内存约定（重要，曾出过问题）：
//   算法内部**不得**写 `context.allocator = mem.arena_allocator(arena)`。
//   那样会永久改写当前线程的分配器（proc 返回也不还原），使调用方后续所有
//   make/append 都落进 arena —— 而 arena 会被 arena_pool 反复 reset 复用，
//   数据随时可能被后来的分片覆盖。
//   正确做法是把 arena 分配器**显式**传给每一次分配：make(..., allocator)。
//   这样命中数组仍来自 arena（原设计意图：批量释放、零散分配快），
//   而调用方的分配器保持原样（worker 的"拷贝到堆"才真的落在堆上）。
// ============================================================================

import "core:mem"

// 单字节模式：直接线性扫描，O(n)，无需内层循环比较。
single_match :: proc(data: []u8, ctx: Match_Ctx, arena: ^mem.Arena, progress: ^Progress) -> []Match_Result {
    // 显式指定 arena 分配器（不要改写 context.allocator，见文件头说明）。
    results := make([dynamic]Match_Result, 0, 64, mem.arena_allocator(arena))
    target := ctx.pattern[0]
    if ctx.case_insensitive {
        target = lower_table[target]
    }
    for i in 0..<len(data) {
        b := data[i]
        if ctx.case_insensitive {
            b = lower_table[b]
        }
        if b == target {
            append(&results, Match_Result{offset = u64(i)})
        }
    }
    progress_add(progress, u64(len(data)))
    return results[:]
}

// 朴素扫描：逐位对齐、逐字节比较，O(n*m)。
// 命中区间允许重叠（例如在 "aaaa" 中匹配 "aa" 得到 3 个命中）。
naive_match :: proc(data: []u8, ctx: Match_Ctx, arena: ^mem.Arena, progress: ^Progress) -> []Match_Result {
    // 显式指定 arena 分配器（不要改写 context.allocator，见文件头说明）。
    results := make([dynamic]Match_Result, 0, 64, mem.arena_allocator(arena))
    pat_len := uint(len(ctx.pattern))
    // 空模式不产生任何命中，直接返回空（避免下方 0 长度比较导致的退化行为）。
    if pat_len == 0 {
        return results[:]
    }
    // 上界 i + pat_len <= len(data) 保证内层访问不越界。
    for i := uint(0); i + pat_len <= uint(len(data)); i += 1 {
        match_ok := true
        for j := uint(0); j < pat_len; j += 1 {
            d_byte := data[i + j]
            p_byte := ctx.pattern[j]
            if ctx.case_insensitive {
                d_byte = lower_table[d_byte]
                p_byte = lower_table[p_byte]
            }
            if d_byte != p_byte {
                match_ok = false
                break
            }
        }
        if match_ok {
            append(&results, Match_Result{offset = u64(i)})
        }
    }
    progress_add(progress, u64(len(data)))
    return results[:]
}

// 中短模式（2..16 字节）入口。
// 说明：此处**未实现** BNDM 位并行算法，而是直接委托给经过验证的朴素扫描，
//       保证正确性优先；因此 2..16 区间当前与 naive_match 行为完全等价。
//       若后续实现真正的位并行版本，只需替换本函数体，选择表与调用方无需改动。
bndm_match :: proc(data: []u8, ctx: Match_Ctx, arena: ^mem.Arena, progress: ^Progress) -> []Match_Result {
    return naive_match(data, ctx, arena, progress)
}

// ---------------------------------------------------------------------------
// 算法选择表
// ---------------------------------------------------------------------------

// 算法选择表：以模式长度区间选择匹配算法。
//
// 这里刻意使用**编译期常量数组**，而不是"启动时 make 出来再填充"的可变全局表：
//   1. 不存在"忘记初始化"的可能 —— 空表回退路径随之消失，
//      `odin test` 也不再需要任何手动 init（测试踩坑记录见 README「测试」章节）；
//   2. 不占堆内存、不产生进程级泄漏（追踪分配器不会再报 init_alg_table 泄漏）；
//   3. 表内容随二进制固化，便于审查。
// 表里放的是匹配函数指针，属于"能力缝隙"：换算法只改这里一行。
alg_table := [?]Algorithm_Entry{
    {min_len = 1, max_len = 1, matcher = single_match},
    {min_len = 2, max_len = 16, matcher = bndm_match},
    {min_len = 17, max_len = 64, matcher = naive_match},
}

// 按模式长度选择匹配函数；区间均不命中（如 0 字节或 > 64 字节）时回退 naive_match。
// 回退是纯保险：naive_match 对任意长度都给出正确答案，只是不保证速度。
select_matcher :: proc(pat_len: uint) -> Match_Fn {
    for entry in alg_table {
        if pat_len >= entry.min_len && pat_len <= entry.max_len {
            return entry.matcher
        }
    }
    return naive_match
}
