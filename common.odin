package main

// ============================================================================
// common.odin — 公共基础层
//
// 职责：全局常量、跨模块共享的类型定义（匹配上下文 / 匹配结果 / 匹配函数签名 /
//       算法条目）、arena 生命周期辅助，以及最基础的字节工具。
//
// 依赖：仅依赖 core:mem。本文件是整个包的最底层，不引用任何业务模块，
//       被 matcher / worker / scan / cli 等模块共同使用。
// ============================================================================

import "core:mem"
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

// 匹配上下文：模式字节与其大小写敏感开关。
Match_Ctx :: struct {
    pattern:          []u8,
    case_insensitive: bool,
}

// 匹配结果：目前只记录命中位置（文件内的字节偏移）。
Match_Result :: struct {
    offset: u64,
}

// 匹配函数签名（能力缝隙 / capability seam）。
// 所有算法实现同一签名，便于通过 alg_table 按模式长度互换实现，
// 调用方（worker）无需知道具体算法。
//   data     — 待扫描数据（可能只是文件的一个分片）
//   ctx      — 模式与匹配选项
//   arena    — 结果分配器，命中数组从 arena 分配，生命周期由调用方管理
//   progress — 进度上报；可为 disabled 状态（进度条关闭时）
Match_Fn :: proc(data: []u8, ctx: Match_Ctx, arena: ^mem.Arena, progress: ^Progress) -> []Match_Result

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

// 每个 arena 的初始容量；归还时仅 reset 不释放，故不可随意调大。
ARENA_BLOCK_SIZE :: 16 * mem.Megabyte

// 进度条自动刷新的最小间隔（限流），避免高频刷新拖慢多线程热路径。
PROGRESS_MIN_INTERVAL :: 200 * time.Millisecond

// --threads 的默认值与上限策略：上限 = 逻辑核心数 × MAX_THREADS_FACTOR；
// 探测不到核心数时退回 FALLBACK_MAX_THREADS。默认值见 cli.parse_args。
DEFAULT_THREAD_COUNT :: 4
MAX_THREADS_FACTOR :: 4
FALLBACK_MAX_THREADS :: 64

// 版本号：由 --version 输出。对外行为变更时递增。
XREP_VERSION :: "0.2.0"

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

// ---------------------------------------------------------------------------
// Arena 辅助
// ---------------------------------------------------------------------------

// 在堆上申请 size 字节并初始化为 arena。
// 注意：arena.data 由 make 分配，释放必须走 arena_free（而不是 mem.arena_free_all）。
arena_make :: proc(arena: ^mem.Arena, size: uint) {
    mem.arena_init(arena, make([]byte, size))
}

// 释放 arena 自身持有的内存块。
arena_free :: proc(arena: ^mem.Arena) {
    delete(arena.data)
}
