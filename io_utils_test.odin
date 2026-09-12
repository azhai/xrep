package main

// ============================================================================
// io_utils_test.odin — I/O 层单元测试
//
// 覆盖：
//   * context_range 的全部边界算术（文件头、文件尾、窗口跨边界、pat_len/ctx 为 0）
//   * read_file_data 的成功/失败路径
//   * dump_matches 的十进制/十六进制输出、空结果、写入失败路径
//
// 临时文件统一放在 /tmp/xrep_ut_* 前缀下，用例末尾清理。
// ============================================================================

import "core:os"
import "core:testing"

// ---------- context_range ----------

@(test)
test_context_range_basic :: proc(t: ^testing.T) {
    // 文件 1000 字节，命中在 500，模式长 4，上下文各 10 字节
    s, e := context_range(1000, 500, 4, 10)
    testing.expect_value(t, s, uint(490))
    testing.expect_value(t, e, uint(514))
}

@(test)
test_context_range_start_clamped_to_head :: proc(t: ^testing.T) {
    // 命中靠近文件头：向前回退不足 ctx → 夹到 0
    s, e := context_range(1000, 3, 4, 10)
    testing.expect_value(t, s, uint(0))
    testing.expect_value(t, e, uint(17))
    // 命中恰好在 0
    s2, e2 := context_range(1000, 0, 2, 8)
    testing.expect_value(t, s2, uint(0))
    testing.expect_value(t, e2, uint(10))
    // 命中 == ctx：不触发回退分支（start - ctx == 0）
    s3, _ := context_range(1000, 10, 1, 10)
    testing.expect_value(t, s3, uint(0))
}

@(test)
test_context_range_end_clamped_to_tail :: proc(t: ^testing.T) {
    // 命中靠近文件尾：终点超过文件长度 → 夹到文件长度
    s, e := context_range(100, 95, 4, 10)
    testing.expect_value(t, s, uint(85))
    testing.expect_value(t, e, uint(100))
    // 命中正好落在最后一个字节
    s2, e2 := context_range(100, 99, 1, 5)
    testing.expect_value(t, s2, uint(94))
    testing.expect_value(t, e2, uint(100))
}

@(test)
test_context_range_zero_inputs :: proc(t: ^testing.T) {
    // 边界：ctx=0 → 窗口恰好覆盖模式本身
    s, e := context_range(100, 50, 3, 0)
    testing.expect_value(t, s, uint(50))
    testing.expect_value(t, e, uint(53))
    // 边界：pat_len=0 → 窗口退化为命中点周围 ctx 字节
    s2, e2 := context_range(100, 50, 0, 5)
    testing.expect_value(t, s2, uint(45))
    testing.expect_value(t, e2, uint(55))
    // 边界：空文件
    s3, e3 := context_range(0, 0, 0, 0)
    testing.expect_value(t, s3, uint(0))
    testing.expect_value(t, e3, uint(0))
    // 边界：ctx 远超文件长度（起点夹 0，终点夹文件长度）
    s4, e4 := context_range(10, 5, 2, 4096)
    testing.expect_value(t, s4, uint(0))
    testing.expect_value(t, e4, uint(10))
}

// ---------- read_file_data ----------

@(test)
test_read_file_data_ok_and_missing :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_read.bin"
    content := "hello xrep\n"
    werr := os.write_entire_file(path, transmute([]byte)content)
    testing.expect(t, werr == nil, "写入临时文件应成功")
    defer os.remove(path)

    data, err := read_file_data(path)
    testing.expect(t, err == nil, "读取已存在文件应成功")
    testing.expect_value(t, len(data), len(content))
    testing.expect_value(t, transmute(string)data, content)
    delete(data)

    // 边界：不存在的路径必须返回错误而不是崩溃
    missing, err2 := read_file_data("/tmp/xrep_ut_definitely_missing_9d3f.bin")
    testing.expect(t, err2 != nil, "读取不存在文件应返回错误")
    if err2 == nil {
        delete(missing)
    }
}

// ---------- dump_matches ----------

@(test)
test_dump_matches_decimal :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_dump_dec.txt"
    defer os.remove(path)

    ok := dump_matches(path, []Match_Result{{0}, {17}, {4096}}, false)
    testing.expect(t, ok, "dump 应成功")

    data, err := os.read_entire_file(path, context.allocator)
    testing.expect(t, err == nil)
    defer delete(data)
    testing.expect_value(t, transmute(string)data, "0\n17\n4096\n")
}

@(test)
test_dump_matches_hex :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_dump_hex.txt"
    defer os.remove(path)

    ok := dump_matches(path, []Match_Result{{255}, {4096}}, true)
    testing.expect(t, ok, "dump 应成功")

    data, err := os.read_entire_file(path, context.allocator)
    testing.expect(t, err == nil)
    defer delete(data)
    // 十六进制输出统一使用 0x 前缀、小写字母
    testing.expect_value(t, transmute(string)data, "0xff\n0x1000\n")
}

