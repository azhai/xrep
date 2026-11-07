package search

import "core:bytes"
import "xrep:lib"



// ============================================================================
// matcher.odin — 匹配算法层
//
// 职责：提供"按模式长度自动选择算法"的匹配能力。所有算法共享 Match_Fn 签名，
//       通过 alg_table 注册；新增算法只需在表中加一行（capability seam），
//       调用方（worker_steal）不必改动。
//
// 依赖：lib/base.odin（类型与查表）、lib/progress.odin（进度上报）。
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

// ---------------------------------------------------------------------------
// 预筛原语（ADR 0008 性能改造的核心）
// ---------------------------------------------------------------------------

// 大小写不敏感时同一字母有两种写法。给出小写形式，返回另一种；
// 非字母时两者相同，调用方据此只查一次（省掉一半 SIMD 调用）。
alt_case :: proc "contextless" (lower_b: u8) -> u8 {
    if lower_b >= 'a' && lower_b <= 'z' {
        return lower_b - 32 // 'a'..'z' -> 'A'..'Z'
    }
    return lower_b
}

// 在 d 中找 a（或 a/b 两者中较早的）第一次出现的位置。
//
// 单候选走 `bytes.index_byte`：那是 core 的 SIMD 实现（amd64+AVX2 用 256 位、
// arm64 每轮 64 字节 4 个 128 位向量），稀疏数据下比逐字节扫描快一个数量级，
// 且是 "contextless"，不碰分配器。
//
// 双候选（大小写不敏感）走 `index_either`：**一趟**里同时比两个字节。
// 这里曾经是 `min(index_byte(a), index_byte(b))` —— 两趟完整扫描，稀疏命中时
// 内存流量翻倍（256 MiB 实测 30.3 → 62.5 GB/s）。
find_byte :: proc "contextless" (d: []u8, a: u8, b: u8, two: bool) -> int {
    if !two {
        return bytes.index_byte(d, a)
    }
    return index_either(d, a, b)
}

// 验证 data[at:at+m] 是否等于 pat。首字节已由预筛保证相等，故从 j=m-1
// **倒序**比到 j=1：真实数据里的失配多发生在尾部，倒序能更早退出。
match_rest :: proc "contextless" (data: []u8, pat: []u8, at: uint, m: uint, ci: bool) -> bool {
    if ci {
        for j := m - 1; j >= 1; j -= 1 {
            if lib.lower_table[data[at + j]] != lib.lower_table[pat[j]] {
                return false
            }
        }
        return true
    }
    for j := m - 1; j >= 1; j -= 1 {
        if data[at + j] != pat[j] {
            return false
        }
    }
    return true
}

// 命中数组的初始容量。仅为减少小输入的扩容次数；超出后正常增长（无上限）。
MATCH_INITIAL_CAP :: 64

// 单字节模式：SIMD 跳到候选位置，再**就地连续消费**。
//
// 为什么分两段：纯 `index_byte` 循环在**密集**数据上会退化成"每个字节一次
// 调用"（每次只前进 1，SIMD 的启动开销反客为主）—— 典型如 `a` 扫全 `a` 文件
// （`all_a.bin`，2.5 MiB 全命中）。命中后先就地连续消费（无调用开销），
// 遇到非命中再用 SIMD 跳跃，两种分布都不吃亏。
single_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
    n := uint(len(data))
    target := ctx.pattern[0]
    if ctx.case_insensitive {
        target = lib.lower_table[target]
    }
    alt := target
    two := false
    if ctx.case_insensitive {
        alt = alt_case(target)
        two = alt != target
    }
    i := uint(0)
    for i < n {
        idx := find_byte(data[i:], target, alt, two)
        if idx < 0 {
            break
        }
        i += uint(idx)
        // 密集段：连续命中就地消费（大写形式已由 lower_table 归一化到 target）
        for i < n {
            b := data[i]
            if ctx.case_insensitive {
                b = lib.lower_table[b]
            }
            if b != target {
                break
            }
            append(&results, lib.Match_Result{offset = u64(i), pat_len = 1})
            i += 1
        }
    }
    lib.progress_add(progress, u64(len(data)))
    return results[:]
}

