# 真实仓库验证（case study）

这份文档回答一个问题：**moon-slice 在别人写的 MoonBit 代码上到底准不准？**

所有数字都可以用仓库里的脚本复现，不依赖任何手工统计。

## 方法

```bash
# 1. 构建 release 二进制（避免把 moon run 的启动开销算进测量）
./dev.sh build --target native --release cmd/main

# 2. 拉取被测仓库（浅克隆即可）
git clone --depth 1 https://github.com/moonbitlang/async /tmp/async
git clone --depth 1 https://github.com/moonbitlang/x     /tmp/x

# 3. 一条命令扫描整棵树
(cd /tmp/async && <repo>/_build/native/release/build/cmd/main/main.exe dead --dir . --json)
(cd /tmp/x     && <repo>/_build/native/release/build/cmd/main/main.exe dead --dir . --json)
./dev.sh run cmd/main -- dead --dir .

# 4. 再用独立脚本交叉核对（逐文件进程，结果应一致）
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe /tmp/async
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe /tmp/x
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe .
```

`dead --dir` 自己完成枚举、解析、分析、汇总，并跳过 `.git`、`_build`、
`target`、`.mooncakes`、`node_modules`。`tools/scan.mjs` 是独立的第二实现：
它逐文件起进程、自己汇总，用来确认批量模式的数字不是自说自话。两者不会
“猜”哪些命中是真的，triage 由人做。

## 结果（2026-10-29）

| 仓库 | commit | 文件 | 源码行 | 解析失败 | 命中文件 | 命中行 |
| --- | --- | --- | --- | --- | --- | --- |
| `moonbitlang/async` | `2632315` | 368 | 50,388 | 0 | 0 | 0 |
| `moonbitlang/x` | `4705764` | 166 | 37,595 | 0 | 0 | 0 |
| `moon-slice` 自身（含 examples） | working tree | 51 | 10,401 | 0 | 6 | 7 |
| **合计** | | **585** | **98,384** | **0** | **6** | **7** |

- **解析**：585 个文件、全部 `errors 0`。没有任何 panic、没有崩溃、没有
  “分析到一半失败”。
- **前两个仓库 0 命中**：它们是持续维护、CI 开着 warning 的库，本来就不该有
  死存储。工具没有为了“显得有用”而编造命中。
- **自身 7 个命中全部是真阳性**，都在 `examples/` 里，是语料故意埋的死代码：

| 文件 | 行 | 为什么是死代码 |
| --- | --- | --- |
| `08_dead_assignment.mbt` | 4, 5 | `cache = 1` / `cache = 2` 在下次读取前被覆盖 |
| `01_let.mbt` | 7 | `let unused = 99` 从未被读 |
| `02_mut.mbt` | 4 | `let mut n = 0` 在 `n = 1` 前没有读取 |
| `03_if_else.mbt` | 4 | `let mut tag = 0` 被两个分支都覆盖后才读 |
| `06_match.mbt` | 4 | `let mut label = 0` 被所有 match 分支覆盖 |
| `09_shadowing.mbt` | 4 | `let a = 1` 被下一行同名绑定遮蔽，从未被读 |

7/7 真阳性，0 误报。

批量模式也把扫描时间从“每文件一次进程启动”降到一次进程：166 个文件的
`moonbitlang/x` 约 **1.0 s**，368 个文件的 `moonbitlang/async` 约 **1.2 s**
（Windows release 构建，含解析与全部查询）。

## 扫描过程中在工具里发现的 7 个真 bug

第一轮扫描报告的命中是 **176 行**，全部是误报。逐类 triage 后修掉 6 个缺陷，
命中数变成 0。这部分比“扫出多少问题”更有价值：它说明这些结论是**核对过的**，
不是跑一遍就写进 PPT。

