package lib

// ============================================================================
// base.odin — lib 包的基础层
//
// 职责：全局常量、跨模块共享的类型定义（匹配上下文 / 匹配结果 / 匹配函数签名 /
//       算法条目 / 颜色模式 / 汇总统计），以及最基础的字节工具。
//
// 依赖：仅依赖 core:mem / core:sync / core:time。本文件是整个工程的**依赖根**，
//       不引用任何本工程包，被 matcher / worker / scan / cli 等模块共同使用。
//       数据结构集中放在 lib 包（ADR 0007），这里是其中与匹配/运行期相关的那一半；
//       选项类数据见 options.odin，容器见 task_pool.odin / output_queue.odin。
// ============================================================================

import "core:mem"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// 全局常量与查表
// ---------------------------------------------------------------------------

// 小写化查表：lower_table[b] 给出字节 b 的小写形式。
// 之所以用查表而非每次调用 tolower()，是因为匹配热路径里每字节都要做一次比较，
// 查表可以避免分支与函数调用开销。
//
// 初始化时机（重要）：用 `@(init)` 在**进程启动时**自动填充，main 与 `odin test`
// 都不再需要显式调用。历史上这里要求调用方手动 init，而 `odin test` 不执行 main，
// 于是每个用例都得自己补一次；漏掉时大小写不敏感匹配会把所有字节都视为相等
// （lower_table 全 0），曾导致测试断言得到"29 命中"而非正确值。
// 改为 `@(init)` 后这个坑彻底消失：全局表在任何入口（含按名筛选的单个测试）都已就绪。
//
// 注：`@(init)` 过程必须是 "contextless" —— 不得依赖 context.allocator。
// 本表是定长数组、纯算术填充，不需要分配器，正好满足约束。
lower_table: [256]u8

@(init)
init_lower_table :: proc "contextless" () {
    for i in 0..<256 {
        c := u8(i)
        if c >= 'A' && c <= 'Z' {
            lower_table[i] = c - 'A' + 'a'
        } else {
            lower_table[i] = c
        }
    }
}

// ANSI 转义序列：用于命中行与上下文高亮。红色为粗体红，绿色用于进度条。
COLOR_RED :: "\x1b[31;1m"
COLOR_RESET :: "\x1b[0m"
COLOR_GREEN :: "\x1b[32;1m"

// 字符串 → []u8（字节看作原始字节）。
// 采用 transmute 而非逐字节拷贝：两者内存布局一致，零拷贝即可获得可切片视图，
// 因此返回的切片与入参共享底层内存，调用方不能假定它拥有所有权。
s2b :: proc(s: string) -> []u8 {
    return transmute([]u8)s
}

// ---------------------------------------------------------------------------
// 跨模块共享的类型
// ---------------------------------------------------------------------------

// 进度条状态。
//
// 为什么类型与函数分在两处：`Match_Fn` 的签名要用 `^Progress`，类型必须住在不
// 依赖任何人的包里（ADR 0006 曾因它留在 engine 而形成 lib 的前身 common → engine 的环）。
// 现在两者同在 lib 包（ADR 0007），仍分文件：类型在 base.odin、
// 操作在 progress.odin —— "数据与操作分离"的常规切法。
Progress :: struct {
    mu:          sync.Mutex,
    total:       u64, // 总字节数；为 0 时不做任何渲染
    scanned:     u64, // 已扫描字节数
    last_render: time.Time, // 上次刷新时刻，用于限流（PROGRESS_MIN_INTERVAL）
    use_color:   bool, // 是否输出 ANSI 颜色
    enabled:     bool, // 总开关（--quiet 时关闭）
}

// 匹配上下文：模式字节、大小写敏感开关，以及**额外模式**（-e / -f 的多模式）。
// 单模式时 extra 为空 → 走 alg_table 选定的原算法，性能与行为完全不变；
// 多模式时 extra 非空 → 由 multi_match 逐位置比较整张模式表。
Match_Ctx :: struct {
    pattern:          []u8,
    case_insensitive: bool,
    extra:            [][]u8,
}

// 模式总数（主模式 + 额外模式）。主模式始终占 1 个槽位。
ctx_pattern_count :: proc(ctx: Match_Ctx) -> int {
    return 1 + len(ctx.extra)
}

// 按索引取模式：0 号是主模式，其余依次为 extra。
ctx_pattern_at :: proc(ctx: Match_Ctx, i: int) -> []u8 {
    if i == 0 {
        return ctx.pattern
    }
    return ctx.extra[i - 1]
}

