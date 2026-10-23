package lib

// ============================================================================
// options.odin — 运行期「数据」定义（CLI 选项 / 扫描选项 / 遍历选项）
//
// 职责：只放**数据**。这里没有一行行为代码：解析在 app/cli.odin，
//       扫描编排在 app/scan.odin，目录遍历在 app/walk.odin。
//       三者都消费这里的类型，因此它们必须住在一个谁都能引用、
//       且不反向依赖任何人的包里 —— 这就是 lib（见 ADR 0007）。
//
// 为什么从 app 搬出来（ADR 0007）：
//   - `Options` 由 cli 产出，却被 main / scan / walk / selftest / bench 消费；
//   - `Scan_Options` 由 main 从 Options 映射而来，scan 与 bench 都要构造；
//   - `Walk_Options` 由 cli 映射、walk 消费。
//   它们都是跨模块流转的数据，放在 app 里会让"数据"跟着某个消费者走，
//   新增消费者时要么反向依赖 app，要么再抄一份结构。
//
// 字段语义的权威说明在 README「命令行选项」；此处只保留归属与所有权说明。
// ============================================================================

// -l / -L 的模式：列出"有命中"或"无命中"的文件。
List_Mode :: enum {
    None, // 默认：打印命中明细
    Files_With, // -l：只列有命中的文件名
    Files_Without, // -L：只列无命中的文件名
}

// parse_args 的结果分类。**不决定进程存活** —— 退出策略交给调用方（main），
// 这样参数解析（含所有错误分支）可以被单元测试完整覆盖。
//   .Ok      → 解析成功，继续主流程
//   .Help    → 调用方打印帮助并退出 0
//   .Version → 调用方打印版本并退出 0
//   .Error   → 调用方把 message 写入 stderr 并退出 1
Parse_Outcome :: enum {
    Ok,
    Help,
    Version,
    Error,
}

// 解析后的全部运行选项。字段默认值与拆分前的局部变量初始化一一对应。
//
// 内存所有权（重要）：以下字段由 parse_args 分配，**调用方必须调用
// options_destroy 释放**（main 会调用；单元测试也必须调用，否则内存追踪器报 leak）：
//   file_list / patterns / pattern_extra / globs / excludes / pattern_buffers
// 其中各字符串元素多为 os.args 的视图（不单独释放），
// 只有 pattern_buffers 里的内容是真正分配的（`-f FILE` 读入的文件内容）。
Options :: struct {
    pattern:       []u8, // 主模式（无 -e 时来自位置参数；有 -e 时即 patterns[0]）
    patterns:      [dynamic]string, // -e / -f 收集到的全部模式（可空）
    pattern_extra: [][]u8, // patterns[1:] 的字节视图；由 match_ctx_from_options 填充
    pattern_buffers: [dynamic][]byte, // -f 读入的文件内容（真正分配，需释放）
    file_list:     [dynamic]string, // 其余非 flag 参数
    ignore_case:   bool, // --ignore-case
    limit:         uint, // --limit N（0 = 不截断 pretty 输出）
    after:         u64, // --after N，命中偏移下界
    before:        u64, // --before N，命中偏移上界
    context_bytes: uint, // --context N
    run_test:      bool, // --test
    do_bench:      bool, // --bench
    only_count:    bool, // --count
    thread_count:  uint, // --threads N
    offset_hex:    bool, // --offset-hex
    dump_path:     string, // --dump FILE
    dump_prefix:   string, // --dump-prefix P
    quiet:         bool, // --quiet
    skip_empty:    bool, // --skip-empty：命中 0 条时不产出 dump 文件
    dump_append:   bool, // --dump-append：dump 改为追加写
    max_size:      u64, // --max-size N：跳过大于 N 字节的文件（0 = 不限制）

    // ---- 目录遍历（对齐 krep）----
    recursive: bool, // -r / --recursive
    hidden:    bool, // --hidden
    globs:     [dynamic]string, // --glob，可重复
    excludes:  [dynamic]string, // --exclude，可重复

    // ---- 输出与匹配（对齐 krep）----
    line_numbers:  bool, // -n / --line-number
    only_matching: bool, // -o / --only-matching
    max_count:     uint, // -m / --max-count（0 = 不限）
    json:          bool, // --json / --jsonl
    stats:         bool, // --stats
    color_mode:    Color_Mode, // --color=WHEN / --no-color
    list_mode:     List_Mode, // -l / -L
}

// 目录遍历选项。由 cli.Options 映射而来。
Walk_Options :: struct {
    recursive: bool, // -r/--recursive
    hidden:    bool, // --hidden：把 . 开头的条目也纳入
    globs:     []string, // --glob，可重复；空表示全收
    excludes:  []string, // --exclude，可重复
}

// 一次扫描的全部选项。由 main 从 cli.Options 映射而来；测试直接构造。
//
// 以结构体而非一长串位置参数传入：本函数参数已随功能增多接近两位数，
// 用结构体承载可避免调用点出现一长串同类型实参（易错且难读）。
Scan_Options :: struct {
    ctx:           Match_Ctx, // 模式与大小写选项
    after:         u64, // 命中偏移下界（闭区间）
    before:        u64, // 命中偏移上界（闭区间）
    limit:         uint, // 仅截断 pretty 汇总（0 = 不截断；见 README 已知行为#3）
    context_bytes: uint, // 命中前后展示的字节数
    only_count:    bool, // 只打印命中总数
    thread_count:  uint, // worker 线程数（<=0 时按 1 处理）
    offset_hex:    bool, // 打印/落盘用十六进制偏移
    dump_path:     string, // --dump 的目标文件（单文件汇总）
    dump_prefix:   string, // --dump-prefix 的前缀
    quiet:         bool, // 完全静默：不打印统计，仅 dump 与 stderr 错误
    skip_empty:    bool, // 命中 0 条时不落盘（--skip-empty）
    dump_append:   bool, // 落盘改为追加（--dump-append）
    max_size:      u64, // >0 时跳过超过该字节数的文件（--max-size）

    // ---- 展示层（对齐 krep）----
    path_label:    string, // 展示用文件名；空则回退到真实 path
    show_path:     bool, // 行导向：输出 `path[:line]:offset`（多文件 / -r 时启用）
    line_numbers:  bool, // -n
    only_matching: bool, // -o
    max_count:     uint, // -m（0 = 不限）
    json:          bool, // --json / --jsonl
    list_mode:     List_Mode, // -l / -L
    use_color:     bool, // 已解析的颜色开关（来自 --color / --no-color）
    stats:         ^Run_Stats, // 可为 nil；非 nil 时累加统计
}
