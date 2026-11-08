package engine

// ============================================================================
// readahead.odin — 读文件与扫描重叠
//
// 为什么需要它：`scan_file` 是"读一整个文件 → 在内存里并行扫它"，而 main 是
// `for f in files { scan_file(f) }`。于是"读下一个文件"和"扫当前文件"完全串行：
// 磁盘在扫描期间闲置，CPU 在读取期间闲置。
//
// 这不是小事。本机（Apple M4 + 内置 SSD）1 GiB 冷读实测：
//
//     单线程同步 read + F_NOCACHE   1.81 GB/s   ← 队列深度 1
//     2 个读者并发                  3.15 GB/s   ← 盘饱和
//     4 / 8 个读者                  3.09 / 3.10
//
// 而扫描本身有 63 GB/s 的单线程带宽、几百 MB/s 量级的整段处理速度。所以串行时
// 端到端是"读 + 扫"，重叠后是 max(读, 扫) —— 冷语料上后者的上限接近前者的一半。
//
// 设计取舍（都是为了保持"输出逐字节不变"这条硬约束）：
//
//   * **顺序不变**：只有一个读者线程，严格按调用方给的顺序读，队列是 FIFO。
//     多读者能更快吃满盘，但会打乱顺序 —— 那属于"并行读一个文件"的问题，
//     不是这里的（每个文件仍然整块连续、读到内存后由 N 个 worker 并行扫）。
//   * **有界**：深度 2，且超过 READAHEAD_MAX_BYTES 的文件不进队（原地同步读）。
//     否则两个 1 GiB 文件就是 2 GiB 常驻，比省下的那点等待贵得多。
//   * **读失败不在这里处理**：读者把 `data = nil` 交回去，消费方走原来的
//     `scan_file` 路径重试一次，于是 "open ... failed" 的措辞、退出码、
//     `--max-size` 的跳过统计全都保持原样 —— 这条路径只在出错时走。
//   * 锁的频率是"每文件一次"，不是"每字节一次"。ADR 0010 把命中路径上的锁全删了，
//     是因为那里每次命中都要过锁；这里是每文件一次，几万文件也就几万次。
// ============================================================================

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"

// 预读深度。1 就够把"读下一个"与"扫当前"重叠起来；2 让盘的队列里通常还有一条
// 待处理请求（SSD 的内部并行度靠队列深度吃），代价是最多多占一个文件的内存。
READAHEAD_DEPTH :: 2

// 大文件用几个 pread 并发读。一个同步 `read` 是队列深度 1：本机 1 GiB 冷读实测
// 1.81 GB/s（1 读者）对 3.15 GB/s（2 读者），4 个 / 8 个读者不再更快 —— 盘在 2 个
// 读者时就饱和了。所以读者数是 2，不是"等于核数"。
READAHEAD_READERS   :: 2
PARALLEL_READ_MIN   :: 4 * 1024 * 1024

// 超过这个大小的文件不进预读队列：两个 1 GiB 文件常驻内存不合理，而超大文件本身
// 就没有"下一个文件"可与之重叠（单个文件的读仍是串行的，这一点没变）。
READAHEAD_MAX_BYTES :: 64 * 1024 * 1024

// 一条预读结果。`path` 借用调用方的文件名切片（生命周期长于 Reader），
// `data` 由 Reader 分配、由消费方释放。
Read_Item :: struct {
	path: string,
	data: []u8,
	// `data == nil` 不够用：空文件也是"读到了，只是 0 字节"。所以状态单独一位 ——
	// skipped 表示这个文件没被预读读（太大 / 超过 --max-size / 读失败），
	// 消费方按原路径自己读一遍，错误措辞与跳过统计因此保持原样。
	skipped: bool,
}

Reader :: struct {
	paths:    []string,
	max_size: u64,
	next:     int,

	mu:    sync.Mutex,
	ready: sync.Cond, // 队列里有了新条目 / 生产者结束
	space: sync.Cond, // 队列里腾出了位置 / 要停

	items: [READAHEAD_DEPTH]Read_Item,
	count: int,
	head:  int,
	tail:  int,

	eof:  bool,
	stop: bool,
	th:   ^thread.Thread,
}

// readahead_init 启动读者线程。`paths` 必须在整个 Reader 生命周期内有效
// （main 里就是 walk_expand 的产物，直到线程销毁后才 free）。
readahead_init :: proc(r: ^Reader, paths: []string, max_size: u64) -> bool {
	r.paths = paths
	r.max_size = max_size
	// `sync.Cond` / `sync.Mutex` 是零值可用的（core:sync 没有 init/destroy）：
	// 结构体已经由调用方清零，这里不需要再做一次。
	r.th = thread.create_and_start_with_data(r, readahead_run)
	return r.th != nil
}

// readahead_next 取下一个条目；生产者结束时返回 ok=false。
// 返回的 data（若非 nil）由调用方释放：`delete(data, runtime.default_context().allocator)`。
readahead_next :: proc(r: ^Reader) -> (item: Read_Item, ok: bool) {
	sync.mutex_lock(&r.mu)
	for r.count == 0 && !r.eof {
		sync.cond_wait(&r.ready, &r.mu)
	}
	if r.count == 0 {
		sync.mutex_unlock(&r.mu)
		return {}, false
	}
	item = r.items[r.head]
	r.head = (r.head + 1) % READAHEAD_DEPTH
	r.count -= 1
	sync.cond_signal(&r.space)
	sync.mutex_unlock(&r.mu)
	return item, true
}

