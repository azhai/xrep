package app

// ============================================================================
// scan_test.odin — 单文件扫描端到端单元测试
//
// 覆盖：命中计数、多线程与单线程一致性、跨分片归并后偏移有序、
//       --after/--before 区间过滤、--limit / -m 语义、dump / dump-prefix 落盘、
//       --skip-empty / --dump-append / --max-size、空文件快速跳过、
//       多模式端到端、--stats 累加、输出模式判定（legacy_output /
//       line_index_needed）、分片重叠窗口的重复上报契约，
//       以及文件不存在时的错误返回。
//
// 说明：所有用例以 quiet=true 调用（关闭进度条与统计输出），
//       使断言聚焦返回值与落盘内容，测试输出保持干净。
//       临时文件统一使用 /tmp/xrep_ut_* 前缀。
//
// 为什么没有"输出文本"断言：输出线程与汇总行都写进程级 stdout，
// 而 `odin test` 默认并行跑用例 —— 捕获/重定向 fd 1 会与其它用例互相污染，
// 属于用不可靠的断言换覆盖面。输出文本改由 README「行为验收矩阵」的外部
// 命令矩阵把关，本文件只断言**返回值、落盘内容、统计累加**这些无歧义的可观察量。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "xrep:lib"

// 扫描用的示例数据：一段文本中埋入 3 处 "test"（偏移 6 / 17 / 28），共 32 字节。
SCAN_SAMPLE :: "hello test world\ntest again\ntest"

// 全局表初始化说明：`lower_table` 由 `@(init)` 在进程启动时填充，`alg_table`
// 是编译期常量 —— main 与 `odin test` 走同一条启动路径，用例**无需**手动初始化。
// （历史上这里有个 scan_init_globals() 辅助函数：因为 `odin test` 不执行 main，
//   每个用例都得自己补一次初始化，漏掉会让大小写不敏感匹配把所有字节视为相等。
//   改用 `@(init)` 后该辅助函数已删除。）
// 写入示例数据并返回路径；调用方负责 os.remove。
scan_write_sample :: proc(t: ^testing.T, path: string) {
    // 显式经由 string 形参再转 []byte：避免 os.write_entire_file 的
    // 重载歧义（[]byte 与 string 两个版本对无类型常量均匹配）。
    content: string = SCAN_SAMPLE
    err := os.write_entire_file(path, transmute([]byte)content)
    testing.expect(t, err == nil, "写入测试文件应成功")
}

// 构造 quiet 的扫描选项：测试聚焦返回值与落盘内容，不夹杂统计输出。
// 全区间（after=0 / before=u64 上界），可按需覆盖字段。
scan_opts :: proc(ctx: lib.Match_Ctx, thread_count: uint = 1) -> lib.Scan_Options {
    return lib.Scan_Options{
        ctx = ctx,
        after = 0,
        before = 0xFFFFFFFFFFFFFFFF,
        thread_count = thread_count,
        quiet = true,
    }
}

@(test)
test_scan_file_basic_count :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_basic.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    hits, dump_ok := scan_file(path, scan_opts(ctx))
    testing.expect_value(t, hits, uint(3))
    testing.expect(t, dump_ok, "未落盘时 dump_ok 应为 true")

    // 大小写不敏感：模式 "TEST" 同样命中 3 处
    ctx_i := lib.Match_Ctx{pattern = lib.s2b("TEST"), case_insensitive = true}
    hits_i, _ := scan_file(path, scan_opts(ctx_i))
    testing.expect_value(t, hits_i, uint(3))
    // 大小写敏感：模式 "TEST" 命中 0 处
    ctx_c := lib.Match_Ctx{pattern = lib.s2b("TEST"), case_insensitive = false}
    hits_c, _ := scan_file(path, scan_opts(ctx_c))
    testing.expect_value(t, hits_c, uint(0))
}

@(test)
test_scan_file_thread_counts_agree :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_threads.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // 行为变更（ADR 0002）：thread_count 0 不再静默产出 0 命中，
    // 而是按防御性夹取当作 1 个 worker 处理 —— 0 个 worker 时任务无人消费。
    hits0, _ := scan_file(path, scan_opts(ctx, 0))
    testing.expect_value(t, hits0, uint(3))

    thread_counts := []uint{1, 2, 4, 8}
    for n in thread_counts {
        hits, _ := scan_file(path, scan_opts(ctx, n))
        testing.expectf(t, hits == 3, "threads=%d 时应命中 3 处，实际 %d", n, hits)
    }
}

