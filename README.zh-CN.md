# moon-slice

面向 MoonBit 的程序切片与依赖图工作台。

[验收对照表](ACCEPTANCE.md) · [真实仓库验证](docs/CASE_STUDY.md) · [贡献指南](CONTRIBUTING.md) · [路线图](ROADMAP.md)

选中一行，它能回答三个日常问题：

- **这个值从哪来？** 向后切片，列出所有可能影响它的赋值、分支和调用。
- **改这一行会影响谁？** 向前切片，列出所有受影响的语句。
- **这次改动影响了什么？** `review` 读取 git diff，对每个改动行做向前切片。

![报告截图](docs/report.png)

- 在线试用（无需安装）：https://NaIWaniubi.github.io/moon-slice/
- 英文文档：[README.md](README.md)
- 真实仓库验证：[docs/CASE_STUDY.md](docs/CASE_STUDY.md)

## 为什么不是又一个 grep

切片基于 MoonBit 官方 parser 构建的真实依赖图，不是文本匹配：

```text
.mbt 源码
   │  moonbitlang/parser
   ▼
语句级 IR（SNode / VarId / Loc）
   │
   ├─ CFG        顺序、分支、循环、break/continue/return
   ├─ def-use    到达定义（reaching definitions），区分同名遮蔽
   ├─ CDG        控制依赖（结构化 / 后支配两种算法）
   ▼
PDG ──▶ 向后/向前切片、死代码、数据流路径、调用图、HTML 报告
```

因此它能区分「同名但不同作用域的变量」、能沿着 `return` 找到被跳过的代码、
能在报告里画出数据边（实线）和控制边（虚线）。

## 安装与快速开始

需要 `moonc` **0.10.16 或更新**（实测 `v0.10.17`）。分析包是纯 MoonBit；Node
只用于可选的网页工具与冒烟脚本。

```bash
git clone https://github.com/NaIWaniubi/moon-slice
cd moon-slice

./dev.sh check                 # 类型检查
./dev.sh test                  # 315 个测试

# 向后切片：examples/04_while.mbt 第 7 行依赖什么
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward
# 4,5,6,7,8

# 向前切片：改这一行会影响什么
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward
# 7,10

# 死代码 / 不可达代码
./dev.sh run cmd/main -- dead --file examples/08_dead_assignment.mbt
# 4,5

# 数据流路径（taint-lite）：从 i 的定义到 total 的使用
./dev.sh run cmd/main -- path --file examples/04_while.mbt --from i --to total
# n1 L4 -> n5 L7

# 生成自包含 HTML 报告（内联 SVG + 源码高亮 + 节点表）
./dev.sh run cmd/main -- html --file examples/04_while.mbt --line 7 --out report.html
```

Windows 的 cmd/PowerShell 用 `dev.cmd` 代替 `./dev.sh`。库已发布到 mooncakes.io：

```bash
moon add NaIWaniubi/moon-slice@0.7.2
```

<https://mooncakes.io/docs/NaIWaniubi/moon-slice> · 发布细节见 `PUBLISHING.md`。

## 改动影响分析（review）

```bash
bash tools/review.sh            # 相对 HEAD~1 的改动
bash tools/review.sh origin/main
bash tools/review.sh HEAD~3 --json
```

输出示例：

```text
src/query/query.mbt: changed 55 line(s) -> affected 18 line(s) in visible_lines, unreachable_nodes, path_between
  affected lines: 187,188,189,...
review: 5 file(s), 163 changed line(s), 212 affected line(s)
```

`tools/review.sh` 用 `git diff -U0` 取改动行，CLI 的 `review --diff` 对每个改动行
做向前切片并汇总到函数名。可以直接在评委/同事的仓库上跑。

## 接入 CI（SARIF / 基线 / GitHub Action）

`dead --dir D` 一条命令扫描整棵树（跳过 `.git`、`_build`、`target`、
`.mooncakes`、`node_modules`），输出顺序稳定。三个开关让它变成 CI 门禁：

```bash
# 1. 生成 GitHub code scanning 认识的 SARIF 2.1.0
./dev.sh run cmd/main -- dead --dir . --format sarif --out moon-slice.sarif

# 2. 记录当前存量问题
./dev.sh run cmd/main -- dead --dir . --write-baseline .moon-slice-baseline

# 3. 只对新增问题失败（退出码 1），存量不阻塞
./dev.sh run cmd/main -- dead --dir . --baseline .moon-slice-baseline --fail-on-findings
```