// readahead_destroy 停掉读者线程。队列里还没被取走的条目在这里释放 ——
// 否则 `--max-count` 提前退出之类的路径会漏掉它们。
readahead_destroy :: proc(r: ^Reader) {
	if r.th != nil {
		sync.mutex_lock(&r.mu)
		r.stop = true
		sync.cond_broadcast(&r.space)
		sync.mutex_unlock(&r.mu)
		thread.join(r.th)
		thread.destroy(r.th)
		r.th = nil
	}
	for i in 0..<r.count {
		it := r.items[(r.head + i) % READAHEAD_DEPTH]
		if it.data != nil {
			delete(it.data, runtime.default_context().allocator)
		}
	}
	r.count = 0
}

// ---------------------------------------------------------------- 并行读一个文件
//
// `readahead_run` 一次只处理一个文件，所以"一个文件怎么读快"和"文件之间怎么重叠"是
// 两个独立的问题。前者靠这里：把文件切成 nreaders 段，每段一个线程顺序 pread。
// 段内仍然顺序（盘的顺序读最快），段间并发（把队列深度从 1 抬到 nreaders）。

Chunk :: struct {
	file: ^os.File,
	// 这一段在**文件里**的起始偏移。pread 的偏移是绝对的，不是相对切片的 ——
	// 少了这个字段，每一段都会把文件开头读进自己的缓冲（这个 bug 写出来时就在）。
	file_off: i64,
	buf:      []u8,
	ok:       bool,
}

@(private)
chunk_read :: proc(data: rawptr) {
	c := cast(^Chunk)data
	off := i64(0)
	for off < i64(len(c.buf)) {
		n, err := os.read_at(c.file, c.buf[off:], c.file_off + off)
		if err != nil || n <= 0 {
			return // c.ok 保持 false
		}
		off += i64(n)
	}
	c.ok = true
}

// read_file_parallel 读取整个文件，返回的缓冲由进程默认堆分配
// （调用方负责 `delete(buf, runtime.default_context().allocator)`）。
// 失败返回 (nil, false)：调用方回落到 `scan_file`，错误措辞由那条路径给出。
read_file_parallel :: proc(path: string, nreaders: int) -> (data: []u8, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return nil, false
	}
	defer os.close(f)
	size, size_err := os.file_size(f)
	if size_err != nil || size < 0 {
		return nil, false
	}
	alloc := runtime.default_context().allocator
	buf := make([]u8, int(size), alloc)

	if nreaders <= 1 || int(size) < PARALLEL_READ_MIN {
		c := Chunk{file = f, buf = buf}
		chunk_read(&c)
		if !c.ok {
			delete(buf, alloc)
			return nil, false
		}
		return buf, true
	}

	count := nreaders
	chunks := make([]Chunk, count, alloc)
	defer delete(chunks, alloc)
	per := int(size) / count
	for i in 0..<count {
		start := i * per
		end := start + per
		if i == count - 1 {
			end = int(size) // 余数留给最后一段，避免丢尾巴
		}
		chunks[i] = Chunk{file = f, file_off = i64(start), buf = buf[start:end]}
	}
	ths := make([]^thread.Thread, count, alloc)
	defer delete(ths, alloc)

	for i in 0..<count {
		ths[i] = thread.create_and_start_with_data(&chunks[i], chunk_read)
	}
	for i in 0..<count {
		thread.join(ths[i])
		thread.destroy(ths[i])
	}
	for i in 0..<count {
		if !chunks[i].ok {
			delete(buf, alloc)
			return nil, false
		}
	}
	return buf, true
}

@(private)
readahead_run :: proc(data: rawptr) {
	r := cast(^Reader)data
	for {
		sync.mutex_lock(&r.mu)
		for r.count == READAHEAD_DEPTH && !r.stop {
			sync.cond_wait(&r.space, &r.mu)
		}
		if r.stop {
			sync.mutex_unlock(&r.mu)
			return
		}
		if r.next >= len(r.paths) {
			r.eof = true
			sync.cond_broadcast(&r.ready)
			sync.mutex_unlock(&r.mu)
			return
		}
		path := r.paths[r.next]
		r.next += 1
		sync.mutex_unlock(&r.mu)

		// 读盘不持锁：这是整条管线里唯一慢的一步，持锁等于把消费者也停住。
		item := Read_Item{path = path}
		size, size_ok := file_size_of(path)
		switch {
		case !size_ok:
			// 交给消费方按原路径重试，好让错误措辞与退出码保持原样。
			item.skipped = true
		case size > READAHEAD_MAX_BYTES:
			item.skipped = true
		case r.max_size > 0 && size > r.max_size:
			// --max-size 会跳过它；不读，让 scan_file 照原样打印 skip 行。
			item.skipped = true
		case:
			buf, read_ok := read_file_parallel(path, READAHEAD_READERS)
			if !read_ok {
				item.skipped = true
			} else {
				item.data = buf
			}
		}

		sync.mutex_lock(&r.mu)
		r.items[r.tail] = item
		r.tail = (r.tail + 1) % READAHEAD_DEPTH
		r.count += 1
		sync.cond_signal(&r.ready)
		sync.mutex_unlock(&r.mu)
	}
}
