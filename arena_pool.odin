package main

// ============================================================================
// arena_pool.odin — Arena 对象池
//
// 职责：复用 arena 实例，避免每个扫描分片都 malloc 一块大内存（默认 16 MiB）。
//       取出时自动 reset（arena_free_all）而不归还系统内存，因此分配很快；
//       归还时同样 reset，下一次取用即为"空 arena"。
//
// 依赖：core:sync、core:mem。
// 生命周期：池内积压的 arena 由 arena_pool_destroy 统一释放；被借出未归还的
//           arena 不会出现在 free_list 中，因此调用方必须成对使用 get/put。
// ============================================================================

import "core:mem"
import "core:sync"

Arena_Pool :: struct {
    mu:         sync.Mutex,
    free_list:  [dynamic]^mem.Arena,
    block_size: uint,
}

// 预分配 init_count 个 block_size 字节的 arena，减少启动后的首次分配抖动。
arena_pool_init :: proc(p: ^Arena_Pool, block_size: uint, init_count: uint) {
    p.block_size = block_size
    p.free_list = make([dynamic]^mem.Arena, 0, init_count)
    for i in 0..<init_count {
        a := new(mem.Arena)
        arena_make(a, block_size)
        append(&p.free_list, a)
    }
}

// 借出一个已 reset 的 arena；池空则现场新建一个（容量增长不设上限）。
arena_pool_get :: proc(p: ^Arena_Pool) -> ^mem.Arena {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    if len(p.free_list) > 0 {
        a := pop(&p.free_list)
        mem.arena_free_all(a)
        return a
    }
    a := new(mem.Arena)
    arena_make(a, p.block_size)
    return a
}

// 归还 arena。reset 保证下次借出时不残留旧数据，也避免结果被误读到。
arena_pool_put :: proc(p: ^Arena_Pool, a: ^mem.Arena) {
    sync.mutex_lock(&p.mu)
    defer sync.mutex_unlock(&p.mu)
    mem.arena_free_all(a)
    append(&p.free_list, a)
}

arena_pool_destroy :: proc(p: ^Arena_Pool) {
    for a in p.free_list {
        arena_free(a)
        free(a)
    }
    delete(p.free_list)
}