基线是纯文本的 `path:line` 列表；解析失败的文件会写进 JSON/SARIF 的
`errors` / `parseFailures`，不会掩盖其他文件的结果。

仓库根目录的 `action.yml` 把“装工具链、构建、执行”封装成 composite action，
`templates/review-workflow.yml` 可直接复制到业务仓库：

```yaml
- uses: NaIWaniubi/moon-slice@v0.6.0
  with:
    command: review
    since: ${{ github.event.pull_request.base.sha }}

- uses: NaIWaniubi/moon-slice@v0.6.0
  with:
    command: dead
    args: --dir . --baseline .moon-slice-baseline --format sarif --out moon-slice.sarif --fail-on-findings
```

action 会从 pin 住的 tag 现场构建二进制，workflow 里写的版本就是实际运行的版本。

## 死代码与无人调用的函数

两个问题、两个命令。`dead` 看函数内部：

```bash
./dev.sh run cmd/main -- dead --file examples/08_dead_assignment.mbt   # 4,5
./dev.sh run cmd/main -- dead --dir examples
```

`unused` 看整个包：私有函数对同包所有文件可见，所以“还有没有人调用它”只能在
包（目录）这一级回答，按文件问必然是错的。

```bash
./dev.sh run cmd/main -- unused --dir src      # 空
./dev.sh run cmd/main -- unused --dir examples # 10 处：示例本身就是独立片段
```

它刻意保守，每条规则都来自真实代码打脸：

- **入口点不报**：`main` 和 `init` 由运行时调用；
- **`pub` 是 API**，永不报告；
- **方法不在范围内**：`impl T with fn m` 与 `fn T::m(self)` 走点号或 trait 派发，
  本 pass 不建模；
- **名字只要在包内出现过就不再报告**（包括注释、属性、插值文本），因此留下的
  只有“整个包里只出现一次”的名字——也就是它的定义本身。

在 `moonbitlang/async`（368 文件）与 `moonbitlang/x`（166 文件）上零命中；
在 `moonbitlang/core`（1452 文件）上命中 4 个，全部是官方自己命名为
`unused_function` / `suppress_unused_v128_import_on_*` 的函数。细节与由此在
moon-slice 自身发现的两类误报见 `docs/CASE_STUDY.md`。

### 就地抑制

已经判定过的告警可以在原地关掉；相比基线文件，它跟着代码走，行号变了也不会失效。

```moonbit
let unused = compute() // moon-slice: ignore dead-store

// moon-slice: ignore[unused-function]
fn helper() -> Unit { ... }
```

- 写在有代码的行上，就作用于该行；单独占一行时，作用于下一行代码（中间的空行和
  注释会跳过）。
- 只写 `ignore` 覆盖全部规则；写规则名则只关掉那几条：`dead-store`、
  `unreachable-code`、`unused-function`。任何其他写法（包括拼错）都让这条指令
  失效——写错名字不该整行静音。
- 指令必须是行尾最后的内容，所以字符串字面量里的 `"// moon-slice: ignore"`
  不算指令。
- 被抑制的告警仍然计入 `suppressed`（与基线隐藏的合并计数），也仍然会被
  `--write-baseline` 记录，基线因此保持完整。

## 跨文件切片与 callers

`slice --file F` 只看一个文件。加 `--dir D` 后，包成为分析单位：调用会被追到 `D`
下定义该被调函数的那个文件。

```bash
./dev.sh run cmd/main -- slice --dir pkg --file pkg/a.mbt --line 2
# pkg/a.mbt: 2
./dev.sh run cmd/main -- slice --dir pkg --file pkg/a.mbt --line 2 --interprocedural
# pkg/a.mbt: 2
# pkg/b.mbt: 2,6,7,8
```

结果按文件分组，因为节点编号只在它所属的程序里有意义。语义与单文件一致：裸调用
贡献被调函数整个函数体，有返回值的调用只贡献返回值 cone（被调函数里的死存储不会
被带进来），且可传递。同文件内定义优先于其他文件的同名函数。

反向问题是一个独立命令：

```bash
./dev.sh run cmd/main -- callers --dir . --name baseline_key
# cmd/main/main.mbt:352: filter_baseline
# cmd/main/main.mbt:374: write_baseline_file
# cmd/main/main.mbt:449: write_scan_baseline
# cmd/main/main.mbt:573: run_dead_dir
# cmd/main/main.mbt:613: write_unused_baseline
# cmd/main/main.mbt:765: run_unused_dir
```

