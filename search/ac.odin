package search

// ============================================================================
// ac.odin — Aho-Corasick 多模式自动机
//
// 职责：给"模式很多"的场景提供**与模式数无关**的扫描代价。
//
// 为什么需要它：`multi_match` 是"每个位置 × 每个模式"，代价 O(n × Σ|pat|)。
// 实测（100 MiB 合成数据，`xrep --bench` 的 A3 组）：
//     2 个模式 1163 MB/s → 8 个 716 → 16 个 346 → 32 个 198 → 64 个 114
// 模式数翻一倍，吞吐几乎砍一半。AC 把模式编译成一台自动机，扫描时每字节只做
// 一次查表，代价 O(n × 命中数) —— 模式数从个位数涨到几十也不掉速。
//
// 结构：
//   * 构建：先插成 trie，再 BFS 补 fail 指针，顺手把 trie 补成**完全转移表**
//     （无转移的字节直接填 goto(fail, c)），于是扫描期没有"沿 fail 链回退"
//     的循环，热路径就是一次查表。
//   * 输出链接 `out`：沿 fail 链最近的"有模式在此结束"的状态。扫描时顺着
//     out → fail → out ... 就能把"在当前位置结尾的所有模式"一次性取完。
//
// 字母表压缩（关键，踩过坑）：转移表**不能**照搬 256 列。那样每状态 1 KiB，
// 几十个模式就几百 KB，扫描时每字节一次跨表随机访存 → L2 未命中约 14 周期，
// 实测 4 模式反而从 1038 MB/s 掉到 231 MB/s（比 multi_match 还慢 4 倍）。
// 改为两遍构建：先扫出模式里真正出现过的字节，压成 σ 个符号，表宽变成
// (σ+1) 列。文本模式的 σ 通常 20~30 → 每状态约 100 B，整张表进得了 L1，
// 且"不出现在任何模式里的字节"直接映射到符号 0，从任何状态都回到根。
//
// 输出顺序（关键契约）：必须与 `multi_match` **逐条一致**，即
//   (起点偏移升序, 模式序号升序)。
// AC 天然按"**结束**位置"给结果，而不同长度的模式在同一结束位置对应不同起点，
// 后结束的长模式起点反而可能更小 —— 所以不能"发现即输出"，见 multi_ac_match
// 里的延迟线。归并（merge_ordered_matches）假定各分片列表已按 offset 升序，
// 顺序一乱，最终输出顺序就会变。
//
// 依赖：lib/base.odin（Match_Ctx / Match_Result / lower_table）。
// 内存：自动机**每次调用重建**（分片 2 MiB，重建代价远小于扫描），
//       因此没有跨线程共享的可变状态。
// ============================================================================

import "xrep:lib"

// 延迟线里的待输出条目：同一"起点"可能被多个模式命中，需按模式序号排序。
ac_pending :: struct {
    plen: u32,
    k:    u32,
}

// 自动机。
//   goto_tbl — 行优先的完全转移表：goto_tbl[state * width + sym]
//              sym = 0 表示"该字节不出现在任何模式里"，从任何状态都回到根 0
//   width    — σ + 1（σ = 模式里出现过的不同字节数）
AC :: struct {
    goto_tbl:  [dynamic]i32,
    width:     int,
    fail:      [dynamic]i32, // fail[s] 的深度一定小于 s（BFS 序）
    out:       [dynamic]i32, // 输出链接：沿 fail 链最近的"有输出"状态，0 = 无
    term_head: [dynamic]i32, // 每个状态上"直接结束的模式"链表头，-1 = 无
    t_pat:     [dynamic]u32, // 链表节点：模式序号
    t_next:    [dynamic]i32, // 链表节点：下一个节点，-1 = 尾
    sym:       [256]u16, // 字节 → 符号（1..σ；0 = 不在任何模式里）
    pat_len:   [dynamic]u32, // 模式序号 → 字节长度（按模式表下标；空模式为 0）
    max_len:   uint, // 最长模式的字节数（决定延迟线的长度）
}

// ---------------------------------------------------------------------------
// 构建
// ---------------------------------------------------------------------------

// 追加一个状态：转移表整行补 0（0 在 trie 阶段表示"无转移"）。
ac_new_state :: proc(ac: ^AC) -> i32 {
    append(&ac.fail, 0)
    append(&ac.out, 0)
    append(&ac.term_head, -1)
    for _ in 0..<ac.width {
        append(&ac.goto_tbl, 0)
    }
    return i32(len(ac.fail)) - 1
}