@(test)
test_scan_file_range_filter :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_range.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // 全区间：3 处（偏移 6 / 17 / 28）
    h1, _ := scan_file(path, scan_opts(ctx))
    testing.expect_value(t, h1, uint(3))
    // 只留 >= 10：命中 17 / 28
    o2 := scan_opts(ctx); o2.after = 10
    h2, _ := scan_file(path, o2)
    testing.expect_value(t, h2, uint(2))
    // 只留 <= 10：命中 6
    o3 := scan_opts(ctx); o3.before = 10
    h3, _ := scan_file(path, o3)
    testing.expect_value(t, h3, uint(1))
    // 闭区间边界：after == before == 17 应恰好命中 1 处
    o4 := scan_opts(ctx); o4.after = 17; o4.before = 17
    h4, _ := scan_file(path, o4)
    testing.expect_value(t, h4, uint(1))
    // 空区间
    o5 := scan_opts(ctx); o5.after = 100; o5.before = 200
    h5, _ := scan_file(path, o5)
    testing.expect_value(t, h5, uint(0))
}

@(test)
test_scan_file_limit_does_not_change_returned_count :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_limit.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // 契约语义（README 已知行为#3，刻意保留）：--limit 只截断 pretty 汇总，
    // 返回值仍是过滤后的完整命中数，--count/--dump 也不受影响。
    full, _ := scan_file(path, scan_opts(ctx))
    o := scan_opts(ctx); o.limit = 1
    limited, _ := scan_file(path, o)
    testing.expect_value(t, full, uint(3))
    testing.expect_value(t, limited, uint(3))
}

@(test)
test_scan_file_dump_path :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_dump.bin"
    dump :: "/tmp/xrep_ut_scan_dump_offsets.txt"
    scan_write_sample(t, path)
    defer os.remove(path)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    o := scan_opts(ctx); o.dump_path = dump
    hits, dump_ok := scan_file(path, o)
    testing.expect_value(t, hits, uint(3))
    testing.expect(t, dump_ok, "正常落盘应返回 true")

    data, err := os.read_entire_file(dump, context.allocator)
    testing.expect(t, err == nil, "dump 文件应存在")
    defer delete(data)
    // 十进制、升序、每行一个偏移
    testing.expect_value(t, transmute(string)data, "6\n17\n28\n")

    // 十六进制变体
    dump_hex :: "/tmp/xrep_ut_scan_dump_hex.txt"
    defer os.remove(dump_hex)
    oh := scan_opts(ctx); oh.dump_path = dump_hex; oh.offset_hex = true
    _, _ = scan_file(path, oh)
    dh, errh := os.read_entire_file(dump_hex, context.allocator)
    testing.expect(t, errh == nil)
    defer delete(dh)
    testing.expect_value(t, transmute(string)dh, "0x6\n0x11\n0x1c\n")
}

@(test)
test_scan_file_dump_prefix_sanitizes_path :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_pfx.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    // 契约变更（ADR 0002）：dump-prefix 输出名中的路径分隔符会被清洗为 '_'，
    // 因此输入路径里的 '/' 不再变成子目录层级，目标目录只需存在一层。
    outdir :: "/tmp/xrep_ut_scan_pfxdir"
    // sanitize("/tmp/xrep_ut_scan_pfx.bin") == "_tmp_xrep_ut_scan_pfx.bin"
    expected :: "/tmp/xrep_ut_scan_pfxdir/_tmp_xrep_ut_scan_pfx.bin.txt"
    os.remove_all(outdir)
    testing.expect(t, os.make_directory_all(outdir) == nil, "应能创建输出目录")
    defer os.remove_all(outdir)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    o := scan_opts(ctx); o.dump_prefix = outdir + "/"
    hits, dump_ok := scan_file(path, o)
    testing.expect_value(t, hits, uint(3))
    testing.expect(t, dump_ok, "前缀落盘应成功")

    data, err := os.read_entire_file(expected, context.allocator)
    testing.expect(t, err == nil, "清洗后的 dump 文件应存在")
    defer delete(data)
    testing.expect_value(t, transmute(string)data, "6\n17\n28\n")
}

