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

# 3. 逐文件跑 dead，汇总
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe /tmp/async
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe /tmp/x
node tools/scan.mjs _build/native/release/build/cmd/main/main.exe .
```

`tools/scan.mjs` 只做三件事：枚举 `.mbt`、对每个文件执行 `dead --json`、把
解析失败数与命中行数汇总成 JSON。它不会“猜”哪些命中是真的，triage 由人做。

## 结果（2026-10-29）

| 仓库 | commit | 文件 | 源码行 | 解析失败 | 命中文件 | 命中行 |
| --- | --- | --- | --- | --- | --- | --- |
| `moonbitlang/async` | `2632315` | 368 | 50,388 | 0 | 0 | 0 |
| `moonbitlang/x` | `4705764` | 166 | 37,595 | 0 | 0 | 0 |
| `moon-slice` 自身（含 examples） | working tree | 50 | 9,712 | 0 | 6 | 7 |
| **合计** | | **584** | **97,695** | **0** | **6** | **7** |

- **解析**：584 个文件、全部 `errors 0`。没有任何 panic、没有崩溃、没有
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

## 扫描过程中在工具里发现的 6 个真 bug

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

## 这份验证不能证明什么

- **不是“发现了上游 bug”**。两个上游仓库零命中，这是它们代码干净的证据，不是
  工具能力的上限。要证明“能找真 bug”，需要构造有缺陷的代码或扫描历史版本。
- **不是全语言覆盖**。584 个文件全部解析成功，但 `impl` 里的关联类型、
  `lexmatch`、宏等构造仍按保守 `Expr` 处理。
- **不是性能基准**。上面的耗时包含每个文件一次进程启动（Windows 上约 110 ms），
  所以 166 个文件要 99 秒。分析本身在 3.2 万行单文件上约 1.5 秒，见
  `bench/README.md`。批量模式（一次进程扫多文件）还没做。
- **闭包捕获是超近似**。被闭包读取的变量会一直被视为 live，可能漏报真正的死存储。

## 和“只看示例”的区别

示例语料证明的是“对写好的形状正确”；这份验证证明的是“对没见过的代码不崩、
不乱报”。两者都在 CI 里：`testdata/verify_corpus.sh` 管前者，
`tools/scan.mjs` 的结果是人工复核后写进本文档的，没有加进 CI（否则每次都要联网
克隆两个仓库）。