两者都能识别限定调用 `T::f(x)`——真实 MoonBit 代码就是这么调自己的函数的。接收者
调用 `x.f()` 刻意不跟进：接收者类型未知，硬算成名为 `f` 的函数等于凭空造一次调用；
这一条也有回归测试守着。

## 浏览器 playground（点行即切片）

`web/index.html` 现在是一个小工具而不是文本框：**行号槽可点击**，点哪行就切哪行；
行号槽用绿色标出切片、琥珀色标出目标行（数据来自报告内嵌的 JSON，报告本身仍可
单独打开）；内置 5 个示例（while、match、死存储、过程间、遮蔽）各自带目标行与
方向；编辑后自动重跑，`Ctrl`+`Enter` 立即执行；**Copy link** 把源码、行号、方向
写进 URL。`web/presets.mjs` 会逐个示例、逐个方向用 JS 引擎核对，数字与 CLI 一致。

截图见 `docs/playground.png`。

## 两种控制依赖，一屏看清差别

结构化 CDG 便宜但会过度近似；`--precise` 用后支配计算精确控制依赖。`compare`
把两者的差异摊开：

```bash
./dev.sh run cmd/main -- compare --file bench/precise_cdg.mbt --line 7
# structural control edges: 18
# precise control edges:    7
# removed by precise:       12
# added by precise:         1
```

被移除的 12 条是结构性规则的伪边（分支 region“控制”兄弟 region、循环头被自己的
循环体“控制”）；新增的 1 条是语法树表达不了的循环携带依赖。

## 精度是怎么验证的

三层，互相独立：

1. **示例语料**：10 个例子带 `EXPECT-BACKWARD` / `EXPECT-FORWARD` 头，
   `moon test` 断言精确行集合。
2. **独立预言器**：`precision_oracle_test.mbt` 按「定义到使用存在一条不被重定义
   阻断的路径」重新推导，与工作列表算法逐对比对，覆盖 12 个程序 + 全部示例。
3. **属性测试**：种子化生成 40 个程序，检查结构不变量、预言器一致性、切片闭包、
   目标成员性、行投影、过程间超集性。

真实仓库验证（`docs/CASE_STUDY.md`）：

| 仓库 | 文件 | 源码行 | 解析失败 | 死代码命中 |
| --- | --- | --- | --- | --- |
| moonbitlang/async | 368 | 50,388 | 0 | 0 |
| moonbitlang/x | 166 | 37,595 | 0 | 0 |
| moon-slice 自身 | 51 | 10,401 | 0 | 7（全部人工确认） |

第一轮扫描报了 176 行，逐类核对后发现全是工具自身的误报。修掉 7 类缺陷后降到 0，
每一类都有回归测试。这条「先报错、再证明是误报、再修掉」的过程写在 case study 里。

## 支持范围

- 自由函数与 `impl T with fn ...` 方法 / `impl T with view ...` 视图
- `let` / `let mut` / 赋值、`if/else`、`guard/else`、`while`、`for` / `for-in`、
  `match`、`return` / `break` / `continue`
- 字段与数组读写（按基变量保守处理）、字符串插值里的变量读取
- 过程间：返回值 cone 展开（裸调用展开整个函数体），调用图
- 输出：终端行号、JSON、DOT、自包含 HTML、浏览器 playground

## 诚实的限制

- **过程间不做参数映射**。字面量实参、默认参数、标签实参都会让按位置过滤变得
  不健全，因此保留整个返回值 cone；切片可能偏大，不会偏小。
- **无逃逸分析 / 指向分析**。字段写按基变量抽象，切片偏大。闭包捕获的变量按
  “一直存活”处理。
- **CDG 是结构化的（默认）**。`--precise` 才用后支配；两者都不建模过程间控制
  依赖和异常边（`raise` / `try` 不是 CFG 边）。
- **`dead` 只报确定的情况**。局部未使用的定义、`return` 之后的不可达语句；
  通过参数或字段产生的副作用一律不报。
- **行粒度**。同一行多条语句在行号视图里合并；`--json` 的 `nodes` 保留区别，
  `--node ID` 可精确指定。

## 工程

- 315 个测试；库代码行覆盖率约 89%
- GitHub Actions：`check` / `test` / 语料 / CLI smoke / JS 构建与 smoke
- 性能：32,000 行单文件，`slice` 1.55 s、`dead` 0.80 s、`graph` 0.74 s
  （native release，`bench/bench.mjs` 可复现）
- 许可证：Apache-2.0