// 朴素扫描：逐位对齐、逐字节比较，O(n*m)。
// 命中区间允许重叠（例如在 "aaaa" 中匹配 "aa" 得到 3 个命中）。
naive_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
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
                d_byte = lib.lower_table[d_byte]
                p_byte = lib.lower_table[p_byte]
            }
            if d_byte != p_byte {
                match_ok = false
                break
            }
        }
        if match_ok {
            append(&results, lib.Match_Result{offset = u64(i), pat_len = u32(pat_len)})
        }
    }
    lib.progress_add(progress, u64(len(data)))
    return results[:]
}

// ---------------------------------------------------------------------------
// 位并行 BNDM（Backward Nondeterministic DAWG Matching）
// ---------------------------------------------------------------------------

// BNDM 用 u64 位掩码承载"模式前缀 vs 窗口后缀"的匹配状态，因此模式长度
// 上限就是机器字长 64 字节（超出的场合见下方回退分支）。
BNDM_MAX_LEN :: 64

// 位并行 BNDM：**从窗口尾部向前**读，用一次移位 + 一次掩码同时更新所有
// 可能的对齐位置，并在读完之前就确定安全的跳跃距离。
//
// 不变量（第 j 轮与 B[data[pos+j]] 相交之后）：
//   D 的第 r 位为 1  ⟺  pat[r .. r+(m-1-j)] == data[pos+j .. pos+m-1]
// 于是：
//   * 第 0 位为 1 ⟺ "窗口后缀 == 模式前缀"，即 pos+j 是一个合法的候选起点；
//   * j == 0 且第 0 位为 1 ⟺ 完整命中。
// 递推只需 `D = (D >> 1) & B[c]`：D 的第 r 位由上一轮第 r+1 位"右移"得来，
// 正好对应"模式位置 r 去对齐更早的那个字节"。
//
// 跳跃：反向扫描过程中 j 递减，每当第 0 位为 1 就记下 `last = j`；最终留下的是
// **最小的**合法 j，也就是不会漏掉任何候选起点的最保守位移。整轮都没记到就
// 位移 m（窗口内没有任何前缀-后缀重合，跳过整个窗口是安全的）。
//
// 与 naive_match 的结果逐条一致：候选起点逐 1 推进，重叠命中不丢。
bndm_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    pat := ctx.pattern
    m := uint(len(pat))
    // 位掩码装不下超长模式：交给通用实现（结果一致，只是慢）。
    if m > BNDM_MAX_LEN {
        return naive_match(data, ctx, progress)
    }
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
    n := uint(len(data))
    // 与 naive/memchr 一致：空模式、模式比数据长都无命中，但**照样上报扫描量**。
    if m == 0 || m > n {
        lib.progress_add(progress, u64(len(data)))
        return results[:]
    }

    // 预处理：B[c] 的第 j 位为 1 ⟺ pat[j] == c（大小写不敏感时双方都取小写）。
    B: [256]u64
    if ctx.case_insensitive {
        for j := uint(0); j < m; j += 1 {
            B[lib.lower_table[pat[j]]] |= 1 << j
        }
    } else {
        for j := uint(0); j < m; j += 1 {
            B[pat[j]] |= 1 << j
        }
    }
    // 低 m 位全 1。m == 64 时 `1 << 64` 是未定义行为，必须单独处理。
    full: u64 = ~u64(0)
    if m < 64 {
        full = (u64(1) << m) - 1
    }

    limit := n - m + 1
    pos := uint(0)
    for pos < limit {
        j := m - 1
        last := m
        D := full
        for {
            c := data[pos + j]
            if ctx.case_insensitive {
                c = lib.lower_table[c]
            }
            D &= B[c]
            if D == 0 {
                break
            }
            if D & 1 == 1 {
                if j == 0 {
                    append(&results, lib.Match_Result{offset = u64(pos), pat_len = u32(m)})
                } else {
                    last = j
                }
            }
            if j == 0 {
                break
            }
            D >>= 1
            j -= 1
        }
        pos += last
    }
    lib.progress_add(progress, u64(len(data)))
    return results[:]
}

