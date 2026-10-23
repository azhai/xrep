package app

// ============================================================================
// walk.odin — 目录遍历与 glob 匹配
//
// 职责：把命令行给出的"输入项"（文件或目录）展开成真正要扫描的文件路径列表。
//   * glob_match        — 纯函数：单个 glob 与路径的匹配（可单测）
//   * walk_dir          — 递归遍历目录，按 --exclude / --glob / --hidden 过滤
//   * walk_expand       — 对外入口：逐个处理输入项
//
// 依赖：core:fmt、core:os、core:slice、core:strings。
// 注：本机 Odin 没有 `core:os/os2`，因而没有现成的 walk —— 自己实现。
//
// glob 语义（与 shell/grep 的常见约定一致）：
//   `*`  匹配任意长度的字符，**不跨** `/`；
//   `**` 匹配任意长度（含 `/`），用于跨目录；
//   `?`  匹配单个字符，**不匹配** `/`；
//   `\`  转义下一个字符（使 `*` `?` 可按字面量匹配）。
//   模式中**不含 `/`** 时只与路径的 basename 比较 —— 于是 `--glob='*.bin'`
//   能在任意深度命中所有 .bin 文件，符合直觉。
//
// 过滤规则（与 grep 一致的分工）：
//   * 目录：只受 `--exclude` 与 `--hidden` 约束。若 `--glob` 也作用于目录，
//     `--glob='*.bin'` 会让所有子目录都不匹配、直接不下降，显然不对。
//   * 文件：`--exclude` 命中即跳过；`--glob` 非空时必须至少命中一条。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "xrep:lib"

// ---------------------------------------------------------------------------
// glob 匹配
// ---------------------------------------------------------------------------

// glob 匹配的递归核心。
// pat[pi:] 是剩余模式，s[si:] 是剩余路径。除 `*` 外均为单步推进；
// `*` / `**` 处需要对"星号吃掉多少字符"做回溯（其余分支唯一，无需回溯）。
// 注意：Odin 的 proc 形参不可赋值，故用局部变量 p / i 推进游标。
glob_match_here :: proc(pat: string, pi0: int, s: string, si0: int) -> bool {
    p := pi0
    i := si0
    for p < len(pat) {
        c := pat[p]
        switch c {
        case '*':
            // 把连续的 '*' 折叠成一个：出现两个及以上即视为 `**`（可跨 `/`）。
            double := false
            np := p + 1
            for np < len(pat) && pat[np] == '*' {
                np += 1
                double = true
            }
            if np == len(pat) {
                // 尾随星号：`**` 吃掉剩余全部；单个 `*` 只能在当前目录内吃掉。
                if double {
                    return true
                }
                for k := i; k < len(s); k += 1 {
                    if s[k] == '/' {
                        return false
                    }
                }
                return true
            }
            for k := i; k <= len(s); k += 1 {
                if glob_match_here(pat, np, s, k) {
                    return true
                }
                // 单 `*` 不得跨目录分隔符：遇到 '/' 就不能再多吃。
                if !double && k < len(s) && s[k] == '/' {
                    break
                }
            }
            return false
        case '?':
            if i >= len(s) || s[i] == '/' {
                return false
            }
            p += 1
            i += 1
        case '\\':
            // 转义：下一个模式字符按字面量比较。
            if p + 1 < len(pat) {
                if i >= len(s) || s[i] != pat[p + 1] {
                    return false
                }
                p += 2
                i += 1
            } else {
                if i >= len(s) || s[i] != '\\' {
                    return false
                }
                p += 1
                i += 1
            }
        case:
            if i >= len(s) || s[i] != c {
                return false
            }
            p += 1
            i += 1
        }
    }
    // 模式耗尽时，路径也必须刚好耗尽才算匹配。
    return i == len(s)
}

// glob_match 判断 path 是否匹配 pattern。模式不含 `/` 时只比 basename。
glob_match :: proc(pattern: string, path: string) -> bool {
    if !strings.contains(pattern, "/") {
        name := path
        if i := strings.last_index_byte(path, '/'); i >= 0 {
            name = path[i + 1:]
        }
        return glob_match_here(pattern, 0, name, 0)
    }
    return glob_match_here(pattern, 0, path, 0)
}

// ---------------------------------------------------------------------------
// 遍历
// ---------------------------------------------------------------------------