@(test)
test_scan_file_dump_prefix_relative_dot_path :: proc(t: ^testing.T) {
    // 回归：'./x.bin' 这类相对路径过去会拼出 "<prefix>./x.bin.txt" 而写入失败
    // （中间的 './' 需要同名目录）。清洗后应正常产出文件。
    dir :: "/tmp/xrep_ut_scan_pfxrel"
    os.remove_all(dir)
    testing.expect(t, os.make_directory_all(dir) == nil, "应能创建输出目录")
    defer os.remove_all(dir)

    data_path := dir + "/./inner.bin"
    scan_write_sample(t, data_path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    o := scan_opts(ctx); o.dump_prefix = dir + "/out_"
    hits, dump_ok := scan_file(data_path, o)
    testing.expect_value(t, hits, uint(3))
    testing.expect(t, dump_ok, "含 './' 的路径清洗后应能落盘")

    // sanitize("/tmp/.../inner.bin" 中的 '/') → '_'，最终文件名不含任何分隔符
    expected := dir + "/out__tmp_xrep_ut_scan_pfxrel_._inner.bin.txt"
    content, err := os.read_entire_file(expected, context.allocator)
    testing.expect(t, err == nil, "清洗后的 dump 文件应存在")
    if err == nil {
        defer delete(content)
        testing.expect_value(t, transmute(string)content, "6\n17\n28\n")
    }
}

@(test)
test_scan_file_dump_append :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_append.bin"
    dump :: "/tmp/xrep_ut_scan_append.txt"
    scan_write_sample(t, path)
    defer os.remove(path)
    defer os.remove(dump)
    os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // 第一次覆盖写
    o1 := scan_opts(ctx); o1.dump_path = dump
    _, ok1 := scan_file(path, o1)
    testing.expect(t, ok1)
    // 第二次追加写：内容应翻倍
    o2 := scan_opts(ctx); o2.dump_path = dump; o2.dump_append = true
    _, ok2 := scan_file(path, o2)
    testing.expect(t, ok2)

    data, err := os.read_entire_file(dump, context.allocator)
    testing.expect(t, err == nil)
    defer delete(data)
    testing.expect_value(t, transmute(string)data, "6\n17\n28\n6\n17\n28\n")
}

@(test)
test_scan_file_skip_empty :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_skipempty.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    dump :: "/tmp/xrep_ut_scan_skipempty.txt"
    os.remove(dump)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("no-such-pattern-xyz"), case_insensitive = false}
    // 不开启 skip_empty：既有行为是创建空文件
    o1 := scan_opts(ctx); o1.dump_path = dump
    h1, _ := scan_file(path, o1)
    testing.expect_value(t, h1, uint(0))
    // 只判存在性时用 os.exists（os.stat 会把路径 clone 到传入的分配器上，
    // 且返回的 File_Info 需 file_info_delete 才不泄漏 —— 这里不需要那么重）。
    testing.expect(t, os.exists(dump), "默认应创建空 dump 文件")

    // 开启 skip_empty：0 命中时不落盘
    os.remove(dump)
    o2 := scan_opts(ctx); o2.dump_path = dump; o2.skip_empty = true
    h2, ok2 := scan_file(path, o2)
    testing.expect_value(t, h2, uint(0))
    testing.expect(t, ok2, "跳过落盘不算失败")
    testing.expect(t, !os.exists(dump), "skip_empty 时不应创建文件")
}

@(test)
test_scan_file_max_size_skips :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_maxsize.bin"
    scan_write_sample(t, path) // 32 字节
    defer os.remove(path)

    dump :: "/tmp/xrep_ut_scan_maxsize.txt"
    os.remove(dump)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // 上限 10 字节 < 文件 32 字节 → 跳过：0 命中，且不落盘
    o1 := scan_opts(ctx); o1.dump_path = dump; o1.max_size = 10
    h1, ok1 := scan_file(path, o1)
    testing.expect_value(t, h1, uint(0))
    testing.expect(t, ok1, "主动跳过不算失败")
    testing.expect(t, !os.exists(dump), "被跳过的文件不应落盘")

    // 上限 100 字节 > 文件 32 字节 → 正常扫描
    o2 := scan_opts(ctx); o2.max_size = 100
    h2, _ := scan_file(path, o2)
    testing.expect_value(t, h2, uint(3))
}

