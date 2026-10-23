package app

// ============================================================================
// bench.odin — 微基准（`xrep --bench`）
//
// 职责：两组测量。
//
//   A. 匹配算法吞吐 —— 按**模式长度 / 大小写 / 模式个数**分组，覆盖 alg_table
//      的每一档：1（single）、2..16（bndm）、17..64（naive）、>64（回退 naive），
//      外加 multi_match（`-e` / `-f`）。每组都经由 `select_matcher_for` 分派，
//      因此打印出的算法名就是**实际跑的那个**，顺带验证长度分派。
//
//   B. 端到端线程伸缩 —— 直接跑 `scan_region_parallel`（任务池 + worker +
//      输出队列 + 归并的完整路径），报告 1/2/4/8 线程的吞吐与相对加速比。
//      单看 A 组只能说明"算法有多快"，B 组才能说明"多线程有没有用"。
//
// 方法：每个 case 跑固定轮数，取**最快的一轮**作为代表值。别的负载、调度抖动
//       与缓存抖动只会让结果变慢，不会让它变快 —— 取最快一轮因此是最抗噪的口径。
//       命中数组由 matcher 在堆上分配（ADR 0004），每轮结束立即 delete，
//       使测量聚焦"扫描"而非"分配"。
//
// 数据：A 组是 u8(i % 256)，近似均匀的周期性数据（长度 ≤256 的模式每 256 字节
//       必然复现一次，命中密度 ≈ 1/256）。B 组是全 0xFF、每 64 KiB 埋一处命中的
//       稀疏数据 —— 稀疏是为了让测量聚焦扫描编排与内存带宽：出队是 O(队列长度)
//       的整体左移，密集命中会让输出队列主导结果，那是另一个话题。
//
// 依赖：core:fmt、core:mem、core:time。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:time"
import "xrep:lib"
import "xrep:search"

// A 组数据量与轮数。轮数比原先的 10 少，取"最快一轮"后噪声更小。
BENCH_DATA_SIZE :: mem.Megabyte * 100
BENCH_ROUNDS :: 5

// B 组：数据量、命中间距与轮数
BENCH_SPARSE_SIZE :: mem.Megabyte * 64
BENCH_SPARSE_HIT_BYTES :: 64 * 1024
BENCH_SCAN_ROUNDS :: 3

// 算法名（用于在输出里如实标出 select_matcher_for 选中的实现）
alg_name :: proc(m: lib.Match_Fn) -> string {
    if m == search.single_match {
        return "single_match"
    }
    if m == search.bndm_match {
        return "bndm_match"
    }
    if m == search.memchr_match {
        return "memchr_match"
    }
    if m == search.naive_match {
        return "naive_match"
    }
    if m == search.multi_match {
        return "multi_match"
    }
    return "?"
}

// 跑一轮算法并计时。命中数组用后即删（每轮重新分配，测量聚焦扫描本身）。
bench_round :: proc(m: lib.Match_Fn, data: []u8, ctx: lib.Match_Ctx, p: ^lib.Progress) -> time.Duration {
    start := time.now()
    res := m(data, ctx, p)
    delete(res)
    return time.since(start)
}

// 跑一轮端到端并行扫描并计时（返回值由主线程 delete，用的是主线程的分配器）。
bench_scan_round :: proc(data: []u8, o: lib.Scan_Options, label: string) -> time.Duration {
    start := time.now()
    hits := scan_region_parallel(data, o, label)
    delete(hits)
    return time.since(start)
}

// 一个 case：固定轮数 + 取最快一轮 + 打印 MB/s。
bench_case :: proc(label: string, m: lib.Match_Fn, data: []u8, ctx: lib.Match_Ctx, p: ^lib.Progress) {
    best := bench_round(m, data, ctx, p)
    for _ in 1..<BENCH_ROUNDS {
        d := bench_round(m, data, ctx, p)
        if d < best {
            best = d
        }
    }
    mib := f64(len(data)) / (1024.0 * 1024.0)
    mbps := mib / (f64(best) / f64(time.Second))
    // 注意：Odin 的 fmt 对数字宽度默认补 **0**（`%9.2f` 会打印 001355.42）。
    // 右对齐要用空格填充标志，即格式串里的 `% 9.2f`（' ' 紧跟 %）。
    fmt.printf("  %-8s %-13s % 9.2f MB/s\n", label, alg_name(m), mbps)
}

// 一个 case 的自动分派版本：算法由 select_matcher_for 按 ctx 选出。
bench_ctx :: proc(label: string, data: []u8, ctx: lib.Match_Ctx, p: ^lib.Progress) {
    bench_case(label, search.select_matcher_for(ctx), data, ctx, p)
}