// 去掉路径开头的若干 "./"，让 `./src/x.bin` 能匹配模式 `src/*.bin`。
// 仅用于"拿去做 glob 比较"，返回的仍是原字符串的切片视图。
strip_dot_slash :: proc(p: string) -> string {
    out := p
    for len(out) >= 2 && out[0] == '.' && out[1] == '/' {
        out = out[2:]
    }
    return out
}

// 拼接目录与条目名，避免出现 `dir//name`（目录以 '/' 结尾时直接相接）。
// 返回新分配的字符串，调用方负责 delete。
join_path :: proc(dir: string, name: string) -> string {
    if len(dir) > 0 && dir[len(dir) - 1] == '/' {
        return fmt.aprintf("%s%s", dir, name)
    }
    return fmt.aprintf("%s/%s", dir, name)
}

// 隐藏项判定：`.` 开头（含 "." 与 ".."）在未开 --hidden 时一律跳过。
walk_hidden :: proc(name: string, show_hidden: bool) -> bool {
    if show_hidden {
        return false
    }
    return len(name) > 0 && name[0] == '.'
}

// 是否被 --exclude 排除。
walk_excluded :: proc(match_path: string, o: lib.Walk_Options) -> bool {
    for ex in o.excludes {
        if glob_match(ex, match_path) {
            return true
        }
    }
    return false
}

// 文件是否被 --glob 接受（globs 为空视为全收）。
walk_glob_ok :: proc(match_path: string, o: lib.Walk_Options) -> bool {
    if len(o.globs) == 0 {
        return true
    }
    for g in o.globs {
        if glob_match(g, match_path) {
            return true
        }
    }
    return false
}

// 递归遍历目录 dir，把通过过滤的**常规文件**路径追加到 out（调用方拥有字符串）。
// 输出顺序按条目名排序，保证同一目录树在不同文件系统下得到相同顺序（便于测试与对照）。
walk_dir :: proc(dir: string, o: lib.Walk_Options, out: ^[dynamic]string) {
    entries, err := os.read_directory_by_path(dir, -1, context.allocator)
    if err != nil {
        fmt.fprintf(os.stderr, "xrep: cannot read directory %s: %v\n", dir, err)
        return
    }
    // read_directory_by_path 会 clone 每个 File_Info.fullpath，必须逐个归还。
    defer {
        for e in entries {
            os.file_info_delete(e, context.allocator)
        }
        delete(entries)
    }
    slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })

    for e in entries {
        if walk_hidden(e.name, o.hidden) {
            continue
        }
        full := join_path(dir, e.name)
        match_path := strip_dot_slash(full)
        #partial switch e.type {
        case .Directory:
            // 目录只受 exclude 约束（见文件头说明），且不跟随符号链接目录，
            // 以免目录环导致无限递归。
            if walk_excluded(match_path, o) {
                delete(full)
                continue
            }
            if o.recursive {
                walk_dir(full, o, out)
            }
            delete(full)
        case .Regular:
            if walk_excluded(match_path, o) || !walk_glob_ok(match_path, o) {
                delete(full)
                continue
            }
            append(out, full)
        case:
            // 符号链接 / 管道 / 套接字等一律跳过：本工具面向常规文件。
            delete(full)
        }
    }
}

// 展开输入项列表为待扫描文件列表。
// 规则：
//   * 目录 → 仅在 --recursive 时展开；否则报 stderr 并跳过（与"文件不存在"同样不致命）。
//   * 其它路径 → **原样保留**，交给 scan_file 处理。刻意不在此处做存在性过滤：
//     既有行为是 `open <path> failed: ...` 写 stderr、退出码 0，过滤掉会改变可观察行为。
// 返回的动态数组与其中的字符串都归调用方所有。
walk_expand :: proc(inputs: []string, o: lib.Walk_Options) -> [dynamic]string {
    out: [dynamic]string
    for p in inputs {
        if os.is_dir(p) {
            if !o.recursive {
                fmt.fprintf(os.stderr, "xrep: %s: is a directory (use -r to search recursively)\n", p)
                continue
            }
            match_path := strip_dot_slash(p)
            if walk_excluded(match_path, o) {
                continue
            }
            walk_dir(p, o, &out)
            continue
        }
        append(&out, strings.clone(p))
    }
    return out
}

// 释放 walk_expand / walk_dir 产出的字符串与切片。
walk_free :: proc(paths: ^[dynamic]string) {
    for p in paths {
        delete(p)
    }
    delete(paths^)
}