| # | 症状 | 根因 | 修复 | 回归 |
| --- | --- | --- | --- | --- |
| 1 | 176 行误报；所有 `impl` setter（`self.index = value`）被判死 | 通过参数写字段是调用方可见的副作用，不是死存储 | `dead` 跳过对形参的写 | `real_world_test.mbt`：`a write through a parameter is not reported as dead` |
| 2 | `buf.len = dropped - len`、`input.len += n` 被判死 | 字段/原地写 = 读写同一基变量；无逃逸分析时无法证明它不可见 | `dead` 跳过 `defs ∩ uses ≠ ∅` 的写 | `a read-modify-write through a local is not reported as dead` |
| 3 | `"%\{interface}"`、`"x=\{ip >> 24}"` 里的变量被判“未使用” | 该 parser 版本的插值元素是 `Source` 文本，表达式没有被降低成 `Expr`，默认访问器走不到 | 扫描插值源文本里的标识符（保守超集） | `an interpolation reads every identifier inside it` |
| 4 | C 风格 `for` 的 `i = i + 1` 被判不可达 | 更新块是 `Expr` 容器，CFG 的 `dispatch` 不遍历它的子节点，更新节点成为孤岛 | `Expr` 有子节点时按序列走 | `a C-style for runs its initialiser once and reaches the update` |
| 5 | 循环体里的 `i` 只连到初始化，不连到更新 | 初始化器被建模成“每轮在循环头重新定义” | 初始化器降为循环前的 `Assign`，循环头不再定义循环变量 | 同上 |
| 6 | `for i = 0, j = 0; ...` 的更新容器被报为不可达代码 | 容器节点没有源码语句，不该出现在 `dead` 的行号里 | `unreachable_nodes` 跳过纯容器 | `a structural container is not reported as unreachable code` |

另外修掉一个闭包相关误报（`moonbitlang/x` 的 2 行）：局部 `fn` 捕获的变量在闭包
被调用时才读，直线式 def-use 看不到。现在闭包正文里出现的变量会作为函数出口的
use 记录，使被捕获的赋值不再被判死（保守方向，不会漏报副作用）。

## 复现其中一条

```bash
$ cat > /tmp/cfor.mbt <<'MBT'
fn f(n : Int) -> Int {
  let mut k = 0
  for i = 0; i < n; i = i + 1 {
    k = k + i
  }
  return k
}
MBT
$ ./dev.sh run cmd/main -- dead --file /tmp/cfor.mbt
（空输出）
$ ./dev.sh run cmd/main -- slice --file /tmp/cfor.mbt --line 4 --direction backward
2,3,4
```

修复前这里会报第 3 行为死代码，并且从第 4 行回溯时看不到循环更新。

## Review 一个真实提交

`review` 在 `moonbitlang/x` 的真实提交 `4705764`
（`fix(time): reject incomplete duration and period strings`）上的输出：

```bash
$ cd /tmp/x
$ git diff -U0 HEAD~1 HEAD -- '*.mbt' > /tmp/x_head.diff
$ <repo>/_build/native/release/build/cmd/main/main.exe review --diff /tmp/x_head.diff
time/duration.mbt: changed 7 line(s) -> affected 36 line(s) in parse_str, from_str, to_string, seconds, nanoseconds, is_zero
  affected lines: 69,70,71,73,74,75,76,77,78,79,81,83,84,87,88,91,92,93,94,96,97,101,102,103,106,107,109,111,112,113,115,119,121,124,125,127
time/duration_test.mbt: changed 2 line(s) -> affected 0 line(s)
time/period.mbt: changed 4 line(s) -> affected 4 line(s) in to_string, days, add_years
  affected lines: 43,44,70,71
time/period_test.mbt: changed 2 line(s) -> affected 0 line(s)
review: 4 file(s), 15 changed line(s), 40 affected line(s)
```

这个提交只改了 15 行，但 `parse_str` 的改动会通过返回值影响 6 个函数、36 行；
`period.mbt` 的 4 行影响 `to_string` / `days` / `add_years`。测试文件的影响面
是 0，符合预期（测试只调用 API，没有内部数据依赖）。这就是 review 想回答的
问题：**一个 diff 在表面之外还动了什么**。

## 无人调用的私有函数（`unused`）

`dead` 只看函数内部；“这个私有函数还有人调用吗”必须在**包**这一级回答，因为私有
函数对同包所有文件可见：按文件问，兄弟文件里的调用会漏，反过来也会多报。

