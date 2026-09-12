package main

// ============================================================================
// walk_test.odin — 目录遍历与 glob 匹配的单元测试
//
// 覆盖：
//   * glob_match：basename 规则、`*` 不跨 `/`、`**` 跨 `/`、`?`、反斜杠转义；
//   * walk_expand：递归展开、非递归目录被拒、隐藏项、--glob 过滤、--exclude 排除。
//
// 两个必须注意的点：
//   1. 测试运行器默认**并行**跑用例，因此每个用例必须使用**独立的根目录**，
//      否则会互相删树（第一次写这组用例时就踩到了）。
//   2. `fmt.tprintf` 走临时分配器，其返回值**不能 delete**（会报 bad free）；
//      需要释放的字符串一律用 `fmt.aprintf`。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

// 每个用例的独立根目录（aprintf，调用方 delete）。
wt_root :: proc(name: string) -> string {
    return fmt.aprintf("/tmp/xrep_ut_walk_%s", name)
}

// 在 root 下写文件（自动建父目录）。path 用临时分配器拼装，不泄漏。
wt_write :: proc(root: string, rel: string, content: string) {
    path := fmt.tprintf("%s/%s", root, rel)
    if i := strings.last_index_byte(path, '/'); i > 0 {
        os.make_directory_all(path[:i])
    }
    _ = os.write_entire_file(path, transmute([]byte)content)
}

// 建树：
//   <root>/a.txt  <root>/b.bin  <root>/sub/c.txt
//   <root>/sub/deep/d.bin        <root>/.hidden/e.txt
wt_setup :: proc(t: ^testing.T, root: string) {
    os.remove_all(root)
    wt_write(root, "a.txt", "x")
    wt_write(root, "b.bin", "x")
    wt_write(root, "sub/c.txt", "x")
    wt_write(root, "sub/deep/d.bin", "x")
    wt_write(root, ".hidden/e.txt", "x")
    testing.expect(t, os.is_dir(root), "测试目录树应已创建")
}

// 把结果去掉 root 前缀后拼成 "a.txt,b.bin,sub/c.txt"（返回 aprintf 串，调用方 delete）。
wt_rel_join :: proc(paths: []string, root: string) -> string {
    b: strings.Builder
    strings.builder_init(&b)
    for p, i in paths {
        if i > 0 {
            strings.write_byte(&b, ',')
        }
        rel := p
        if len(p) > len(root) + 1 {
            rel = p[len(root) + 1:]
        }
        strings.write_string(&b, rel)
    }
    return strings.to_string(b)
}

// 展开 root 并与期望的相对路径串比较（顺序敏感：walk 按条目名排序）。
wt_expect :: proc(t: ^testing.T, root: string, o: Walk_Options, want: string, msg: string) {
    files := walk_expand([]string{root}, o)
    defer walk_free(&files)
    got := wt_rel_join(files[:], root)
    defer delete(got)
    testing.expectf(t, got == want, "%s: 期望 [%s]，实际 [%s]", msg, want, got)
}

// ---------------------------------------------------------------------------
// glob_match
// ---------------------------------------------------------------------------

@(test)
test_glob_basename_rule :: proc(t: ^testing.T) {
    // 模式不含 '/' → 只与 basename 比较，因此可命中任意深度。
    testing.expect(t, glob_match("*.bin", "a.bin"), "同目录 .bin")
    testing.expect(t, glob_match("*.bin", "src/sub/a.bin"), "深层 .bin")
    testing.expect(t, !glob_match("*.bin", "a.txt"), "扩展名不符")
    testing.expect(t, glob_match("a.txt", "deep/dir/a.txt"), "纯文件名精确匹配")
}

@(test)
test_glob_star_does_not_cross_slash :: proc(t: ^testing.T) {
    // 单 `*` 不跨目录分隔符。
    testing.expect(t, glob_match("src/*", "src/a.c"), "src/* 命中子文件")
    testing.expect(t, !glob_match("src/*", "src/sub/a.c"), "src/* 不跨目录")
    testing.expect(t, glob_match("src/*.c", "src/a.c"), "src/*.c")
    testing.expect(t, !glob_match("src/*.c", "src/sub/a.c"), "src/*.c 不跨目录")
    testing.expect(t, !glob_match("src*", "src/sub"), "尾部 * 不跨 /")
}