// 按 ctx 里的模式表（pattern + extra）构建自动机。空模式跳过（与 multi_match 一致）。
ac_build :: proc(ctx: lib.Match_Ctx) -> AC {
    ac: AC

    // ---- 1) 第一遍：收集字母表，压成 σ 个符号 ----
    present: [256]bool
    count := lib.ctx_pattern_count(ctx)
    for k in 0..<count {
        pat := lib.ctx_pattern_at(ctx, k)
        append(&ac.pat_len, u32(len(pat)))
        if len(pat) == 0 {
            continue
        }
        if uint(len(pat)) > ac.max_len {
            ac.max_len = uint(len(pat))
        }
        for i in 0..<len(pat) {
            c := pat[i]
            if ctx.case_insensitive {
                c = lib.lower_table[c]
            }
            present[c] = true
        }
    }
    sigma := 0
    for c in 0..<256 {
        if present[c] {
            sigma += 1
            ac.sym[c] = u16(sigma)
        }
    }
    ac.width = sigma + 1

    // ---- 2) 第二遍：插 trie ----
    ac_new_state(&ac) // 根（状态 0）
    for k in 0..<count {
        pat := lib.ctx_pattern_at(ctx, k)
        if len(pat) == 0 {
            continue
        }
        s := i32(0)
        for i in 0..<len(pat) {
            c := pat[i]
            if ctx.case_insensitive {
                c = lib.lower_table[c]
            }
            sy := int(ac.sym[c])
            idx := int(s) * ac.width + sy
            nxt := ac.goto_tbl[idx]
            if nxt == 0 {
                nxt = ac_new_state(&ac)
                // append 可能搬走 goto_tbl，下标必须重新算
                ac.goto_tbl[int(s) * ac.width + sy] = nxt
            }
            s = nxt
        }
        // 头插：同一状态结束的多个模式成链（重复模式也各占一个节点）
        append(&ac.t_pat, u32(k))
        append(&ac.t_next, ac.term_head[s])
        ac.term_head[s] = i32(len(ac.t_pat)) - 1
    }

    // ---- 3) BFS：补 fail 指针 + 补齐完全转移表 + 算输出链接 ----
    // 根这一行先处理：根没有 fail，缺的转移就是回到自己（已是 0）。
    queue := make([dynamic]i32, 0, len(ac.fail))
    defer delete(queue)
    for sy in 1..<ac.width {
        t := ac.goto_tbl[sy] // 根在 0 行
        if t != 0 {
            ac.fail[t] = 0
            append(&queue, t)
        }
    }
    for qi := 0; qi < len(queue); qi += 1 {
        s := queue[qi]
        fs := ac.fail[s]
        base := int(s) * ac.width
        fbase := int(fs) * ac.width
        // BFS 保证 fail[s] 这一行在 s 之前已经补齐，可以放心读
        for sy in 1..<ac.width {
            t := ac.goto_tbl[base + sy]
            if t == 0 {
                ac.goto_tbl[base + sy] = ac.goto_tbl[fbase + sy]
            } else {
                ac.fail[t] = ac.goto_tbl[fbase + sy]
                append(&queue, t)
            }
        }
        if ac.term_head[s] >= 0 {
            ac.out[s] = s
        } else {
            ac.out[s] = ac.out[fs]
        }
    }
    return ac
}

ac_destroy :: proc(ac: ^AC) {
    delete(ac.goto_tbl)
    delete(ac.fail)
    delete(ac.out)
    delete(ac.term_head)
    delete(ac.t_pat)
    delete(ac.t_next)
    delete(ac.pat_len)
}

// ---------------------------------------------------------------------------
// 启用判据
// ---------------------------------------------------------------------------

// 模式数少于这个值时不值得建自动机。阈值来自**真实文本**实测
// （100 MiB 源码文本，`-f` 送入 N 个词，单线程 --count）：
//
//   N       multi_match    multi_ac
//   4       0.16 s         0.50 s
//   8       0.34 s         0.52 s
//   16      0.68 s         0.53 s   ← 交叉点
//   32      1.31 s         0.54 s
//
// multi_match 的每字节成本随模式数线性增长（首字节位图只挡住"首字节不在
// 集合里"的位置，真实文本里挡不住多少），AC 则基本恒定。合成数据上曾测到
// 相反结论 —— 那是数据全 0xFF、一个字节都不在字母表里，位图 100% 拒绝，
// 属于 multi_match 的极端有利情形，不能当依据。
AC_MIN_PATTERNS :: 16

// 状态数（≈ 所有模式的总字节数）上限：单状态 (σ+1)×4 B，这条线把单次构建的
// 内存开销压在可控范围内。超过就退回 multi_match。
AC_MAX_STATES :: 4096

ac_worth_it :: proc(ctx: lib.Match_Ctx) -> bool {
    count := lib.ctx_pattern_count(ctx)
    if count < AC_MIN_PATTERNS {
        return false
    }
    total := 0
    for k in 0..<count {
        total += len(lib.ctx_pattern_at(ctx, k))
    }
    return total <= AC_MAX_STATES
}

// ---------------------------------------------------------------------------
// 扫描
// ---------------------------------------------------------------------------