// 匹配结果：命中位置（文件内的字节偏移）与命中长度。
// pat_len 由匹配算法写入，用于 --context / -o 的高亮区间；
// 为 0 表示"未标注"，调用方回退到主模式长度（历史行为，保持兼容）。
Match_Result :: struct {
    offset:  u64,
    pat_len: u32,
}

// 匹配函数签名（能力缝隙 / capability seam）。
// 所有算法实现同一签名，便于通过 alg_table 按模式长度互换实现，
// 调用方（worker）无需知道具体算法。
//   data     — 待扫描数据（可能只是文件的一个分片）
//   ctx      — 模式与匹配选项
//   progress — 进度上报；可为 disabled 状态（进度条关闭时）
//
// 返回值所有权：返回的切片归**调用方**所有，必须由调用方 `delete`。
//
// 为什么结果不再来自 arena（ADR 0004）：命中数是输入的函数、没有上界，而
// arena 是定长的 —— 超过块容量时 `append` 会**静默失败**（不报错、不回滚），
// 表现为"命中被悄悄丢弃"。实测 `a` 扫 2.5 MiB 全 `a` 文件时，16 MiB 的 arena
// 只装得下 1572864 条（真值 2621440），丢了 40%。改为堆分配后无容量上限。
Match_Fn :: proc(data: []u8, ctx: Match_Ctx, progress: ^Progress) -> []Match_Result

// 算法条目：以模式长度区间选择匹配算法。
Algorithm_Entry :: struct {
    min_len: uint,
    max_len: uint,
    matcher: Match_Fn,
}

// ---------------------------------------------------------------------------
// 运行期常量
//
// 原先这些数值硬编码在各模块内部（scan/worker/progress/bench），散落且难以审查。
// 统一提到本层，便于调参与对照（"提取硬编码常量"）。
// ---------------------------------------------------------------------------

// 单次扫描的分片大小。任务数 = ceil(file_size / TASK_CHUNK_SIZE)。
TASK_CHUNK_SIZE :: 2 * mem.Megabyte

// 分片末尾向后多扫的字节数，避免跨分片的匹配被切断。
// 代价：落在 [分片边界, 分片边界 + CHUNK_OVERLAP) 的命中会被相邻任务各报一次
// （见 README「已知行为与限制」#2）。
CHUNK_OVERLAP :: 16

// 进度条自动刷新的最小间隔（限流），避免高频刷新拖慢多线程热路径。
PROGRESS_MIN_INTERVAL :: 200 * time.Millisecond

// --threads 的默认值与上限策略：上限 = 逻辑核心数 × MAX_THREADS_FACTOR；
// 探测不到核心数时退回 FALLBACK_MAX_THREADS。默认值见 cli.parse_args。
DEFAULT_THREAD_COUNT :: 4
MAX_THREADS_FACTOR :: 4
FALLBACK_MAX_THREADS :: 64

// 版本号：由 --version 输出。对外行为变更时递增。
XREP_VERSION :: "0.3.0"

// ---------------------------------------------------------------------------
// 输出与统计
// ---------------------------------------------------------------------------

// --color=WHEN 的三态。Auto 在实际输出前解析为布尔值（看 stdout 是否 TTY），
// 因此本类型是纯数据，不依赖 core:os —— 解析函数放在 io_utils.resolve_color。
Color_Mode :: enum {
    Auto,
    Always,
    Never,
}

// 整个进程的汇总统计（--stats）。跨文件累加，最后统一写 stderr。
// 注意：--quiet 只抑制 stdout，不影响本统计（统计走 stderr，与"错误可见"同理）。
Run_Stats :: struct {
    files_scanned: uint, // 真正读过并扫描的文件数
    files_matched: uint, // 至少有一条命中的文件数
    files_skipped: uint, // --max-size 跳过的文件数
    bytes_scanned: u64, // 累计扫描字节数
    total_hits:    u64, // 累计命中数
}

// 把用户给出的线程数夹到 [1, max_threads]。
// 纯函数（不探测硬件），便于单测：max_threads 由调用方提供。
// 语义：0 视为 1 —— 否则没有任何 worker 消费任务，结果会静默变成 0 命中。
clamp_thread_count :: proc(n: uint, max_threads: uint) -> uint {
    // 形参不可赋值，先在局部变量上做兜底。
    cap := max_threads
    if cap == 0 {
        cap = FALLBACK_MAX_THREADS
    }
    if n < 1 {
        return 1
    }
    if n > cap {
        return cap
    }
    return n
}
