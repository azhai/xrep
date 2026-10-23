#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Odin 源码「包级重构」工具（词法感知）。

为什么会有这个文件（ADR 0006 记录的两个坑）：

  坑 1 —— 批量给符号加「包名前缀」时用无脑正则替换，**字符串字面量会被一起
           改掉**：`fmt.println("OK slice_map")` 变成
           `fmt.println("OK search.slice_map")`，程序的**输出文本被静默改坏**，
           而 golden 矩阵要跑完才发现。反向操作（去掉自引用前缀）同样会削掉
           字符串里的内容：`"xrep GET app.log"` 变成 `"xrep GET log"`。
  坑 2 —— 提取「顶层声明」时只匹配 `name ::`，漏掉用 `:` 声明的全局变量
           （`lower_table: [256]u8`）和用 `:=` 声明的（`alg_table := [?]...`），
           这些符号因此拿不到前缀，编译报 `Undeclared name`。

对策：

  * **词法感知** —— 替换只作用于 code 区间。双引号字符串、反引号 raw string、
    字符字面量、`//` 行注释、`/* */` 块注释全部按区间屏蔽，一个字都改不到。
  * **声明提取认三种形式** —— `name ::` / `name :=` / `name :`（非 `::`），
    且只认列 0 且花括号深度为 0 的行；struct 字段是缩进且在花括号内，天然不会混入。

安全取向（重要，决定了下面这些"保守"规则）：

    **过度限定会静默改坏数据；漏限定只会在编译期大声报错。**
    所以凡有歧义一律不动 —— 成员访问（`.` 之后）、`@(attr)` 内、
    `#directive` 之后、`package`/`import` 之后、Odin 关键字、`context`，
    以及花括号/圆括号内的 `ident:` / `ident =`（结构体字段、字面量字段、参数名）。
    保护按**位置**记录而不是按名字：`x[CHUNK_OVERLAP:]` 是切片，那里的冒号不是
    字段分隔符，若按名字保护会把同一文件里其它正常用法连带漏掉（复现测试抓到过）。

子命令（选项跟在子命令后面）：
  symbols         打印各包顶层声明（供人核对）
  qualify         加包名前缀 + 同步 import（默认 dry-run 只打 diff，--write 才落盘）
  strip-self      去掉本包自引用前缀（默认 dry-run，--write 才落盘）
  check-literals  护栏：字符串字面量里出现 `<包>.<本包已知符号>` 即报错
  selftest        内置回归用例（含"旧错误做法确实会改坏"的反向断言）

用法示例：
  # 目录已拆成 lib/ search/ engine/ app/
  python3 tools/odin_qualify.py qualify --packages lib search engine app

  # 尚未拆（flat 布局），用 `包名=文件.odin,文件.odin` 指定归属
  python3 tools/odin_qualify.py qualify --packages lib=base.odin \
      search=matcher.odin,merge.odin,slice_utils.odin

  # 护栏（已接进 verify.sh 与 make guard）
  python3 tools/odin_qualify.py check-literals

