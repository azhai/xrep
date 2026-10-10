# Progress Log

## 2026-10-10 — 把外部命令矩阵落进仓库

### 结果
- `./verify.sh` → exit 0：单元 129 用例 + 内建自检 + golden 75 条 + 断言 34 + 51。
- 新增/改动：
  - `tests/fixtures/`（9 个输入：文本 ×2、空文件、`-f` 模式文件、目录树含隐藏项）
  - `tests/golden/`（75 条 golden，300 KB；已确认无绝对路径、无计时值）
  - `tests/run.sh`（golden 矩阵，支持 `--update` / `TESTS_FILTER`）
  - `tests/lib.sh`（断言小工具）、`tests/run2.sh`、`tests/run3.sh`
  - `verify.sh`（一条命令入口）、`.gitignore` 加 `/tests/.out/`
  - `README.md`：矩阵章节重写 + 已知缺陷 #12

### 跑过的命令
- `ls /tmp/xrep_verify/` → 不存在（脚本已不可恢复，只能重建）
- `./tests/run.sh --update ./xrep` → 75 条 golden 生成
- `./tests/run.sh ./xrep /tmp/xo_a` 与 `/tmp/xo_b` 各一次 → 均 75/75；
  两次产物 `diff -r` 仅差 outdir 自身的路径（已被 @OUT@ 归一化）→ **确定性成立**
- `./tests/run2.sh ./xrep` → 34/34
- `./tests/run3.sh ./xrep` → 51/51
- `./verify.sh` → exit 0（连续两次）

## 尝试与失败记录
1. **账本文件污染 golden（最严重）**：最初把 `.stdout/.stderr/.golden/.diff`
   与命令产出放在同一目录，`find` 把它们一起列进 golden → 表现为
   "第一次全绿、第二次成片失败（run2 33 条、run3 75 条）"，且 `.golden` 会抄自己。
   修复：产出目录 `$dir` 与账本目录 `$dir/.cap` 分开，`find` 排除 `./.cap/*`；
   并给 `rm -rf`/`mkdir` 加 `|| exit 1`，让清理失败**响亮**而不是静默。
2. **macOS bash 3.2 + `set -u`**：空数组 `"${args[@]}"` 被当成未绑定变量
   （`meta-no-args` 这条无参命令踩到）。修法：`${args[@]+"${args[@]}"}`。
3. `file_eq` 参数顺序写反（定义 `(名字, 路径, 期望)`，调用写成 `(名字, 期望, 路径)`）
   → 6 条断言误报。已统一为 `(名字, 路径, 期望内容)`。
4. `-c` 属于传统输出模式，进度条会先打一行再打结论行 → 整段 `eq` 必然失败。
   改为 `has` 匹配结论行。
5. `--max-size` 跳过的文件**连 `0 hits` 都不打印**（它是"未扫描"不是"0 命中"），
   断言从 `has "0 hits"` 改为 `eq "" "$OUT"`。
6. 期望值算错两处（fixture 里同时存在 "test"×3 与 "TEST"×1）：
   `-i TEST` 是 4 命中不是 3；大小写敏感的 `TEST` 是 1 命中不是 0。

## 顺带发现的生产缺陷（已修）
`scan.odin:260` `progress_init(&prog, u64(file_size), true, progress_on)` ——
形参是 `(p, total, use_color, enabled)`，`use_color` 被写死成 `true`，
导致 `--color never` / `--no-color` 下进度条仍输出 ANSI 绿色转义。
**已按用户指示修复**：改传 `o.use_color`，并在调用点加注释点名"两个 bool 别写反"。

修复后的验证：
- 实测四种颜色模式的 ANSI 行数：默认 4 / `--color never` 0 / `--no-color` 0 /
  `--color always` 4 / `--color auto`（非 TTY）0 —— 与 ADR 0005 的承诺一致了。
- golden 重生成后**只有 3 条命令变化**：`color-never` / `color-no-color` / `color-auto`，
  每条恰好一行（进度条去掉 ANSI）；`color-always` 及其余 71 条逐字节不变。
- `tests/run3.sh` 的颜色段从 3 条扩到 8 条断言（新增"整段 stdout 有无 ANSI"这一层），
  把这个缺陷钉死：`--color never` / `--no-color` / `--color auto` 必须**整段**无转义。
  51 → 56 条。
- README：删掉"已知行为与限制 #12（已知缺陷）"，把修正说明并入 #1（`--no-color` 真正生效）。
- `./verify.sh` → exit 0（129 单测 + 75 golden + 34 + 56）。

## 2026-10-10（续）—— 给"分片重叠窗口"加外部快照
- `tests/run.sh` 末尾新增两条命令（75 → **77**）：
  - `chunk-straddle-reported-once`：2 MiB+ 文件，"test" 埋在 `chunk-2`
    （跨越分片边界）→ 1 命中、dump 只有 1 行 —— 跨界匹配**不被切断也只报一次**。
  - `chunk-boundary-reported-twice`："test" 埋在 `chunk` 上（完全落在 16 字节重叠
    窗口内）→ 2 命中、dump 同一偏移两行 —— 已知的重复上报契约。
  - 输入由脚本在临时目录现造（`head -c /dev/zero | tr` + `dd seek` 埋点），
    不进仓库；golden 里以 `@SETUP@` 占位。
- 确定性处理：多 worker 下**逐条流式打印的先后顺序取决于调度**，所以这两条
  一律用 `-c` + `--dump`（结论行 + 归并后的 dump 都与调度无关），并在文件头
  写死"不要给它们去掉 -c"。两次独立运行的 golden 逐字节一致。

## 2026-10-10（续）—— run.sh 从 57s 降到 1.9s
- 现象：77 条命令跑 57s，其中 37s 是 **user** CPU，而 `./xrep` 单条只要 5ms。
- 定位：二分到"每条命令一次 `rm -rf`" —— 本环境（CI 沙箱）会**拦截并审计 rm**，
  单次调用约 0.5s CPU。同时它还有"单轮批量删除上限"（实测 500 个文件），
  这正是之前"第二次运行成片失败"的真凶（不是脚本逻辑错）。
- 修法：改成**每轮一棵全新的临时树** `$OUT/run-<pid>/{<name>,.cap,<name>,.setup}`，
  `trap 'rm -rf "$RUN"' EXIT` 只删一次；顺带把 `find+sed+sort` 换成 glob +
  bash 内建字符串替换（`emit_norm`），每条命令少 3~4 个子进程。
- 结果：run.sh 57s → **1.85s**，`./verify.sh` 64s → **10s**；golden 一个字节没变
  （77/77 依旧全绿），`tests/.out` 跑完即空。

## 遗留（未处理）
- `output_queue_pop` 的出队是 O(队列长度) 整体左移，密集命中下可能退化。