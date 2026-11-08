#+dialect hela
package engine

// ============================================================================
// readahead_test.odin — 预读管线的契约测试
//
// 这条管线改了"谁读文件、什么时候读"，所以它的契约只有两条，但两条都不能破：
//
//   1. **顺序与内容**：条目按调用方给的顺序交付，每条的数据与 `os.read_entire_file`
//      逐字节相同。顺序变了，`--dump`、golden、`-m` 的"前 N 条"全都跟着变。
//   2. **不漏不重**：每个文件恰好交付一次；提前 destroy（例如 --max-count 提前结束）
//      时队列里还没取走的缓冲必须被释放 —— 否则每次都是几 MB 的泄漏。
//
// 另外单独测并行读：分块 pread 的偏移是绝对的，写错就是"每一段都读文件开头"，
// 而那种错误在输出里表现为"命中位置全挤在文件前 1/n"—— 用逐字节比对才抓得住。
// ============================================================================

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"

// 一个临时目录 + 若干文件；名字用 aprintf 分配，destroy 时一并释放。
@(private = "file")
Fixture :: struct {
	dir:   string,
	paths: []string,
}

@(private = "file")
fixture_make :: proc(t: ^testing.T, counts: []int) -> Fixture {
	dir, err := os.make_directory_temp("", "xrep_readahead_", context.allocator)
	if err != nil {
		testing.fail_now(t, "make_directory_temp failed")
	}
	paths := make([]string, len(counts))
	for content_len, i in counts {
		p := fmt.aprintf("%s/f%d.txt", dir, i)
		paths[i] = p
		f, cerr := os.create(p)
		if cerr != nil {
			testing.fail_now(t, "create failed")
		}
		// 内容长度不同，才能分辨"哪一段读到了哪一段"。
		buf := make([]byte, content_len)
		for k in 0 ..< content_len {
			buf[k] = u8('a' + (k + i) % 26)
		}
		_, _ = os.write(f, buf)
		delete(buf)
		os.close(f)
	}
	return Fixture{dir = dir, paths = paths}
}

@(private = "file")
fixture_destroy :: proc(fx: ^Fixture) {
	for p in fx.paths {
		os.remove(p)
		delete(p)
	}
	delete(fx.paths)
	os.remove(fx.dir)
	delete(fx.dir)
}

@(test)
test_readahead_delivers_in_order :: proc(t: ^testing.T) {
	counts := [?]int{0, 1, 17, 4096, 3}
	fx := fixture_make(t, counts[:])
	defer fixture_destroy(&fx)

	r: Reader
	if !readahead_init(&r, fx.paths, 0) {
		testing.fail_now(t, "readahead_init failed")
	}
	seen := 0
	for {
		item, ok := readahead_next(&r)
		if !ok {
			break
		}
		testing.expect(t, item.path == fx.paths[seen], "条目按调用方给的顺序交付")
		testing.expect(t, !item.skipped, "没有越过 --max-size 时必然读到了数据")
		if item.data != nil {
			testing.expectf(t, len(item.data) == counts[seen],
				"第 %d 条长度应为 %d，实际 %d", seen, counts[seen], len(item.data))
			// 首字节与末字节：内容来自哪个文件，一眼可辨。
			if len(item.data) > 0 {
				testing.expect(t, item.data[0] == u8('a' + seen % 26), "内容属于这个文件")
				testing.expect(t,
					item.data[len(item.data) - 1] == u8('a' + (len(item.data) - 1 + seen) % 26),
					"末字节也属于这个文件")
			}
			delete(item.data, runtime.default_context().allocator)
		}
		seen += 1
	}
	readahead_destroy(&r)
	testing.expectf(t, seen == len(counts), "每个文件恰好交付一次：期望 %d，实际 %d", len(counts), seen)
}

@(test)
test_readahead_respects_max_size :: proc(t: ^testing.T) {
	counts := [?]int{16, 16, 16}
	fx := fixture_make(t, counts[:])
	defer fixture_destroy(&fx)

	r: Reader
	// --max-size 是 4 字节：全部超限，于是全部以 skipped 交付（由 scan_file 打印 skip 行），
	// 而不是被预读线程额外读一遍再丢掉。
	if !readahead_init(&r, fx.paths, 4) {
		testing.fail_now(t, "readahead_init failed")
	}
	seen := 0
	for {
		item, ok := readahead_next(&r)
		if !ok {
			break
		}
		testing.expect(t, item.skipped, "超限文件不应被读")
		testing.expect(t, item.path == fx.paths[seen], "跳过也要按顺序交付")
		seen += 1
	}
	readahead_destroy(&r)
	testing.expect(t, seen == len(counts), "跳过的条目也要全部交付")
}

@(test)
test_readahead_destroy_releases_pending :: proc(t: ^testing.T) {
	counts := [?]int{1024, 1024, 1024, 1024, 1024, 1024}
	fx := fixture_make(t, counts[:])
	defer fixture_destroy(&fx)

	r: Reader
	if !readahead_init(&r, fx.paths, 0) {
		testing.fail_now(t, "readahead_init failed")
	}
	// 只取一条就停：队列里还有 1 条（深度 2）正要/已经读好，读者线程也可能正握着一条。
	// destroy 必须把没交付的缓冲释放掉 —— 这条用例存在的意义就是那个 free 少写了一次。
	item, ok := readahead_next(&r)
	testing.expect(t, ok && !item.skipped, "至少交付一条")
	if item.data != nil {
		delete(item.data, runtime.default_context().allocator)
	}
	readahead_destroy(&r)
}

@(test)
test_read_file_parallel_matches_whole_read :: proc(t: ^testing.T) {
	// 超过 PARALLEL_READ_MIN 才走分块路径；加 7 字节的尾巴，让"余数留给最后一段"被走到。
	size := PARALLEL_READ_MIN + 7
	buf := make([]byte, size)
	defer delete(buf)
	for i in 0 ..< size {
		buf[i] = u8(i * 31)
	}
	fx := fixture_make(t, []int{0})
	defer fixture_destroy(&fx)
	path := fmt.aprintf("%s/big.bin", fx.dir)
	defer delete(path)
	f, _ := os.create(path)
	_, _ = os.write(f, buf)
	os.close(f)

	whole, werr := os.read_entire_file(path, context.allocator)
	if werr != nil {
		testing.fail_now(t, "read_entire_file failed")
	}
	defer delete(whole)

	readers := [?]int{1, 2, 4}
	for n in readers {
		got, ok := read_file_parallel(path, n)
		testing.expectf(t, ok, "%d 个读者应成功", n)
		if !ok {
			continue
		}
		testing.expectf(t, len(got) == len(whole), "%d 个读者：长度应为 %d，实际 %d",
			n, len(whole), len(got))
		testing.expectf(t, string(got) == string(whole),
			"%d 个读者：内容必须与整块读逐字节相同", n)
		delete(got, runtime.default_context().allocator)
	}
}

@(test)
test_read_file_parallel_missing_is_an_error :: proc(t: ^testing.T) {
	got, ok := read_file_parallel("/tmp/xrep_no_such_file_9f2a.bin", 2)
	testing.expect(t, !ok, "不存在的文件必须报失败而不是返回空切片")
	testing.expect(t, got == nil, "失败时不返回缓冲")
}