@(test)
test_glob_double_star_crosses_slash :: proc(t: ^testing.T) {
    testing.expect(t, glob_match("src/**", "src/sub/a.c"), "** 跨目录")
    testing.expect(t, glob_match("src/**/*.c", "src/sub/deep/a.c"), "** 中间段")
    testing.expect(t, glob_match("**", "a/b/c"), "裸 ** 全匹配")
    testing.expect(t, glob_match("**/a.c", "x/y/a.c"), "**/ 前缀")
    // 连续多个 '*' 折叠成 '**'（模式含 '/'，故与整条路径比较）。
    testing.expect(t, glob_match("a/***b", "a/x/yb"), "多星折叠为 **")
}

@(test)
test_glob_question_and_escape :: proc(t: ^testing.T) {
    testing.expect(t, glob_match("a?c", "abc"), "? 匹配单字符")
    testing.expect(t, !glob_match("a?c", "a/c"), "? 不匹配 /")
    testing.expect(t, !glob_match("a?c", "ac"), "? 必须恰好一个")
    // 反斜杠转义：`\*` 是字面量星号。
    testing.expect(t, glob_match("a\\*b", "a*b"), "转义星号按字面匹配")
    testing.expect(t, !glob_match("a\\*b", "axb"), "转义后不再是通配")
}

@(test)
test_glob_exact_and_edge :: proc(t: ^testing.T) {
    testing.expect(t, glob_match("", ""), "空模式匹配空串")
    testing.expect(t, !glob_match("", "a"), "空模式不匹配非空")
    testing.expect(t, glob_match("abc", "abc"), "字面量全等")
    testing.expect(t, !glob_match("abc", "abcd"), "字面量必须耗尽")
    testing.expect(t, !glob_match("abcd", "abc"), "路径必须耗尽")
    // 不含 '/' 的模式只比 basename —— 这也是"为什么 glob 作用于整条路径"的对照。
    testing.expect(t, glob_match("b", "a/b"), "模式 b 命中 a/b 的 basename")
}

// ---------------------------------------------------------------------------
// walk_expand
// ---------------------------------------------------------------------------

@(test)
test_walk_recursive_default :: proc(t: ^testing.T) {
    root := wt_root("rec")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    // 隐藏目录 .hidden 默认跳过；顺序按条目名排序（a.txt < b.bin < sub）。
    wt_expect(t, root, Walk_Options{recursive = true}, "a.txt,b.bin,sub/c.txt,sub/deep/d.bin", "递归默认（跳过隐藏）")
}

@(test)
test_walk_hidden_included :: proc(t: ^testing.T) {
    root := wt_root("hidden")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    wt_expect(
        t,
        root,
        Walk_Options{recursive = true, hidden = true},
        ".hidden/e.txt,a.txt,b.bin,sub/c.txt,sub/deep/d.bin",
        "开 --hidden",
    )
}

@(test)
test_walk_glob_filter_applies_to_files_only :: proc(t: ^testing.T) {
    root := wt_root("glob")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    // `*.txt` 必须仍能下降到 sub/ 与 sub/deep/（目录不受 --glob 约束）。
    wt_expect(t, root, Walk_Options{recursive = true, globs = []string{"*.txt"}}, "a.txt,sub/c.txt", "--glob '*.txt'")
}

@(test)
test_walk_exclude_dir_and_file :: proc(t: ^testing.T) {
    root := wt_root("excl")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    // 排除目录 sub：只剩根下的两个文件。
    wt_expect(t, root, Walk_Options{recursive = true, excludes = []string{"sub"}}, "a.txt,b.bin", "--exclude sub")
    // 排除扩展名：b.bin 与 sub/deep/d.bin 都被挡掉。
    wt_expect(t, root, Walk_Options{recursive = true, excludes = []string{"*.bin"}}, "a.txt,sub/c.txt", "--exclude '*.bin'")
}

@(test)
test_walk_non_recursive_dir_is_skipped :: proc(t: ^testing.T) {
    root := wt_root("norec")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    // 未开 --recursive：目录参数被跳过（报 stderr），结果为空。
    files := walk_expand([]string{root}, Walk_Options{})
    defer walk_free(&files)
    testing.expect_value(t, len(files), 0)
}

@(test)
test_walk_passthrough_non_dir_kept_verbatim :: proc(t: ^testing.T) {
    root := wt_root("pass")
    defer delete(root)
    wt_setup(t, root)
    defer os.remove_all(root)
    // 非目录路径原样保留 —— 包括**不存在**的路径：存在性由 scan_file 负责报告，
    // 在这里过滤会改变既有的 stderr 文案与退出码。
    missing := "/tmp/xrep_ut_walk_definitely_missing_zz"
    files := walk_expand([]string{missing}, Walk_Options{})
    defer walk_free(&files)
    testing.expect_value(t, len(files), 1)
    testing.expect_value(t, files[0], missing)
}