// 多字节模式的通用实现：**首字节 SIMD 预筛 + 倒序验证**。
//
// 相比朴素扫描（每个对齐位置都比较 m 个字节），这里先用 SIMD 找出首字节的
// 出现位置，只有首字节对上了才做剩下的 m-1 次比较 —— 真实数据里首字节命中的
// 概率远低于 1/m，于是内层比较次数从 O(n·m) 降到 O(n/m · m) = O(n)。
//
// 正确性要点：
//   - 候选位置逐 1 推进，因此**重叠命中不丢**（"aa" 在 "aaa" 中仍是 2 条）；
//   - 只在 [0, n-m] 范围内搜首字节，天然不会越界读；
//   - 空模式与"模式比数据长"都与朴素实现一样返回空，且**照样上报扫描字节数**
//     （进度条依赖它，测试有断言）。
//
// 退化保护（ADR 0009）：预筛的代价正比于"首字节出现的频率"。若首字节在数据里
// 极常见（典型如二进制数据里搜 0x00 开头的模式），SIMD 每个字节都"命中"，
// 预筛就退化成逐字节验证 —— 此时切换到 BNDM（它先读**末字节**，可能一次就
// 否掉整个窗口）。判定用"候选密度"而不是预先采样，因此不依赖样本代表性。
//   ADAPTIVE_MIN_SCAN — 至少扫过这么多字节才允许切换（避免小分片误判）
//   ADAPTIVE_MAX_DENSITY — 候选数 / 已扫字节 超过 1/这个值 即判为退化
// 阈值取 1/4 是量出来的（`xrep --bench` 的 A4 组）：
//   uniform（首字节 1/256）memchr 34.6 GB/s vs bndm 5.1 GB/s —— 不该切；
//   dense  （"aa" 扫全 'a'）memchr 87 MB/s vs bndm 154 MB/s —— 该切；
//   zeros  （首字节 100%）  两者都是 758 MB/s —— 切不切一样。
// dense.bin（'t' 每 8 字节一次 = 1/8）落在阈值下方，保持不切。
ADAPTIVE_MIN_SCAN :: 4096
ADAPTIVE_MAX_DENSITY :: 4

memchr_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
    pat := ctx.pattern
    m := uint(len(pat))
    n := uint(len(data))
    // 空模式 / 模式比数据长：不可能命中。仍需上报扫描量（与 naive 一致）。
    if m == 0 || m > n {
        lib.progress_add(progress, u64(len(data)))
        return results[:]
    }
    first := pat[0]
    if ctx.case_insensitive {
        first = lib.lower_table[first]
    }
    alt := first
    two := false
    if ctx.case_insensitive {
        alt = alt_case(first)
        two = alt != first
    }
    // 候选位置的上界：at + m <= n。搜索区间到 n-m+1 为止（含）。
    search_end := n - m + 1
    at := uint(0)
    scanned := uint(0) // 已扫过的字节数（切换判定用）
    cands := uint(0) // 已遇到的候选数
    for at < search_end {
        idx := find_byte(data[at:search_end], first, alt, two)
        if idx < 0 {
            break
        }
        at += uint(idx)
        // ---- 退化判定：只在 BNDM 扛得住的模式长度下启用 ----
        if m <= BNDM_MAX_LEN {
            scanned += uint(idx) + 1
            cands += 1
            if scanned >= ADAPTIVE_MIN_SCAN && cands * ADAPTIVE_MAX_DENSITY > scanned {
                // 把剩余区间整体交给 BNDM，并把偏移还原成文件绝对位置。
                // 此刻 at 处的候选**尚未验证**，因此不会出现重复上报。
                // 零值 Progress 的 enabled 为 false，progress_add 会直接返回，
                // 不会重复累加扫描量。
                tail_prog: lib.Progress
                tail := bndm_match(data[at:], ctx, &tail_prog)
                for h in tail {
                    append(&results, lib.Match_Result{offset = h.offset + u64(at), pat_len = h.pat_len})
                }
                delete(tail)
                break
            }
        }
        if match_rest(data, pat, at, m, ctx.case_insensitive) {
            append(&results, lib.Match_Result{offset = u64(at), pat_len = u32(m)})
        }
        at += 1
    }
    lib.progress_add(progress, u64(len(data)))
    return results[:]
}