@(test)
test_scan_file_empty_file_fast_path :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_empty.bin"
    dump :: "/tmp/xrep_ut_scan_empty.txt"
    // 空文件：快速跳过并行路径，但统计与落盘语义保持不变
    testing.expect(t, os.write_entire_file(path, transmute([]byte)string("")) == nil)
    defer os.remove(path)
    os.remove(dump)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    o := scan_opts(ctx); o.dump_path = dump
    hits, dump_ok := scan_file(path, o)
    testing.expect_value(t, hits, uint(0))
    testing.expect(t, dump_ok)
    // 既有语义保持：空结果集仍创建（空）dump 文件
    data, err := os.read_entire_file(dump, context.allocator)
    testing.expect(t, err == nil, "空文件仍应创建 dump 文件")
    if err == nil {
        defer delete(data)
        testing.expect_value(t, len(data), 0)
    }
}

@(test)
test_scan_file_missing_file_returns_zero :: proc(t: ^testing.T) {
    // 边界：文件不存在 → 向 stderr 打印错误并返回 0（不崩溃、不阻塞）
    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    hits, dump_ok := scan_file("/tmp/xrep_ut_scan_nope_5f2c.bin", scan_opts(ctx, 4))
    testing.expect_value(t, hits, uint(0))
    // 读失败不是"落盘失败"，不应把退出码拉成非 0（保持既有容错）
    testing.expect(t, dump_ok)
}

@(test)
test_scan_file_dump_write_failure_reports_false :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_dumpfail.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    // dump 目标目录不存在 → dump_ok=false（供 main 决定非零退出码）
    o := scan_opts(ctx); o.dump_path = "/tmp/xrep_ut_no_such_dir_9b/out.txt"
    hits, dump_ok := scan_file(path, o)
    testing.expect_value(t, hits, uint(3))
    testing.expect(t, !dump_ok, "写入失败应返回 dump_ok=false")
}

@(test)
test_scan_file_multichunk_sorted_merge :: proc(t: ^testing.T) {
    // 跨越多个 2 MiB 分片的大文件：验证分片并行扫描后的归并结果
    // 与单线程完全一致，且偏移全局升序（不被分片顺序打乱）。
    // 命中刻意远离分片边界（2 MiB 边界 2097152 / 4194304），
    // 以避开"分片尾部重叠扫描"带来的边界语义干扰。
    path :: "/tmp/xrep_ut_scan_big.bin"
    dump :: "/tmp/xrep_ut_scan_big_offsets.txt"
    defer os.remove(path)
    defer os.remove(dump)

    data := make([]u8, 5 * mem.Megabyte)
    for i in 0..<len(data) {
        data[i] = u8('z')
    }
    offsets := []int{1000, 1000000, 3000000, 4500000}
    for off in offsets {
        copy(data[off:off + 4], lib.s2b("test"))
    }
    testing.expect(t, os.write_entire_file(path, data) == nil, "写入大文件应成功")
    delete(data)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    thread_counts := []uint{1, 2, 4, 8}
    for n in thread_counts {
        o := scan_opts(ctx, n); o.dump_path = dump
        hits, _ := scan_file(path, o)
        testing.expectf(t, hits == uint(len(offsets)), "threads=%d 应命中 %d 处，实际 %d", n, len(offsets), hits)

        content, err := os.read_entire_file(dump, context.allocator)
        testing.expect(t, err == nil)
        testing.expect_value(t, transmute(string)content, "1000\n1000000\n3000000\n4500000\n")
        delete(content)
    }
}

// ---------------------------------------------------------------------------
// 输出模式判定（两个纯函数：决定"走历史偏移输出"与"是否值得建行号表"）
// ---------------------------------------------------------------------------

