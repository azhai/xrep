# findings.md — Odin 包机制实测结论

## 目录 = package

Odin 中一个目录是一个 package。子目录是**独立包**，彼此不能隐式共享符号。
同一个目录内的所有 `.odin` 文件必须声明同一个 `package X`。

## import 路径解析规则（关键）

`import` 的路径是**相对于源文件所在目录**解析的，不是相对于工程根：

```
/pkg3/main.odin        import "common"   → /pkg3/common     ✅
/pkg3/algo/matcher.odin import "common"   → /pkg3/algo/common ❌ Path does not exist
```

所以兄弟包之间只有两条路：

| 方式 | 写法 | 代价 |
| --- | --- | --- |
| 相对路径 | `import "../common"` | 构建命令不变；深层嵌套时 `../../x` 很难看 |
| collection | `-collection:xrep=.` + `import "xrep:common"` | import 干净；build/test 命令要加一个 flag |

选 **collection**（`-collection:xrep=.` 的相对路径形式实测有效）。

## odin test 只吃一个路径

```
odin test .              # 只跑当前包（根目录），子包的 *_test.odin 不执行 → "No tests to run."
odin test ./common       # ✅ 跑子包
odin test . common algo  # ❌ Invalid flag: common
```

→ 拆分后 test.sh 必须逐包跑，并把各包用例数相加核对总数。

## 子包 `*_test.odin` 不进产品构建 ⭐

在 `algo/matcher_test.odin` 末尾注入 `BOGUS_UNDEFINED_SYMBOL_XYZ :: 1` 后，
`odin build .` **仍然成功**。对比根目录（当前包）的 `*_test.odin` 会被编入。

含义：拆分后 `core:testing` 不再链进产品的 `xrep`。
顺带可能让 wasm 目标可用（此前失败正是因为 `core:testing` 在 wasm 下编译不过）。

## 别名语法（备选方案，未采用）

```
import l "lib"
Thing  :: l.Thing    // 类型别名，可用
double :: l.double   // proc 别名，可用
```
已实测通过。用户选了正统限定符方案，故不采用，但留档。

## 循环依赖风险

`common.odin` 的 `Match_Fn` 签名引用 `Progress`（定义在 progress.odin）。
若 `Progress` 留在 engine 包，则 common → engine 反向依赖，与
「common 是底层」冲突。处置：`Progress` 类型上移到 common。