// 多模式匹配（`-e PATTERN` 可重复 / `-f FILE` 逐行读模式）。
// 按位置遍历整张模式表，命中的模式按模式表顺序产出。
//
// 复杂度：最坏仍是 O(n × Σ|pat|)，但**首字节位图**把绝大多数位置挡在模式比较
// 之外，实测 4 模式场景快 3 倍以上。刻意**不**实现 Aho-Corasick：那需要自动机
// 构建、失败指针与状态管理，收益要到模式数上百时才显现；命令行场景模式数通常
// 个位数，得不偿失。
//
// 语义说明：同一偏移被多个模式命中时会各产出一条结果（不去重）——
// 与既有的"分片重叠窗口内命中重复上报"契约一致（见 README「已知行为与限制」）。
multi_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
    n := uint(len(data))
    pat_count := lib.ctx_pattern_count(ctx)

    // 首字节集合（256 位 = 4×u64）：**所有模式首字节**的位图。
    // 一个位置若其字节不在集合里，就不可能是任何模式的起点 —— 直接跳过，
    // 连一次模式比较都不做。多模式的热点是"每个位置 × 每个模式"，这道预筛
    // 把绝大多数位置挡在了外层，是 4 模式场景提速的主要来源。
    first_bits: [4]u64
    for k in 0..<pat_count {
        pat := lib.ctx_pattern_at(ctx, k)
        if len(pat) == 0 {
            continue
        }
        b := pat[0]
        if ctx.case_insensitive {
            b = lib.lower_table[b]
        }
        first_bits[b >> 6] |= 1 << uint(b & 63)
    }

    for i := uint(0); i < n; i += 1 {
        b := data[i]
        if ctx.case_insensitive {
            b = lib.lower_table[b]
        }
        if (first_bits[b >> 6] >> uint(b & 63)) & 1 == 0 {
            continue
        }
        for k in 0..<pat_count {
            pat := lib.ctx_pattern_at(ctx, k)
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
                    d_byte = lib.lower_table[d_byte]
                    p_byte = lib.lower_table[p_byte]
                }
                if d_byte != p_byte {
                    match_ok = false
                    break
                }
            }
            if match_ok {
                append(&results, lib.Match_Result{offset = u64(i), pat_len = u32(plen)})
            }
        }
    }
    lib.progress_add(progress, u64(len(data)))
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
alg_table := [?]lib.Algorithm_Entry{
    {min_len = 1, max_len = 1, matcher = single_match},
    // 2..16 走 SIMD 预筛；首字节过于稠密时它会自动切换到位并行 BNDM
    // （见 memchr_match 的退化保护）。纯 BNDM 在这台有 AVX2 的机器上是
    // 预筛的**负优化**（实测见 ADR 0009），所以它不作为默认入口。
    {min_len = 2, max_len = 16, matcher = memchr_match},
    // 长模式同样吃 SIMD 预筛的红利（首字节在稀疏数据里很稀有），
    // 因此 17..4096 一并交给 memchr_match，而不是退回朴素扫描。
    {min_len = 17, max_len = 4096, matcher = memchr_match},
}

// 按模式长度选择匹配函数；区间均不命中（如 0 字节或 > 64 字节）时回退 naive_match。
// 回退是纯保险：naive_match 对任意长度都给出正确答案，只是不保证速度。
select_matcher :: proc(pat_len: uint) -> lib.Match_Fn {
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
// 多模式（-e / -f）统一交给 multi_match；模式数多到一定程度（见 ac.odin 的
// ac_worth_it）改走 Aho-Corasick 自动机 —— 代价从 O(n × 模式数) 变成 O(n)。
select_matcher_for :: proc(ctx: lib.Match_Ctx) -> lib.Match_Fn {
    if len(ctx.extra) > 0 {
        if ac_worth_it(ctx) {
            return multi_ac_match
        }
        return multi_match
    }
    return select_matcher(uint(len(ctx.pattern)))
}