@(test)
test_scan_legacy_output_truth_table :: proc(t: ^testing.T) {
    // 默认（全零）→ 历史偏移导向输出，进度条可见
    base := lib.Scan_Options{}
    testing.expect(t, legacy_output(base), "默认应走传统偏移输出")

    // 任何一个结构化开关都会切走：进度条随之关闭，避免 \r 污染管道
    o := base; o.show_path = true
    testing.expect(t, !legacy_output(o), "show_path（多文件/-r）不再是传统输出")
    o = base; o.line_numbers = true
    testing.expect(t, !legacy_output(o), "-n 不再是传统输出")
    o = base; o.only_matching = true
    testing.expect(t, !legacy_output(o), "-o 不再是传统输出")
    o = base; o.json = true
    testing.expect(t, !legacy_output(o), "--json 不再是传统输出")
    o = base; o.list_mode = .Files_With
    testing.expect(t, !legacy_output(o), "-l 不再是传统输出")
    o = base; o.list_mode = .Files_Without
    testing.expect(t, !legacy_output(o), "-L 不再是传统输出")

    // 注意：quiet 与 only_count **不**参与该判定（既有语义）。
    // quiet 由 progress_on 单独兜住（scan_region_parallel 里 !quiet && legacy_output），
    // only_count 走的是"只打印结论行"的早返回分支。
    o = base; o.quiet = true
    testing.expect(t, legacy_output(o), "quiet 不改变输出模式判定（由 progress_on 单独处理）")
    o = base; o.only_count = true
    testing.expect(t, legacy_output(o), "--count 不改变输出模式判定")
    // 组合：quiet + 结构化开关仍为 false
    o = base; o.quiet = true; o.json = true
    testing.expect(t, !legacy_output(o), "结构化开关优先于 quiet")
}

@(test)
test_scan_line_index_needed_truth_table :: proc(t: ^testing.T) {
    // 纯默认：不建行号表（省掉一次 O(n) 扫描与 O(换行数) 内存）
    testing.expect(t, !line_index_needed(lib.Scan_Options{}), "默认不需要行号表")

    // 明细要输出行号的三种形态 → 建表
    o := lib.Scan_Options{line_numbers = true}
    testing.expect(t, line_index_needed(o), "-n 需要行号表")
    o = lib.Scan_Options{show_path = true}
    testing.expect(t, line_index_needed(o), "行导向输出需要行号表")
    o = lib.Scan_Options{json = true}
    testing.expect(t, line_index_needed(o), "--json 需要行号表")

    // 明细根本不输出 → 不建表（即便同时打开了开关）
    o = lib.Scan_Options{line_numbers = true, quiet = true}
    testing.expect(t, !line_index_needed(o), "quiet 抑制明细，不建行号表")
    o = lib.Scan_Options{show_path = true, list_mode = .Files_With}
    testing.expect(t, !line_index_needed(o), "-l 抑制明细，不建行号表")
    o = lib.Scan_Options{json = true, only_count = true}
    testing.expect(t, !line_index_needed(o), "--count 抑制明细，不建行号表")
}

// ---------------------------------------------------------------------------
// --stats 累加（Run_Stats 的四条计数各自独立）
// ---------------------------------------------------------------------------

@(test)
test_scan_file_accumulates_run_stats :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_stats.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    sample_size := u64(len(SCAN_SAMPLE))

    // 1) 有命中：scanned / matched / bytes / hits 全部累加，skipped 不动
    {
        st: lib.Run_Stats
        o := scan_opts(ctx); o.stats = &st
        hits, _ := scan_file(path, o)
        testing.expect_value(t, hits, uint(3))
        testing.expect_value(t, st.files_scanned, uint(1))
        testing.expect_value(t, st.files_matched, uint(1))
        testing.expect_value(t, st.files_skipped, uint(0))
        testing.expect_value(t, st.bytes_scanned, sample_size)
        testing.expect_value(t, st.total_hits, u64(3))
    }
    // 2) 0 命中：仍然算"扫过"，但不算"有命中"
    {
        st: lib.Run_Stats
        o := scan_opts(lib.Match_Ctx{pattern = lib.s2b("zzz-no-such"), case_insensitive = false})
        o.stats = &st
        hits, _ := scan_file(path, o)
        testing.expect_value(t, hits, uint(0))
        testing.expect_value(t, st.files_scanned, uint(1))
        testing.expect_value(t, st.files_matched, uint(0))
        testing.expect_value(t, st.bytes_scanned, sample_size)
        testing.expect_value(t, st.total_hits, u64(0))
    }
    // 3) --max-size 跳过：只加 skipped，其余一律不加（它并非"扫过 0 命中"）
    {
        st: lib.Run_Stats
        o := scan_opts(ctx); o.stats = &st; o.max_size = 10
        hits, ok := scan_file(path, o)
        testing.expect_value(t, hits, uint(0))
        testing.expect(t, ok)
        testing.expect_value(t, st.files_skipped, uint(1))
        testing.expect_value(t, st.files_scanned, uint(0))
        testing.expect_value(t, st.files_matched, uint(0))
        testing.expect_value(t, st.bytes_scanned, u64(0))
        testing.expect_value(t, st.total_hits, u64(0))
    }
    // 4) 多次扫描是累加而非覆盖
    {
        st: lib.Run_Stats
        o := scan_opts(ctx); o.stats = &st
        for _ in 0..<3 {
            _, _ = scan_file(path, o)
        }
        testing.expect_value(t, st.files_scanned, uint(3))
        testing.expect_value(t, st.files_matched, uint(3))
        testing.expect_value(t, st.bytes_scanned, sample_size * 3)
        testing.expect_value(t, st.total_hits, u64(9))
    }
    // 5) stats == nil（不带 --stats 的默认路径）不得崩溃
    {
        o := scan_opts(ctx); o.stats = nil
        hits, _ := scan_file(path, o)
        testing.expect_value(t, hits, uint(3))
    }
}