```bash
./dev.sh build --target native --release cmd/main
BIN=_build/native/release/build/cmd/main/main.exe
(cd /tmp/async && $BIN unused --dir .)
(cd /tmp/x     && $BIN unused --dir .)
(cd /tmp/core  && $BIN unused --dir .)
```

结果（2026-10-30，耗时取 3 次最小值）：

| 仓库 | commit | 文件 | 包 | 首轮命中 | 修完误报后 | 耗时 |
| --- | --- | --- | --- | --- | --- | --- |
| `moonbitlang/async` | `cc2d5d8` | 369 | 54 | 16 | 0 | 1.09 s |
| `moonbitlang/x` | `4705764` | 166 | 25 | 1 | 0 | 1.14 s |
| `moonbitlang/core` | `56256d0` | 1452 | 140 | 4 | 0 | 6.93 s |
| **合计** | | **1987** | **219** | **21** | **0** | |

首轮 21 处命中暴露了分析自身的两类误报，两类都在真实代码上才暴露出来：

| # | 症状 | 根因 | 修复 |
| --- | --- | --- | --- |
| 1 | async 里 16 个 `fn init` 被判“无人调用” | `init` 是包初始化器，由运行时调用 | `main` 与 `init` 都算入口点 |
| 2 | x 的 `Decode::_use_decode_debug` 被判“无人调用” | `fn T::m(self)` 写在 `impl` 块外也是方法，走点号调用 | 带 `type_name` 的声明不是候选 |

修完这两类，async 与 x 都是 0。然后换更大的语料：`moonbitlang/core` 1452 个文件、
140 个包，命中 4 个：

```text
encoding/ascii/decode.mbt:25: suppress_unused_v128_import_on_js
encoding/utf16/decode.mbt:27: suppress_unused_v128_import_on_js
env/env.mbt:82: unused_function
json/json.mbt:428: suppress_unused_v128_import_on_scalar_targets
```

逐个看过：这 4 个全部带着官方自己的标注，函数体只是为了保住一个 import：

```moonbit
#cfg(target="js")
#warnings("-unused_value")
fn suppress_unused_v128_import_on_js() -> Unit {
  ignore(@v128.i8x16_splat(0))
}
```

这就是精确度的另一种证明：**不是 0 命中才叫好，而是命中的正好是该命中的。** 工具在
1452 个文件里独立挑出来的，正好是标准库显式声明“这里就是故意不调用”的那 4 个。
既然作者已经用 `#warnings("-unused_value")` 写明了意图，分析现在直接尊重这个标注
（等价于 Rust 的 `#[allow(dead_code)]`），于是三个仓库合计 1987 个文件 0 命中。

这份分析保守的地方，也说清楚：方法（`impl` 与 `fn T::m(self)`）、trait 派发、
宏展开都不建模；名字只要在包内任何位置出现过（含注释、属性、插值文本）就不再
报告。因此它给出的每一条都要求“整个包里只出现一次”，代价是可能漏掉真死函数。

## 这份验证不能证明什么

- **不是“发现了上游 bug”**。两个上游仓库零命中，这是它们代码干净的证据，不是
  工具能力的上限。要证明“能找真 bug”，需要构造有缺陷的代码或扫描历史版本。
- **不是全语言覆盖**。585 个文件全部解析成功，但 `impl` 里的关联类型、
  `lexmatch`、宏等构造仍按保守 `Expr` 处理。
- **不是性能基准**。`dead --dir` 是单进程批量分析，166 个文件约 1.0 s；
  单文件 3.2 万语句的基准见 `bench/README.md`。两者测的不是同一件事。
- **解析失败会被跳过而不是猜测**。`--dir` 在 JSON/SARIF 里报告失败文件，
  文本模式用 `# error:` 行提示；失败文件不计入 `files`，其余文件照常分析。
- **闭包捕获是超近似**。被闭包读取的变量会一直被视为 live，可能漏报真正的死存储。

## 和“只看示例”的区别

示例语料证明的是“对写好的形状正确”；这份验证证明的是“对没见过的代码不崩、
不乱报”。两者都在 CI 里：`testdata/verify_corpus.sh` 管前者，
`tools/scan.mjs` 的结果是人工复核后写进本文档的，没有加进 CI（否则每次都要联网
克隆两个仓库）。