@(test)
test_dump_matches_empty_creates_empty_file :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_dump_empty.txt"
    defer os.remove(path)

    // 既有行为：空结果集也会创建文件（内容为空）
    ok := dump_matches(path, []Match_Result{}, false)
    testing.expect(t, ok, "空结果 dump 应返回成功")
    data, err := os.read_entire_file(path, context.allocator)
    testing.expect(t, err == nil, "空 dump 文件应存在")
    defer delete(data)
    testing.expect_value(t, len(data), 0)
}

@(test)
test_dump_matches_write_failure :: proc(t: ^testing.T) {
    // 边界：目标目录不存在 → 返回 false（并已向 stderr 打印错误），不得崩溃
    ok := dump_matches("/tmp/xrep_ut_no_such_dir_7a/out.txt", []Match_Result{{1}}, false)
    testing.expect(t, !ok, "写入不可达路径应返回 false")
}

// ---------- print_context（冒烟）----------

@(test)
test_print_context_smoke :: proc(t: ^testing.T) {
    // 渲染输出到 stdout，此处只保证各边界组合不越界/不崩溃。
    data := s2b("abcdefghij")
    print_context(data, 0, 1, 4, true)  // 起点夹 0
    print_context(data, 5, 2, 3, false) // 无颜色
    print_context(data, 9, 1, 8, true)  // 终点夹文件长度
    print_context(data, 0, 0, 0, false) // 退化窗口
    testing.expect(t, true)
}

// ---------- sanitize_dump_name ----------

@(test)
test_sanitize_dump_name_absolute_path :: proc(t: ^testing.T) {
    // 绝对路径：每个 '/' 变成 '_'，长度不变
    got := sanitize_dump_name("/tmp/data/file.bin")
    defer delete(got)
    testing.expect_value(t, transmute(string)got, "_tmp_data_file.bin")
}

@(test)
test_sanitize_dump_name_relative_dot_path :: proc(t: ^testing.T) {
    // 契约变更的关键场景（ADR 0002）：'./data/file.bin' 过去会拼出
    // "..././data/file.bin.txt" 而要求同名子目录存在；清洗后不再有分隔符。
    got := sanitize_dump_name("./data/file.bin")
    defer delete(got)
    testing.expect_value(t, transmute(string)got, "._data_file.bin")
}

@(test)
test_sanitize_dump_name_windows_unsafe_chars :: proc(t: ^testing.T) {
    // 反斜杠、盘符冒号与 Windows 保留字符（* ? " < > |）统一替换为 '_'
    got := sanitize_dump_name("C:\\dir\\a:b*c?.bin")
    defer delete(got)
    testing.expect_value(t, transmute(string)got, "C__dir_a_b_c_.bin")
}

@(test)
test_sanitize_dump_name_preserves_safe_and_utf8 :: proc(t: ^testing.T) {
    // 安全字符（点号、短横线）原样保留
    got := sanitize_dump_name("a-b.c")
    defer delete(got)
    testing.expect_value(t, transmute(string)got, "a-b.c")

    // 中文（多字节 UTF-8）不被破坏：只逐字节判断是否属不安全集合
    name := "数据.bin"
    got2 := sanitize_dump_name(name)
    defer delete(got2)
    testing.expect_value(t, transmute(string)got2, name)

    // 边界：空路径 → 空切片，不崩溃
    got3 := sanitize_dump_name("")
    defer delete(got3)
    testing.expect_value(t, len(got3), 0)
}

// ---------- file_size_of ----------

@(test)
test_file_size_of :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_size.bin"
    content := "0123456789"
    testing.expect(t, os.write_entire_file(path, transmute([]byte)content) == nil)
    defer os.remove(path)

    size, ok := file_size_of(path)
    testing.expect(t, ok, "已存在文件应能取到大小")
    testing.expect_value(t, size, u64(10))

    // 边界：文件不存在 → (0, false)，不崩溃
    _, ok2 := file_size_of("/tmp/xrep_ut_size_missing_zz.bin")
    testing.expect(t, !ok2)
}

// ---------- dump_matches 追加模式 ----------

@(test)
test_dump_matches_append_mode :: proc(t: ^testing.T) {
    path :: "/tmp/xrep_ut_dump_append.txt"
    defer os.remove(path)
    os.remove(path)

    ok1 := dump_matches(path, []Match_Result{{1}}, false)
    testing.expect(t, ok1, "覆盖写应成功")
    // 追加模式：内容累加而非覆盖
    ok2 := dump_matches(path, []Match_Result{{2}}, false, true)
    testing.expect(t, ok2, "追加写应成功")

    data, err := os.read_entire_file(path, context.allocator)
    testing.expect(t, err == nil)
    defer delete(data)
    testing.expect_value(t, transmute(string)data, "1\n2\n")
}