// ---------------------------------------------------------------------------
// -m / --max-count：归并结果截断（流式路径由 worker_test.odin 覆盖）
// ---------------------------------------------------------------------------

@(test)
test_scan_file_max_count_truncates_results :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_scan_maxcount.bin"
    dump :: "/tmp/xrep_ut_scan_maxcount.txt"
    scan_write_sample(t, path)
    defer os.remove(path)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}

    // -m 0（默认）= 不限
    h0, _ := scan_file(path, scan_opts(ctx))
    testing.expect_value(t, h0, uint(3))

    // -m 2：返回值与落盘都截到 2 条。汇总路径取的是**归并后按偏移升序的前 N 条**
    // （流式路径取的是"最先算出来的 N 条"，两者在单分片时一致）
    o := scan_opts(ctx); o.max_count = 2; o.dump_path = dump
    h1, ok1 := scan_file(path, o)
    testing.expect_value(t, h1, uint(2))
    testing.expect(t, ok1)
    {
        data, err := os.read_entire_file(dump, context.allocator)
        testing.expect(t, err == nil)
        defer delete(data)
        testing.expect_value(t, transmute(string)data, "6\n17\n")
    }

    // -m 1：只留偏移最小的一条
    o2 := scan_opts(ctx); o2.max_count = 1
    h2, _ := scan_file(path, o2)
    testing.expect_value(t, h2, uint(1))

    // -m 大于命中数：不补齐，仍是全部 3 条
    o3 := scan_opts(ctx); o3.max_count = 99
    h3, _ := scan_file(path, o3)
    testing.expect_value(t, h3, uint(3))

    // -m 与区间过滤的先后顺序：先按区间过滤，再截断
    o4 := scan_opts(ctx); o4.max_count = 1; o4.after = 20
    h4, _ := scan_file(path, o4)
    testing.expect_value(t, h4, uint(1))
}

// ---------------------------------------------------------------------------
// -l / -L 与多模式的端到端契约
// ---------------------------------------------------------------------------

@(test)
test_scan_file_list_mode_keeps_count :: proc(t: ^testing.T) {
    // -l / -L 只是在常规输出之前提前返回（只打文件名），命中数本身不变。
    path :: "/tmp/xrep_ut_scan_listmode.bin"
    scan_write_sample(t, path)
    defer os.remove(path)

    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}
    plain, _ := scan_file(path, scan_opts(ctx))
    testing.expect_value(t, plain, uint(3))

    o_l := scan_opts(ctx); o_l.list_mode = .Files_With
    hl, _ := scan_file(path, o_l)
    testing.expect_value(t, hl, uint(3))

    // -L 用于有命中的文件时：计数同样是 3（只是不打印该文件）
    o_L := scan_opts(ctx); o_L.list_mode = .Files_Without
    hL, _ := scan_file(path, o_L)
    testing.expect_value(t, hL, uint(3))

    // -l + --json / -L + --json 只影响打印形态，返回值一致
    o_lj := scan_opts(ctx); o_lj.list_mode = .Files_With; o_lj.json = true
    hlj, _ := scan_file(path, o_lj)
    testing.expect_value(t, hlj, uint(3))
}

