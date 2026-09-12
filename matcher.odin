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
// 内存约定（重要，曾出过两次问题）：
//   1. 算法内部**不得**写 `context.allocator = <某分配器>`。那样会永久改写当前
//      线程的分配器（proc 返回也不还原），使调用方后续所有 make/append 都落到
//      别处，数据随时可能被后续分片覆盖。
//   2. 命中数组**不再**由 arena 承载（ADR 0004）。arena 是定长的，而命中数没有
//      上界；超过块容量时 Odin 的 `append` 会**静默失败** —— 不报错、不回滚，
//      只是少记几条，于是"命中被悄悄丢弃"。改用 `context.allocator` 后不存在
//      容量上限，调用方拿到切片后负责释放。
//
// 分配器契约（容易踩）：数组用**调用时的** `context.allocator` 分配。worker 线程
// 入口会 `context = runtime.default_context()`，因此 worker 分配的是"进程默认堆"
// 内存。释放方若不在同一线程，必须显式传入同一分配器
// （`delete(slice, runtime.default_context().allocator)`）；否则在 `odin test`
// 下会用追踪分配器去 free 堆指针，直接报 "bad free"。
//
// 并发：本模块自身无共享可变状态，线程安全；每次调用返回独立切片。
// ============================================================================

// 命中数组的初始容量。仅为减少小输入的扩容次数；超出后正常增长（无上限）。
MATCH_INITIAL_CAP :: 64

// 单字节模式：直接线性扫描，O(n)，无需内层循环比较。
single_match :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result {
    results := make([dynamic]Match_Result, 0, MATCH_INITIAL_CAP)
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
            append(&results, Match_Result{offset = u64(i), pat_len = 1})
        }
    }
    progress_add(progress, u64(len(data)))
    return results[:]
}

// 朴素扫描：逐位对齐、逐字节比较，O(n*m)。
// 命中区间允许重叠（例如在 "aaaa" 中匹配 "aa" 得到 3 个命中）。
naive_match :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result {
    results := make([dynamic]Match_Result, 0, MATCH_INITIAL_CAP)
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
            append(&results, Match_Result{offset = u64(i), pat_len = u32(pat_len)})
        }
    }
    progress_add(progress, u64(len(data)))
    return results[:]
}

// 中短模式（2..16 字节）入口。
// 说明：此处**未实现** BNDM 位并行算法，而是直接委托给经过验证的朴素扫描，
//       保证正确性优先；因此 2..16 区间当前与 naive_match 行为完全等价。
//       若后续实现真正的位并行版本，只需替换本函数体，选择表与调用方无需改动。
bndm_match :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result {
    return naive_match(data, ctx, progress)
}

// 多模式匹配（`-e PATTERN` 可重复 / `-f FILE` 逐行读模式）。
// 按位置遍历整张模式表，命中的模式按模式表顺序产出。
//
// 复杂度 O(n × Σ|pat|)。刻意**不**实现 Aho-Corasick：那需要自动机构建、失败指针
// 与状态管理，收益要到模式数上百时才显现；命令行场景模式数通常个位数，得不偿失。
//
// 语义说明：同一偏移被多个模式命中时会各产出一条结果（不去重）——
// 与既有的"分片重叠窗口内命中重复上报"契约一致（见 README「已知行为与限制」）。
multi_match :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result {
    results := make([dynamic]Match_Result, 0, MATCH_INITIAL_CAP)
    n := uint(len(data))
    pat_count := ctx_pattern_count(ctx)
    for i := uint(0); i < n; i += 1 {
        for k in 0..<pat_count {
            pat := ctx_pattern_at(ctx, k)
            plen := uint(len(pat))
            // 空模式不产生命中（与 naive_match 对空模式的约定一致）。
            if plen == 0 || i + plen > n {
                continue
            }
            match_ok := true
            for j := uint(0); j < plen; j += 1 {
                d_byte := data[i + j]
                p_byte := pat[j]
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
                append(&results, Match_Result{offset = u64(i), pat_len = u32(plen)})
            }
        }
    }
    progress_add(progress, u64(len(data)))
    return results[:]
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

// 按整个匹配上下文选择匹配函数（worker 的入口）。
// 多模式（-e / -f）统一交给 multi_match；单模式仍走 alg_table 的长度分派，
// 因此**单模式路径的算法与性能与加多模式之前完全一致**。
select_matcher_for :: proc(ctx: Match_Ctx) -> Match_Fn {
    if len(ctx.extra) > 0 {
        return multi_match
    }
    return select_matcher(uint(len(ctx.pattern)))
}
