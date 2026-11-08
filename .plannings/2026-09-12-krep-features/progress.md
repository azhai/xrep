# 执行日志：krep 功能对齐

## 2026-09-12
- 读 AGENTS.md / krep README / 现有生产代码（cli、scan、main、io_utils、worker、common、matcher、selftest）。
- 核查 Odin API：无 `core:os/os2`（无现成 walk），用 `os.read_directory_by_path` 自己写。
- 建立基线二进制：`cp xrep /tmp/xrep_krep_before`。
- 用户决策落定：核心档 + 行导向新增、偏移输出保留默认。
- 创建本规划目录。