@(test)
test_scan_file_multi_pattern_end_to_end :: proc(t: ^testing.T) {
    // 多模式（-e / -f）在 worker 里由 select_matcher_for 分派到 multi_match。
    // SCAN_SAMPLE = "hello test world\ntest again\ntest"（32 字节）：
    //   "test" @6 / @17 / @28，"world" @11 → 合计 4 条，归并后按偏移升序。
    path :: "/tmp/xrep_ut_scan_multipat.bin"
    dump :: "/tmp/xrep_ut_scan_multipat.txt"
    scan_write_sample(t, path)
    defer os.remove(path)
    defer os.remove(dump)

    ctx := lib.Match_Ctx{
        pattern = lib.s2b("test"),
        extra = [][]u8{lib.s2b("world")},
    }
    thread_counts := []uint{1, 4}
    for n in thread_counts {
        o := scan_opts(ctx, n); o.dump_path = dump
        hits, ok := scan_file(path, o)
        testing.expectf(t, hits == 4, "threads=%d 多模式应命中 4 条，实际 %d", n, hits)
        testing.expect(t, ok)
        data, err := os.read_entire_file(dump, context.allocator)
        testing.expect(t, err == nil)
        defer delete(data)
        testing.expect_value(t, transmute(string)data, "6\n11\n17\n28\n")
    }

    // 大小写不敏感同样贯穿多模式路径
    ctx_i := lib.Match_Ctx{
        pattern = lib.s2b("TEST"),
        extra = [][]u8{lib.s2b("World")},
        case_insensitive = true,
    }
    hi, _ := scan_file(path, scan_opts(ctx_i, 2))
    testing.expect_value(t, hi, uint(4))

    // --after 过滤作用在**绝对偏移**上（多模式命中同样被过滤）
    o_f := scan_opts(ctx, 2); o_f.after = 13
    hf, _ := scan_file(path, o_f)
    testing.expect_value(t, hf, uint(2)) // 只剩 17 与 28
}

// ---------------------------------------------------------------------------
// 分片重叠窗口的契约（README 已知行为#2）
// ---------------------------------------------------------------------------

@(test)
test_scan_chunk_overlap_contract :: proc(t: ^testing.T) {
    // 每个任务向后多扫 CHUNK_OVERLAP 字节，以免切断跨分片的匹配；
    // 代价是完全落在 [分片边界, 边界+CHUNK_OVERLAP) 的命中会被相邻两个任务
    // 各报一次（不去重）。本用例把三个位置逐一钉死：
    //   b-1   跨界命中            → 只有前一个任务看得到（重叠窗口存在的理由）
    //   b     恰在边界            → 两个任务都看得到 → 报 2 次（已知契约）
    //   b+16  边界 + 重叠长度     → 刚好在窗口之外 → 只报 1 次
    b := uint(lib.TASK_CHUNK_SIZE)
    tail := uint(1024)
    ctx := lib.Match_Ctx{pattern = lib.s2b("test"), case_insensitive = false}

    // ---- 跨界命中不被切断 ----
    path_a :: "/tmp/xrep_ut_scan_ovl_straddle.bin"
    {
        data_a := make([]u8, int(b + tail))
        defer delete(data_a)
        for i in 0..<len(data_a) {
            data_a[i] = 'z'
        }
        copy(data_a[b - 1:b + 3], lib.s2b("test"))
        testing.expect(t, os.write_entire_file(path_a, data_a) == nil)
    }
    defer os.remove(path_a)
    hits_a, _ := scan_file(path_a, scan_opts(ctx, 4))
    testing.expect_value(t, hits_a, uint(1))

    // ---- 重叠窗口内的重复上报 + 窗口外的单次上报 ----
    path_b :: "/tmp/xrep_ut_scan_ovl_dup.bin"
    dump :: "/tmp/xrep_ut_scan_ovl_dup.txt"
    defer os.remove(path_b)
    defer os.remove(dump)
    {
        data_b := make([]u8, int(b + tail))
        defer delete(data_b)
        for i in 0..<len(data_b) {
            data_b[i] = 'z'
        }
        copy(data_b[b:b + 4], lib.s2b("test"))
        copy(data_b[b + lib.CHUNK_OVERLAP:], lib.s2b("test"))
        testing.expect(t, os.write_entire_file(path_b, data_b) == nil)
    }
    o := scan_opts(ctx, 4); o.dump_path = dump
    hits_b, _ := scan_file(path_b, o)
    testing.expect_value(t, hits_b, uint(3))
    {
        content, err := os.read_entire_file(dump, context.allocator)
        testing.expect(t, err == nil)
        defer delete(content)
        want := fmt.aprintf("%d\n%d\n%d\n", b, b, b + lib.CHUNK_OVERLAP)
        defer delete(want)
        testing.expect_value(t, transmute(string)content, want)
    }
}
