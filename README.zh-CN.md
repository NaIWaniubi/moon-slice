# moon-slice

面向 MoonBit 的程序切片与依赖图工作台。

选中一行，它能回答三个日常问题：

- **这个值从哪来？** 向后切片，列出所有可能影响它的赋值、分支和调用。
- **改这一行会影响谁？** 向前切片，列出所有受影响的语句。
- **这次改动影响了什么？** `review` 读取 git diff，对每个改动行做向前切片。

![报告截图](docs/report.png)

- 在线试用（无需安装）：https://cs6210501-lab.github.io/moon-slice/
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

## 快速开始

需要 MoonBit 工具链。所有命令都走仓库自带的包装脚本：

```bash
git clone https://github.com/cs6210501-lab/moon-slice
cd moon-slice

./dev.sh check                 # 类型检查
./dev.sh test                  # 248 个测试

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

Windows 的 cmd/PowerShell 用 `dev.cmd` 代替 `./dev.sh`。

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
| moon-slice 自身 | 50 | 9,712 | 0 | 7（全部人工确认） |

第一轮扫描报了 176 行，逐类核对后发现全是工具自身的误报。修掉 6 类缺陷后降到 0，
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

- 248 个测试；库代码行覆盖率约 89%
- GitHub Actions：`check` / `test` / 语料 / CLI smoke / JS 构建与 smoke
- 性能：32,000 行单文件，`slice` 1.55 s、`dead` 0.80 s、`graph` 0.74 s
  （native release，`bench/bench.mjs` 可复现）
- 许可证：Apache-2.0