// 倒出"起点为 s"的桶：桶内按模式序号升序（插入排序，桶通常只有 1~2 条）。
// slot 是环上下标（由调用方维护游标，**不做取模**：`s % slots` 是运行期除法，
// 每字节一次会直接吃掉 20+ 周期，见文件头的性能注记）。
ac_flush_slot :: proc(ring: [][dynamic]ac_pending, slot: uint, s: uint, results: ^[dynamic]lib.Match_Result) {
    b := &ring[slot]
    if len(b^) == 0 {
        return
    }
    if len(b^) > 1 {
        for i in 1..<len(b^) {
            v := b^[i]
            j := i
            for j > 0 && b^[j - 1].k > v.k {
                b^[j] = b^[j - 1]
                j -= 1
            }
            b^[j] = v
        }
    }
    for pd in b^ {
        append(results, lib.Match_Result{offset = u64(s), pat_len = pd.plen})
    }
    clear(&b^)
}

// Aho-Corasick 扫描。产出顺序与 multi_match 逐条一致。
//
// 延迟线：命中先按**起点**分桶，等扫过 `起点 + max_len - 1` 再倒出 —— 那时长
// 模式的结束位置也处理完了，桶里不可能再有新成员。环形桶数组只需 max_len+1 个
// 槽：任意时刻未倒出的起点跨度不超过 max_len（起点 s 最晚在 i = s+max_len-1
// 被发现，而 s-max_len+1 此时已经倒出）。
//
// 环上游标 offset 是单调递增的"绝对位置"，`slot = flush_pos - flush_slot_base`
// 由调用方维护成 0..slots-1 的游标。命中那条路径用**相对偏移**算槽位：
// `start - flush_pos` 天然落在 [0, slots)（起点不会早于已倒出游标），
// 于是全程没有除法，也没有取模。
multi_ac_match :: proc(data: []u8, ctx: lib.Match_Ctx, progress: ^lib.Progress) -> []lib.Match_Result {
    results := make([dynamic]lib.Match_Result, 0, MATCH_INITIAL_CAP)
    n := uint(len(data))
    ac := ac_build(ctx)
    defer ac_destroy(&ac)
    // 没有非空模式（或空数据）：自动机只有根，扫不出东西。
    if ac.max_len == 0 || n == 0 {
        lib.progress_add(progress, u64(len(data)))
        return results[:]
    }

    slots := ac.max_len + 1
    ring := make([][dynamic]ac_pending, slots)
    // defer 写在函数体顶层：Odin 的 defer 是块作用域，写进循环/分支会提前执行。
    defer {
        for j in 0..<len(ring) {
            delete(ring[j])
        }
        delete(ring)
    }

    // 把热路径要用的字段取到局部：每次 `ac.xxx` 都是一次间接寻址。
    width := ac.width
    goto_tbl := ac.goto_tbl[:]
    out_link := ac.out[:]
    fail := ac.fail[:]
    term_head := ac.term_head[:]
    t_pat := ac.t_pat[:]
    t_next := ac.t_next[:]
    pat_len := ac.pat_len[:]
    sym := ac.sym
    max_len := ac.max_len
    ci := ctx.case_insensitive

    st := i32(0)
    flush_pos := uint(0) // 下一个要倒出的起点
    slot := uint(0) // flush_pos 对应的环上下标
    for i := uint(0); i < n; i += 1 {
        c := data[i]
        if ci {
            c = lib.lower_table[c]
        }
        st = goto_tbl[int(st) * width + int(sym[c])]
        u := out_link[st]
        if u != 0 {
            // 顺着输出链接取走"在当前位置结尾的所有模式"
            for u != 0 {
                for ti := term_head[u]; ti >= 0; ti = t_next[ti] {
                    k := t_pat[ti]
                    plen := pat_len[k]
                    start := i + 1 - uint(plen) // AC 给的是结束位置，还原成起点
                    // start >= flush_pos 且 start - flush_pos < max_len < slots
                    idx := slot + (start - flush_pos)
                    if idx >= slots {
                        idx -= slots
                    }
                    append(&ring[idx], ac_pending{plen = plen, k = k})
                }
                u = out_link[fail[u]]
            }
        }
        // 起点 flush_pos 的桶到此才能保证完整：它最晚的命中在 i = flush_pos+max_len-1
        if i + 1 >= max_len {
            // 先就地判空再调用：绝大多数桶是空的（命中密度远低于 1），
            // 而函数调用 + 取地址在这里是每字节一次的开销。
            if len(ring[slot]) > 0 {
                ac_flush_slot(ring, slot, flush_pos, &results)
            }
            flush_pos += 1
            slot += 1
            if slot == slots {
                slot = 0
            }
        }
    }
    // 收尾：flush_pos 之后还剩 max_len 个（或 n 个，当 n < max_len）桶没倒。
    for flush_pos < n {
        ac_flush_slot(ring, slot, flush_pos, &results)
        flush_pos += 1
        slot += 1
        if slot == slots {
            slot = 0
        }
    }

    lib.progress_add(progress, u64(len(data)))
    return results[:]
}