依赖：Python 3.8+ 标准库，无第三方包。
"""

import argparse
import difflib
import os
import re
import sys

# Odin 关键字。这些词不会被当成符号加前缀。
KEYWORDS = set("""
package import foreign when where if else for switch case break continue return defer
proc struct union enum map bit_set bit_field matrix using context or_return
or_else or_break or_continue in not_in do nil true false cast transmute auto_cast
distinct opaque dynamic_array fixed_array array soa_slice cstring string rune
""".split())

# `context` 是 Odin 内置变量（`context = runtime.default_context()`），
# 且本项目大量出现，绝不能改。
ALWAYS_PROTECT = {'context'}

DEFAULT_PACKAGES = ('lib', 'search', 'engine', 'app')
DEFAULT_MAIN = 'main.odin'

_IDENT_RE = re.compile(r'(?<![\w.])[A-Za-z_]\w*')
_IDENT_FULL = re.compile(r'^[A-Za-z_]\w*$')
_DECL_RE = re.compile(r'^([A-Za-z_]\w*)\s*(::|:=|:(?!:))')


# ---------------------------------------------------------------------------
# 词法扫描：把源码切成「非 code 区间」（字符串/字符/注释），其余即 code
# ---------------------------------------------------------------------------

class Source(object):
    """带词法区间信息的 Odin 源文件。"""

    def __init__(self, text, path='<memory>'):
        self.text = text
        self.path = path
        self.n = len(text)
        self.spans = self._scan(text)              # [(kind, start, end)] 非 code
        self.code = self._complement(self.spans)   # [(start, end)] code
        self._mask = None
        self._depths = None

    @staticmethod
    def _scan(src):
        spans = []
        i, n = 0, len(src)
        while i < n:
            c = src[i]
            if c == '"':
                j = i + 1
                while j < n:
                    if src[j] == '\\':
                        j += 2
                        continue
                    if src[j] == '"':
                        break
                    j += 1
                j = min(j + 1, n)
                spans.append(('string', i, j))
                i = j
            elif c == '`':                          # raw string
                j = src.find('`', i + 1)
                j = n if j < 0 else j + 1
                spans.append(('string', i, j))
                i = j
            elif c == "'":                          # rune literal
                j = i + 1
                while j < n:
                    if src[j] == '\\':
                        j += 2
                        continue
                    if src[j] == "'":
                        break
                    j += 1
                j = min(j + 1, n)
                spans.append(('rune', i, j))
                i = j
            elif c == '/' and i + 1 < n and src[i + 1] == '/':
                j = src.find('\n', i)
                j = n if j < 0 else j
                spans.append(('comment', i, j))
                i = j
            elif c == '/' and i + 1 < n and src[i + 1] == '*':
                j = src.find('*/', i + 2)
                j = n if j < 0 else j + 2
                spans.append(('comment', i, j))
                i = j
            else:
                i += 1
        return spans

    def _complement(self, spans):
        out, pos = [], 0
        for _kind, s, e in spans:
            if s > pos:
                out.append((pos, s))
            pos = max(pos, e)
        if pos < self.n:
            out.append((pos, self.n))
        return out

    @property
    def mask(self):
        """bytearray：1 = code，0 = 字符串/注释。"""
        if self._mask is None:
            m = bytearray(self.n)
            for s, e in self.code:
                for i in range(s, e):
                    m[i] = 1
            self._mask = m
        return self._mask

    @property
    def depths(self):
        """(花括号, 花括号+圆括号, 方括号) 三张深度表；下标 i 表示"字符 i 之前"的深度。

        只看 code 区间，所以字符串/注释里的括号不计入。三张分开是为了区分：
          * 花括号 —— 判断是否在 struct/proc 体/字面量里（顶层声明判定用）
          * 圆括号 —— proc 参数名 `proc(s2b: int)` 也要保护
          * 方括号 —— `x[CHUNK_OVERLAP:]` 是**切片**，那里的冒号不是字段分隔符，
            不能据此保护（否则这个名字在别处的用法会被连带漏掉）
        """
        if self._depths is None:
            nb = self.n + 1
            brace = bytearray(nb)
            cont = bytearray(nb)
            brack = bytearray(nb)
            b = c = k = 0
            for s, e in self.code:
                for i in range(s, e):
                    brace[i], cont[i], brack[i] = b, c, k
                    ch = self.text[i]
                    if ch == '{':
                        b += 1
                        c += 1
                    elif ch == '}':
                        b = max(0, b - 1)
                        c = max(0, c - 1)
                    elif ch == '(':
                        c += 1
                    elif ch == ')':
                        c = max(0, c - 1)
                    elif ch == '[':
                        k += 1
                    elif ch == ']':
                        k = max(0, k - 1)
                brace[e], cont[e], brack[e] = b, c, k
            self._depths = (brace, cont, brack)
        return self._depths

    @property
    def depth_before(self):
        """花括号深度（顶层声明判定用，见 declarations()）。"""
        return self.depths[0]

    def line_starts(self):
        """[(行起始偏移, 行内容)]。"""
        out, pos = [], 0
        for line in self.text.split('\n'):
            out.append((pos, line))
            pos += len(line) + 1
        return out

    def tokens(self):
        """code 区间内的 token 流：[(text, start, end)]。"""
        toks = []
        pat = re.compile(r'[A-Za-z_]\w*|.')
        for s, e in self.code:
            for m in pat.finditer(self.text, s, e):
                toks.append((m.group(0), m.start(), m.end()))
        return toks

    def literals(self):
        """所有字符串/字符字面量：[(text, start, end)]。"""
        return [(self.text[s:e], s, e) for k, s, e in self.spans
                if k in ('string', 'rune')]


# ---------------------------------------------------------------------------
# 顶层声明提取（坑 2 的修复点：:: / := / : 三种都认）
# ---------------------------------------------------------------------------

def declarations(src):
    """本文件的顶层声明名集合。

    判定条件：行首（列 0）是 code、是标识符、且该行花括号深度为 0。
    后者很关键 —— 否则结构体字段（缩进且在 {} 内）可能被误当成顶层声明。
    """
    names = set()
    mask, depth = src.mask, src.depth_before
    for pos, line in src.line_starts():
        if not line or mask[pos] != 1 or not re.match(r'[A-Za-z_]', line[0]):
            continue
        if depth[pos] != 0:
            continue
        m = _DECL_RE.match(line)
        if m:
            names.add(m.group(1))
    return names


# ---------------------------------------------------------------------------
# 「不可碰」位置集合（过度限定会静默改坏数据，所以保守）
# ---------------------------------------------------------------------------

def protected_positions(src):
    """一组绝对偏移：这些位置的标识符**不允许**被加包名前缀。

    关键设计：保护按**位置**记录，不是按名字。曾经按名字保护，结果
    `data_b[b + CHUNK_OVERLAP:]`（切片语法）里的 CHUNK_OVERLAP 被当成字段保护，
    同一文件里 `fmt.aprintf(..., CHUNK_OVERLAP)` 这种正常用法也被连带跳过，
    编译报 Undeclared —— 这是"从 HEAD 复现拆分"的测试抓出来的真 bug。

    规则：
      1. `.` / `package` / `import` / `@` / `#` 之后的标识符
      2. `@(attr)` 括号内的标识符
      3. 花括号或圆括号内、且后跟 `:` 或 `=` 的标识符 —— 结构体字段、
         字面量字段、proc 参数名。**方括号内不算**（那是切片 `x[SYM:]`）
    关键字与 `context` 由调用方单独判断，不进这里。
    """
    prot = set()
    toks = src.tokens()
    _brace, cont, brack = src.depths
    for idx in range(len(toks)):
        tok, s, _e = toks[idx]
        if not _IDENT_FULL.match(tok):
            continue
        prev = toks[idx - 1][0] if idx > 0 else None
        if prev in ('.', 'package', 'import', '@', '#'):
            prot.add(s)
            continue
        if _inside_attr(toks, idx):
            prot.add(s)
            continue
        if cont[s] > 0 and brack[s] == 0 and _next_nonws(toks, idx) in (':', '='):
            prot.add(s)
    return prot


def _inside_attr(toks, idx):
    """idx 处的 token 是否位于 @( ... ) 之内。自 idx 往前找第一个未闭合的 '('，
    看它前面是不是 '@'。"""
    depth = 0
    for j in range(idx - 1, -1, -1):
        t = toks[j][0]
        if t == ')':
            depth += 1
        elif t == '(':
            if depth == 0:
                return j > 0 and toks[j - 1][0] == '@'
            depth -= 1
        elif t in ('{', '}'):
            return False
    return False


def _next_nonws(toks, idx):
    for j in range(idx + 1, len(toks)):
        if not toks[j][0].isspace():
            return toks[j][0]
    return None


_LOCAL_DECL_RE = re.compile(r'^\s*(?:var\s+)?([A-Za-z_]\w*)'
                            r'(?:\s*,\s*[A-Za-z_]\w*)*\s*(?::=|=)')


def local_names(src):
    """本文件函数体内的局部变量名（`x := ...`、`a, b := ...`、`var x: T = ...`）。

    用来避免"与某包全局同名的局部变量"被误加前缀 —— main.odin 里就有
    `scan_opts := Scan_Options{...}`（局部）撞上 app 包的全局 `scan_opts`，
    误加后会变成 `app.scan_opts` 而编译不过。这是"从 HEAD 复现拆分"抓到的
    第二个真 bug。

    只认圆括号/花括号深度 > 0 的行，所以顶层声明不会混进来。
    """
    names = set()
    mask = src.mask
    _brace, cont, _brack = src.depths
    for pos, line in src.line_starts():
        if not line or mask[pos] != 1 or cont[pos] == 0:
            continue
        m = _LOCAL_DECL_RE.match(line)
        if m:
            head = line[:m.end()]
            head = head.split(':=')[0].split('=')[0]
            head = re.sub(r'^\s*var\s+', '', head)
            names.update(re.findall(r'[A-Za-z_]\w*', head))
    return names


# ---------------------------------------------------------------------------
# 替换（坑 1 的修复点：只动 code 区间）
# ---------------------------------------------------------------------------

def _rewrite(src, fn, pattern=None):
    """对每个 code 区间里 pattern 命中的文本调用 fn(match, 段起始偏移) -> 替换文本。

    只遍历 code 区间，所以字符串/注释/字符字面量里的内容根本不会进入 fn
    （坑 1 的修复点）。fn 返回 None 表示保持原样。
    注意：match 的 start/end 是**段内**偏移，换算绝对位置要加 段起始偏移。
    """
    pat = pattern if pattern is not None else _IDENT_RE
    out, last = [], 0
    for s, e in src.code:
        seg = src.text[s:e]
        pieces, seg_last = [], 0
        for m in pat.finditer(seg):
            rep = fn(m, s)
            if rep is not None and rep != m.group(0):
                pieces.append(seg[seg_last:m.start()])
                pieces.append(rep)
                seg_last = m.end()
        if pieces:
            pieces.append(seg[seg_last:])
            out.append(src.text[last:s])
            out.append(''.join(pieces))
            last = e
    out.append(src.text[last:])
    return ''.join(out)


def qualify(src, mapping, own):
    """给 mapping 中**非本包**的符号加 `包.` 前缀。"""
    prot = protected_positions(src)
    # 局部变量与某包全局同名时，按名字保护整个文件（漏限定只会编译报错，安全方向）。
    # 只在真的撞名时才启用，避免无谓的连带漏限定。
    foreign = set()
    for pkg, names in mapping.items():
        if pkg != own:
            foreign |= names
    shadowed = local_names(src) & foreign

    def fn(m, seg_start):
        tok = m.group(0)
        if tok in KEYWORDS or tok in ALWAYS_PROTECT:
            return None
        if tok in shadowed:
            return None
        if (seg_start + m.start()) in prot:
            return None
        for pkg, names in mapping.items():
            if pkg != own and tok in names:
                return pkg + '.' + tok
        return None

    return _rewrite(src, fn)


def strip_self(src, own, own_names):
    """去掉 `own.` 自引用前缀。

    pattern 自带点号（`search.`），所以不会留下孤立的 `.`。
    只有点号后面紧跟**本包已知符号**时才删 —— 避免误伤同名的局部变量 /
    结构体字段。删除后留下的符号由 _IDENT_RE 单独匹配到，保持原样。
    """
    pat = re.compile(r'(?<![\w.])' + re.escape(own) + r'\.')

    def fn(m, seg_start):
        nxt = re.match(r'[A-Za-z_]\w*', src.text[seg_start + m.end():])
        if nxt and nxt.group(0) in own_names:
            return ''
        return None

    return _rewrite(src, fn, pat)


# ---------------------------------------------------------------------------
# import 同步
# ---------------------------------------------------------------------------

_XREP_IMPORT_RE = re.compile(r'^import "xrep:([A-Za-z_]\w*)"$')
_ANY_IMPORT_RE = re.compile(r'^import\s')
_PACKAGE_RE = re.compile(r'^package\s+\w+$')


def sync_imports(text, own, packages):
    """按文件里实际用到的 `包.` 前缀重写 `import "xrep:..."` 块。

    兄弟包必须显式 import（Odin 的 import 路径相对**源文件所在目录**解析），
    所以加了前缀就得补 import，否则编译报 Undeclared。同时删掉不再使用的。
    只动整行的 xrp import，`core:` 导入原样保留。
    """
    src = Source(text)
    pat = re.compile(r'\b(?:%s)\.(?=[A-Za-z_])'
                     % '|'.join(map(re.escape, packages)))
    used = set()
    for s, e in src.code:
        for m in pat.finditer(text[s:e]):
            used.add(m.group(0)[:-1])
    used.discard(own)

    lines = text.split('\n')
    starts = src.line_starts()
    pkg_line, import_idx, xrp_set = None, [], set()
    for i, line in enumerate(lines):
        pos = starts[i][0]
        if pos < len(src.mask) and src.mask[pos] != 1:
            continue                          # 字符串/注释里的伪 import 行
        st = line.strip()
        if pkg_line is None and _PACKAGE_RE.match(st):
            pkg_line = i
        if _ANY_IMPORT_RE.match(st):
            import_idx.append(i)
            m = _XREP_IMPORT_RE.match(st)
            if m:
                xrp_set.add(i)

    have = [lines[i] for i in sorted(xrp_set)]
    want = ['import "xrep:%s"' % p for p in sorted(used)]
    if have == want:
        return text                           # 已经一致，别动

    keep_idx = [i for i in range(len(lines)) if i not in xrp_set]
    # 插入点：最后一个**非 xrp** import 之后；没有就放 package 行之后。
    non_xrp = [i for i in import_idx if i not in xrp_set]
    anchor = non_xrp[-1] if non_xrp else pkg_line
    insert_pos = 0 if anchor is None else sum(1 for i in keep_idx if i <= anchor)

    out = []
    for k, i in enumerate(keep_idx):
        if k == insert_pos:
            out.extend(want)
        out.append(lines[i])
    if insert_pos >= len(keep_idx):
        out.extend(want)
    return '\n'.join(out)


# ---------------------------------------------------------------------------
# 项目遍历
# ---------------------------------------------------------------------------

def parse_packages(specs):
    """把 --packages 的参数解析成 {包名: None(目录模式) 或 [文件名](flat 模式)}。

    目录模式：`--packages lib search`       -> lib/、search/ 目录
    flat 模式：`--packages lib=base.odin` -> 根目录下的单个文件
    两种模式可以混用，方便在"目录已拆"和"尚未拆"的两种布局上跑同一套逻辑。
    """
    out = {}
    for spec in specs:
        if '=' in spec:
            pkg, files = spec.split('=', 1)
            out[pkg] = [f.strip() for f in files.split(',') if f.strip()]
        else:
            out[spec] = None
    return out


def iter_sources(root, pkgmap, main):
    """[(路径, own_pkg)]；main 的 own 为 None。"""
    files = []
    for pkg, members in pkgmap.items():
        if members is None:
            d = os.path.join(root, pkg)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                if fn.endswith('.odin'):
                    files.append((os.path.join(d, fn), pkg))
        else:
            for f in members:
                p = os.path.join(root, f)
                if os.path.isfile(p):
                    files.append((p, pkg))
    m = os.path.join(root, main)
    if os.path.isfile(m):
        files.append((m, None))
    return files


def build_mapping(root, pkgmap, main):
    """pkg -> set(顶层声明名)。"""
    mapping = {}
    for path, pkg in iter_sources(root, pkgmap, main):
        if pkg is None:
            continue
        with open(path, 'r', encoding='utf-8') as f:
            mapping.setdefault(pkg, set()).update(declarations(Source(f.read())))
    return mapping


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_symbols(args):
    mapping = build_mapping(args.root, args.pkgmap, args.main)
    for pkg in args.pkgmap:
        names = sorted(mapping.get(pkg, ()))
        print('%s (%d): %s' % (pkg, len(names), ' '.join(names)))
    return 0


def cmd_qualify(args):
    mapping = build_mapping(args.root, args.pkgmap, args.main)
    changed = []
    for path, own in iter_sources(args.root, args.pkgmap, args.main):
        with open(path, 'r', encoding='utf-8') as f:
            old = f.read()
        new = qualify(Source(old, path), mapping, own)
        if not args.no_sync_imports:
            new = sync_imports(new, own, list(args.pkgmap))
        if new != old:
            changed.append((path, old, new))
    return _emit(args, changed, 'qualify')


def cmd_strip_self(args):
    mapping = build_mapping(args.root, args.pkgmap, args.main)
    changed = []
    for path, own in iter_sources(args.root, args.pkgmap, args.main):
        if own is None:
            continue
        with open(path, 'r', encoding='utf-8') as f:
            old = f.read()
        new = strip_self(Source(old, path), own, mapping.get(own, set()))
        if new != old:
            changed.append((path, old, new))
    return _emit(args, changed, 'strip-self')


def _emit(args, changed, label):
    if not changed:
        print('%s：无需改动。' % label)
        return 0
    for path, old, new in changed:
        diff = difflib.unified_diff(
            old.split('\n'), new.split('\n'),
            fromfile=path, tofile=path + ' (rewritten)', lineterm='')
        print('\n'.join(diff))
        if args.write:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(new)
    print('%s：%d 个文件受影响%s' % (label, len(changed),
                                  '（已写入）' if args.write else '（dry-run，加 --write 落盘）'))
    return 0


def find_literal_pollution(src, mapping, allows=()):
    """在字符串字面量里找 `<包>.<该包已知符号>`。

    判别式设计：只在该点号后面的名字**确实是某个包的顶层声明**时才报警。
    因此 `"xrep GET app.log"`（`log` 不是 app 的符号）不会误报，
    而 `"OK search.slice_map"`（`slice_map` 是 search 的符号）会被抓住。
    返回 [(path, literal_text)]。
    """
    bad = []
    for lit, _s, _e in src.literals():
        if any(a.search(lit) for a in allows):
            continue
        for pkg, names in mapping.items():
            if any(re.search(r'\b' + pkg + r'\.' + re.escape(n) + r'\b', lit)
                   for n in names):
                bad.append((src.path, lit))
                break
    return bad


def cmd_check_literals(args):
    mapping = build_mapping(args.root, args.pkgmap, args.main)
    allows = _load_allowlist(args.allowlist)
    bad = []
    for path, _own in iter_sources(args.root, args.pkgmap, args.main):
        with open(path, 'r', encoding='utf-8') as f:
            bad.extend(find_literal_pollution(Source(f.read(), path), mapping, allows))
    if bad:
        for path, lit in bad:
            sys.stderr.write('字面量被加了包名前缀（不是符号引用）：%s\n    %s\n'
                             % (path, lit))
        sys.stderr.write('\n共 %d 处。这通常是"批量加前缀"误伤了字符串，'
                         '请确认是否真的想改输出文本。\n' % len(bad))
        return 1
    print('字面量检查通过：没有 `<包>.<已知符号>` 出现在字符串里。')
    return 0


def _load_allowlist(path):
    if not path or not os.path.isfile(path):
        return []
    pats = []
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                pats.append(re.compile(line))
    return pats


# ---------------------------------------------------------------------------
# 内置回归用例（selftest）
# ---------------------------------------------------------------------------

FIX_COMMON = '''package lib

// 顶层常量用 ::，全局变量用 : —— 坑 2 就是漏了后者。
Table_Limit :: 8
lower_table: [256]u8

s2b :: proc(s: string) -> []u8 {
    return transmute([]u8)s
}
'''

# 故意混入：含符号名的字符串、raw string、注释、与外部符号同名的结构体字段、
# 以及"切片语法里的同名符号"（复现测试抓到的那个 bug 的形态）。
FIX_SEARCH = '''package search

import "core:fmt"
import "xrep:lib"

// 这里提到 lib 的 s2b，但注释不是代码，不能改。
run :: proc() -> int {
    fmt.println("OK slice_map")           // 字符串里的名字不是符号引用
    fmt.println(`raw lower_table too`)    // raw string 同样要屏蔽
    fmt.println("xrep GET app.log")       // 去掉前缀时最容易被削成 "GET log"
    buf := s2b("ab")                      // 这一处**应该**被限定成 lib.s2b
    tail := data_b[len(buf) + Table_Limit:]   // 切片：冒号不是字段分隔符
    fmt.aprintf("%d", Table_Limit)        // 同一符号的正常用法，必须被限定
    opts := Opts{Table_Limit = 3}         // 字面量字段与外部符号同名，不能动
    with_param(s2b)                       // proc 参数名与外部符号同名，不能动
    return len(buf) + len(tail) + opts.Table_Limit    // 成员访问之后不能动
}

with_param :: proc(s2b: int) -> int { return s2b }

Opts :: struct {
    Table_Limit: int,
}

// 本包自己的符号：真实事故里 "OK slice_map" 被加成了 "OK search.slice_map"，
// 所以夹具里必须真的有这个声明，否则用例没有区分度。
slice_map :: proc(x: []int) -> int {
    return len(x)
}
'''


def _legacy_declarations(text):
    """复刻坑 2 的错误做法：只抓 `::`。"""
    return set(re.findall(r'(?m)^([A-Za-z_]\w*)\s*::', text))


def _legacy_qualify(text, mapping):
    """复刻坑 1 的错误做法：无脑正则、不看词法，且连本包符号一起加前缀
    （当年正是先给本包符号加了前缀，之后才需要反向删除）。"""
    for pkg, names in mapping.items():
        for n in names:
            text = re.sub(r'(?<![\w.])' + re.escape(n) + r'\b', pkg + '.' + n, text)
    return text


def cmd_selftest(args):
    failures = []

    def check(name, cond, detail=''):
        print('  %s %s%s' % ('OK  ' if cond else 'FAIL', name,
                             '' if cond else '  <- ' + detail))
        if not cond:
            failures.append(name)

    print('== 坑 2：声明提取必须同时认 :: := : ==')
    common = Source(FIX_COMMON)
    got = declarations(common)
    check('提取到 Table_Limit（::）', 'Table_Limit' in got)
    check('提取到 lower_table（:）', 'lower_table' in got, sorted(got).__str__())
    check('提取到 s2b（:: proc）', 's2b' in got)
    legacy = _legacy_declarations(FIX_COMMON)
    check('旧做法漏掉 lower_table（证明用例有区分度）',
          'lower_table' not in legacy, sorted(legacy).__str__())

    print('== 坑 1：字符串/注释/字段不得被加前缀 ==')
    mapping = {'lib': got, 'search': declarations(Source(FIX_SEARCH))}
    search = Source(FIX_SEARCH)
    new = qualify(search, mapping, 'search')
    check('代码里的 s2b 被限定', 'lib.s2b("ab")' in new)
    check('字符串 "OK slice_map" 未被污染', '"OK slice_map"' in new)
    check('raw string 未被污染', '`raw lower_table too`' in new)
    check('注释未被污染', '// 这里提到 lib 的 s2b' in new)
    check('结构体字段未被污染', 'Table_Limit: int,' in new)
    check('字面量字段未被污染', 'Opts{Table_Limit = 3}' in new)
    check('proc 参数名未被污染', 'with_param :: proc(s2b: int)' in new)
    check('成员访问未被污染', 'opts.Table_Limit' in new)
    legacy_new = _legacy_qualify(FIX_SEARCH, mapping)
    check('旧做法确实会污染字符串（证明用例有区分度）',
          '"OK search.slice_map"' in legacy_new, legacy_new)

    print('== 复现测试抓到的 bug：切片里的同名符号不得连累别的用法 ==')
    check('切片表达式未被误保护', 'data_b[len(buf) + lib.Table_Limit:]' in new, new)
    check('同文件其它用法被限定', 'fmt.aprintf("%d", lib.Table_Limit)' in new, new)

    print('== 复现测试抓到的 bug：局部变量不得被误加成前缀 ==')
    # main.odin 里有 `scan_opts := ...`（局部）撞上 app 包的全局 scan_opts。
    fix_main = ('package main\n\n'
                'import "core:fmt"\n'
                'import "xrep:app"\n\n'
                'main :: proc() {\n'
                '    scan_opts := 3          // 局部变量，与 app 包的全局同名\n'
                '    fmt.println(scan_opts)  // 不能变成 app.scan_opts\n'
                '    hits := app_scan()      // app 的 proc，必须限定\n'
                '}\n')
    m2 = {'lib': got, 'app': {'scan_opts', 'app_scan'}}
    r = qualify(Source(fix_main), m2, None)
    check('局部变量 scan_opts 未被限定', 'fmt.println(scan_opts)' in r, r)
    check('跨包 proc 仍被限定', 'hits := app.app_scan()' in r, r)
    check('顶层声明不会被当成局部变量',
          'Table_Limit' not in local_names(Source(FIX_COMMON)))

    print('== 坑 1 反向：strip-self 不得削掉字符串内容 ==')
    # 真实事故形态：先给本包符号加了前缀，之后要删掉。
    damaged = FIX_SEARCH.replace('buf := s2b("ab")', 'buf := search.slice_map(s2b("ab"))')
    stripped = strip_self(Source(damaged), 'search', mapping['search'])
    check('search.slice_map 前缀被去掉', 'buf := slice_map(s2b("ab"))' in stripped, stripped)
    check('"xrep GET app.log" 未被削成 "GET log"',
          '"xrep GET app.log"' in stripped, stripped)

    print('== 护栏：check-literals 能抓住被污染的产物 ==')
    polluted = new.replace('"OK slice_map"', '"OK search.slice_map"')
    check('污染可被 find_literal_pollution 命中',
          len(find_literal_pollution(Source(polluted), mapping)) > 0)
    check('合法文件名 app.log 不误报',
          len(find_literal_pollution(Source(new), mapping)) == 0)

    print('== import 同步：加了前缀就得补 import，删掉不用的 ==')
    ALL = ('lib', 'search', 'engine', 'app')
    bare = 'package search\n\nrun :: proc() -> int {\n    return s2b("ab")\n}\n'
    synced = sync_imports(qualify(Source(bare), mapping, 'search'), 'search', ALL)
    check('补上 import "xrep:lib"', 'import "xrep:lib"' in synced, synced)
    check('插在 package 行之后',
          synced.index('package search') < synced.index('import "xrep:lib"'))
    check('再次同步是幂等的', sync_imports(synced, 'search', ALL) == synced)
    unused = ('package search\n\nimport "xrep:lib"\nimport "xrep:engine"\n\n'
              'run :: proc() -> int { return 1 }\n')
    check('删掉未使用的 xrp import', 'xrep:lib' not in sync_imports(unused, 'search', ALL))
    # 字符串里伪装成 import 行 —— 既不能当 import 用，也不能被改
    tricky = ('package search\n\n'
              'fmt.println("import \\"xrep:lib\\"")\n\n'
              'run :: proc() -> int { return s2b("ab") }\n')
    tricky_got = sync_imports(qualify(Source(tricky), mapping, 'search'), 'search', ALL)
    check('字符串里的伪 import 不被当成 import',
          tricky_got.count('import "xrep:lib"') == 1, tricky_got)
    check('字符串里的伪 import 内容不变',
          '"import \\"xrep:lib\\""' in tricky_got, tricky_got)

    print()
    if failures:
        print('selftest FAILED：%d 项' % len(failures))
        for f in failures:
            print('  - ' + f)
        return 1
    print('selftest 全部通过')
    return 0


# ---------------------------------------------------------------------------

def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    root_default = os.path.dirname(here)

    # 子命令在前、公共选项用 parents= 共享。不能把 --packages 挂在顶层解析器上：
    # 它是 nargs='+'，会把后面的子命令名一起吞掉（实测踩到）。
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--root', default=root_default, help='仓库根目录（默认：工具上级目录）')
    common.add_argument('--packages', nargs='+', default=list(DEFAULT_PACKAGES),
                        metavar='PKG',
                        help='包名（目录模式）或 包名=文件.odin,文件.odin（flat 模式）')
    common.add_argument('--main', default=DEFAULT_MAIN, help='main 包文件名')

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd')

    sub.add_parser('symbols', parents=[common], help='打印各包顶层声明')

    for name in ('qualify', 'strip-self'):
        sp = sub.add_parser(name, parents=[common], help='%s（默认 dry-run）' % name)
        sp.add_argument('--write', action='store_true', help='真正写盘（否则只打 diff）')
        if name == 'qualify':
            sp.add_argument('--no-sync-imports', action='store_true',
                            help='不要按用到的前缀重写 import "xrep:..."（默认会同步）')

    sp = sub.add_parser('check-literals', parents=[common], help='字面量护栏')
    sp.add_argument('--allowlist', default=os.path.join(here, 'literal_allowlist.txt'),
                    help='白名单文件，每行一个正则')

    sub.add_parser('selftest', parents=[common], help='内置回归用例')

    args = p.parse_args(argv)
    args.pkgmap = parse_packages(args.packages)
    table = {
        'symbols': cmd_symbols,
        'qualify': cmd_qualify,
        'strip-self': cmd_strip_self,
        'check-literals': cmd_check_literals,
        'selftest': cmd_selftest,
    }
    if args.cmd not in table:
        p.print_help()
        return 2
    return table[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
