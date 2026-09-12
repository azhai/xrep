package main

// ============================================================================
// arena_pool_test.odin — Arena 对象池单元测试
//
// 覆盖：预分配数量、借出即重置（内存为干净状态）、归还后复用同一实例、
//       池空时自动扩容、销毁时不重复释放已借出实例。
// 注意：借出后必须归还，否则 arena_pool_destroy 不会释放它（既有语义）。
// ============================================================================

import "core:mem"
import "core:testing"

@(test)
test_arena_pool_prealloc_and_get :: proc(t: ^testing.T) {
    p: Arena_Pool
    arena_pool_init(&p, 4096, 2)
    defer arena_pool_destroy(&p)

    testing.expect_value(t, len(p.free_list), 2)
    testing.expect_value(t, p.block_size, uint(4096))

    a := arena_pool_get(&p)
    testing.expect(t, a != nil, "应借出非空 arena")
    testing.expect_value(t, len(a.data), 4096)
    testing.expect_value(t, len(p.free_list), 1)

    b := arena_pool_get(&p)
    testing.expect_value(t, len(p.free_list), 0)
    // 池空时自动新建，容量与 block_size 一致
    c := arena_pool_get(&p)
    testing.expect_value(t, len(c.data), 4096)

    arena_pool_put(&p, a)
    arena_pool_put(&p, b)
    arena_pool_put(&p, c)
    testing.expect_value(t, len(p.free_list), 3)
}

@(test)
test_arena_pool_put_resets_and_reuses :: proc(t: ^testing.T) {
    p: Arena_Pool
    arena_pool_init(&p, 1024, 1)
    defer arena_pool_destroy(&p)

    a := arena_pool_get(&p)
    // 在借出的 arena 上分配，模拟 worker 产出命中结果
    alloc := mem.arena_allocator(a)
    buf := make([]u8, 256, alloc)
    testing.expect_value(t, len(buf), 256)
    testing.expect(t, a.offset > 0, "借出的 arena 应已被使用")

    // 归还时必须 reset（free_all），否则下次借出会残留脏数据
    arena_pool_put(&p, a)
    testing.expect_value(t, a.offset, 0)

    // 复用同一实例：地址相同，且内存干净
    got := arena_pool_get(&p)
    testing.expect(t, got == a, "应复用归还的 arena 实例")
    testing.expect_value(t, got.offset, 0)

    arena_pool_put(&p, got)
}