// B 组：端到端线程伸缩（任务池 + worker + 输出队列 + 归并的完整路径）。
bench_scan_scaling :: proc(data: []u8, ctx: lib.Match_Ctx, label: string) {
    thread_counts := []uint{1, 2, 4, 8}
    mib := f64(len(data)) / (1024.0 * 1024.0)
    base: f64 = 0
    for n in thread_counts {
        // quiet=true ⇒ legacy_output 为 false ⇒ 进度条关闭、输出线程 silent，
        // 因此这一组测量全程无 stdout 噪声。
        o := lib.Scan_Options{
            ctx = ctx,
            after = 0,
            before = 0xFFFFFFFFFFFFFFFF,
            thread_count = n,
            quiet = true,
        }
        best := bench_scan_round(data, o, label)
        for _ in 1..<BENCH_SCAN_ROUNDS {
            d := bench_scan_round(data, o, label)
            if d < best {
                best = d
            }
        }
        mbps := mib / (f64(best) / f64(time.Second))
        if base == 0 {
            base = mbps
        }
        fmt.printf("  %d thread(s)  % 14.2f MB/s  % 5.2fx\n", n, mbps, mbps / base)
    }
}

run_bench :: proc() {
    fmt.println("==== Benchmark xrep ====")
    fmt.printf(
        "A: %d MiB synthetic, %d rounds per case (best round reported)\n",
        BENCH_DATA_SIZE / mem.Megabyte,
        BENCH_ROUNDS,
    )
    fmt.printf("B: %d MiB sparse, %d rounds per case, threads 1/2/4/8\n\n", BENCH_SPARSE_SIZE / mem.Megabyte, BENCH_SCAN_ROUNDS)

    // ---- 数据 ----
    data := make([]u8, BENCH_DATA_SIZE)
    defer delete(data)
    for i in 0..<len(data) {
        data[i] = u8(i % 256)
    }
    copy(data[1000:1004], lib.s2b("test"))
    p: lib.Progress
    lib.progress_init(&p, u64(len(data)), false, false)

    // ---- A1. 单模式，按长度分档（1 / 2..16 / 17..64 / >64 回退）----
    // 长模式的字节直接取自数据自身，保证一定存在，且落在 256 周期之外的位置
    // 不会影响别的 case。
    fmt.println("-- A1. single pattern, case sensitive --")
    bench_ctx("1B", data, lib.Match_Ctx{pattern = lib.s2b("t")}, &p)
    bench_ctx("2B", data, lib.Match_Ctx{pattern = lib.s2b("te")}, &p)
    bench_ctx("4B", data, lib.Match_Ctx{pattern = lib.s2b("test")}, &p)
    bench_ctx("16B", data, lib.Match_Ctx{pattern = data[5000:5016]}, &p)
    bench_ctx("17B", data, lib.Match_Ctx{pattern = data[5000:5017]}, &p)
    bench_ctx("64B", data, lib.Match_Ctx{pattern = data[5000:5064]}, &p)
    bench_ctx("128B", data, lib.Match_Ctx{pattern = data[5000:5128]}, &p) // 表外 → 回退 naive

    // ---- A2. 大小写不敏感（每字节多一次查表）----
    fmt.println("\n-- A2. single pattern, case insensitive (-i) --")
    bench_ctx("4B -i", data, lib.Match_Ctx{pattern = lib.s2b("TEST"), case_insensitive = true}, &p)

    // ---- A3. 多模式：命中集合随模式数线性增长 ----
    fmt.println("\n-- A3. multi pattern (-e / -f) --")
    multi1 := lib.Match_Ctx{pattern = lib.s2b("test"), extra = [][]u8{data[6000:6004]}}
    bench_ctx("2 pat", data, multi1, &p)
    multi3 := lib.Match_Ctx{
        pattern = lib.s2b("test"),
        extra   = [][]u8{data[6000:6004], data[7000:7004], data[8000:8004]},
    }
    bench_ctx("4 pat", data, multi3, &p)

    // ---- B. 端到端线程伸缩 ----
    fmt.printf("\n-- B. end-to-end scan_region_parallel (pattern 'test', 1 hit / %d B) --\n", BENCH_SPARSE_HIT_BYTES)
    sparse := make([]u8, BENCH_SPARSE_SIZE)
    defer delete(sparse)
    for i in 0..<len(sparse) {
        sparse[i] = 0xFF
    }
    for off := 0; off + 4 <= len(sparse); off += BENCH_SPARSE_HIT_BYTES {
        copy(sparse[off:off + 4], lib.s2b("test"))
    }
    bench_scan_scaling(sparse, lib.Match_Ctx{pattern = lib.s2b("test")}, "bench")

    fmt.println("\n==== bench done ====")
}