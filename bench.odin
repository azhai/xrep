package main

// ============================================================================
// bench.odin — 微基准（`xrep --bench`）
//
// 职责：在内存生成的 100 MiB 合成数据上，对三种匹配实现跑固定轮数，
//       输出吞吐量（MB/s），用于比较算法相对性能。
//
// 依赖：core:fmt、core:mem、core:time。
// 说明：数据由 `i % 256` 生成（近似均匀分布），在偏移 1000 处埋入 "test"
//       作为唯一真实命中；每轮结束释放命中数组（堆分配，见 ADR 0004），
//       使测量聚焦于"扫描"而非"分配"。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:time"

run_bench :: proc() {
    fmt.println("==== Benchmark Matchers ====")
    DATA_SIZE :: mem.Megabyte * 100
    data := make([]u8, DATA_SIZE)
    for i in 0..<len(data) {
        data[i] = u8(i % 256)
    }
    copy(data[1000:1004], s2b("test"))
    ctx := Match_Ctx{pattern = s2b("test"), case_insensitive = false}
    p: Progress
    progress_init(&p, u64(DATA_SIZE), false, false)

    // 单个算法的测量：固定轮数，按 (数据量×轮数)/耗时 计算吞吐。
    // 说明：命中数组由 matcher 在堆上分配（ADR 0004），因此每轮结束需要释放，
    //       避免轮次间内存累积影响计时公平性（原先靠 arena_free_all 一次性回收）。
    bench_one :: proc(name: string, m: Match_Fn, data: []u8, ctx: Match_Ctx, p: ^Progress) {
        start := time.now()
        ROUNDS :: 10
        for _ in 0..<ROUNDS {
            res := m(data, ctx, p)
            delete(res)
        }
        dur := time.since(start)
        sec := f64(dur) / f64(time.Second)
        mb_per_sec := (f64(DATA_SIZE) * f64(ROUNDS)) / (1024.0 * 1024.0) / sec
        fmt.printf("%-16s %.2f MB/s\n", name, mb_per_sec)
    }

    bench_one("single_match", single_match, data, ctx, &p)
    bench_one("bndm_match", bndm_match, data, ctx, &p)
    bench_one("naive_match", naive_match, data, ctx, &p)
    fmt.println()
}
