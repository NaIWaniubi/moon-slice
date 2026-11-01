# 验收对照表

按「2026 MoonBit 国产基础软件开源大赛-10 月黑客松」验收指南逐条对照。所有
命令都在仓库根目录执行；当前版本 `v0.7.3`，`master` 已有 50+ 个提交。

| # | 验收要求 | 状态 | 证据 |
| --- | --- | --- | --- |
| 1 | MoonBit 为主要实现语言，moonc >= 0.10.16 | 通过 | `moonc -v` = `v0.10.17+d971670cd` |
| 2 | 仓库公开、提交记录清晰 | 通过 | https://github.com/NaIWaniubi/moon-slice，50+ commits，tag `v0.7.3` |
| 3 | 源代码结构清晰，核心功能可完成 | 通过 | 13 个库包（core / parser_adapter / cfg / defuse / cdg / pdg / slice / query / liveness / interproc / suppress / report / web）+ CLI；见下方命令 |
| 4 | README：目标、安装、使用、示例、可复现 | 通过 | `README.md` / `README.zh-CN.md`，quickstart 逐条可运行 |
| 5 | CI 覆盖检查、构建、测试 | 通过 | `.github/workflows/ci.yml` 的 `test` / `action` 两个 job |
| 6 | 至少一个可运行示例 | 通过 | `examples/` 10 个；在线 playground |
| 7 | 完整测试覆盖核心路径 | 通过 | 338 个测试 + corpus + CLI smoke + web smoke |
| 8 | 发布到 mooncakes.io | 通过 | `NaIWaniubi/moon-slice@0.7.3` 已上线（`Server status: 200 OK`），见第 8 节 |
| 9 | OSI 认可许可证，依赖合规 | 通过 | Apache-2.0；`LICENSE`、`THIRD_PARTY.md` |

## 1. MoonBit 为主要实现语言

```bash
moonc -v
# v0.10.17+d971670cd (2026-10-23)
```

分析管线（parser adapter、CFG、def-use、CDG、PDG、切片、查询、报告）全部是
MoonBit。仓库里的 JavaScript 只做两件事：把同一份 MoonBit 源码构建成浏览器
引擎（`web/build.sh`），以及开发期的冒烟/基准脚本，不参与程序分析。

## 2. 仓库与提交记录

```bash
git rev-list --count HEAD   # 50+
git tag --sort=-v:refname   # v0.7.0 v0.6.0 v0.5.0 ...
```

公开地址：https://github.com/NaIWaniubi/moon-slice

## 3. 源代码结构与核心功能

| 目录 | 职责 |
| --- | --- |
| `src/core` | 冻结的数据模型：`SNode`、`Cfg`、`DefUse`、`Cdg`、`Pdg`、`SliceResult` |
| `src/parser_adapter` | MoonBit 官方 AST → `SNode`，唯一依赖 parser 的包 |
| `src/cfg` / `src/defuse` / `src/cdg` / `src/pdg` | 四遍分析 |
| `src/slice` / `src/query` | 向后/向前切片、死代码、数据流路径、调用图 |
| `src/report` | JSON / DOT / SARIF / SVG / 自包含 HTML |
| `cmd/main` | 只做参数解析与输出 |
| `src/web` + `web/` | 同一管线编译到 JavaScript 的单页 playground |

可运行的核心命令：

```bash
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward
# 4,5,6,7,8
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward
# 7,10
./dev.sh run cmd/main -- dead --dir examples
# 7 行，全部是语料里故意埋的死代码
./dev.sh run cmd/main -- path --file examples/04_while.mbt --from i --to total
# n1 L4 -> n5 L7
./dev.sh run cmd/main -- review --diff <unified diff>
./dev.sh run cmd/main -- slice --dir cmd/main --file cmd/main/main.mbt --line 1086 --interprocedural
./dev.sh run cmd/main -- callers --dir . --name baseline_key
./dev.sh run cmd/main -- unused --dir src
```

## 4. README 与可复现性

- 英文：`README.md`；中文：`README.zh-CN.md`
- 目标、架构、安装、quickstart、支持子集、诚实的局限性都在 README 内
- 报告示例：`docs/report.html`（自包含）、`docs/report.png`
- 在线 playground：https://NaIWaniubi.github.io/moon-slice/

复现：

```bash
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"
./dev.sh check && ./dev.sh test
bash testdata/verify_corpus.sh
bash test/cli_smoke.sh
node web/smoke.mjs
```

## 5. 持续集成

`.github/workflows/ci.yml`：

- `test` job：`moon check` → `moon test` → native release 构建 → corpus →
  CLI smoke → committed bundle smoke → JS 重建 → rebuilt bundle smoke
- `action` job：`uses: ./` 真实执行 `action.yml`（安装工具链、构建，`dead` 与 `unused` 各跑一次 `--dir src --fail-on-findings`）

最近一次全绿：CI `41288517194`（`test` + `action`，338 tests，含 playground 预设检查），Pages `41288517199`；0.7.3 发布提交的 CI 为 `41288274865`。
构建产物与线上页面均在上表中可查。

## 6. 可运行示例

```bash
./dev.sh run cmd/main -- dead --dir examples
# examples/01_let.mbt:7
# examples/02_mut.mbt:4
# examples/03_if_else.mbt:4
# examples/06_match.mbt:4
# examples/08_dead_assignment.mbt:4
# examples/08_dead_assignment.mbt:5
# examples/09_shadowing.mbt:4
```

`examples/` 的每个文件都带 `EXPECT-BACKWARD` / `EXPECT-FORWARD` 头，并由
`testdata/expected.json` 与 `testdata/verify_corpus.sh` 校验。

## 7. 测试完整性

```bash
./dev.sh test
# Total tests: 338, passed: 338, failed: 0.
```

覆盖层次：

- 单元/白盒：parser adapter、CFG、def-use、CDG（两套构造）、PDG、query、suppress、report
- 跨包：切片节点集合、过程间返回 cone、接收者调用（箭头与拒绝两种方向）、真实仓库回归（`real_world_test.mbt`）
- 精度：路径枚举预言器逐对比较 reaching definitions；40 个种子化生成程序检查
  结构不变量、切片闭包、行投影、过程间超集
- 端到端：10 个 corpus 示例的精确行集合
- CLI：`test/cli_smoke.sh`（所有命令、JSON/SARIF、基线、就地抑制、门禁退出码、错误路径）
- 浏览器：`web/smoke.mjs` 与真实 Chrome 的 `web/playground_e2e.mjs`

## 8. mooncakes.io

**已发布**：`NaIWaniubi/moon-slice@0.7.0`（2026-10-31）、`@0.7.1`（2026-11-01，
仓库、清单、注册表三者对齐）、`@0.7.2`（就地抑制）、`@0.7.3`（接收者调用）。

```bash
moon publish
# ...
# Check passed
# Server status: 200 OK
```

注册表地址：<https://mooncakes.io/docs/NaIWaniubi/moon-slice>

发布产物与消费验证（在空模块里只依赖已发布版本，不读工作区源码）：

```bash
moon add NaIWaniubi/moon-slice@0.7.3
# Downloading NaIWaniubi/moon-slice@0.7.3
moon run cmd/main
# backward-lines=[4]
# line=1
# line=2
# line=3
# line=4
```

打包结果：`_build/publish/NaIWaniubi-moon-slice-0.7.3.zip`（1,182,221 字节，
146 个文件）。`moon publish` 会先解压打好的 zip 并再次 `moon check`，通过后
才上传。

发布细节、命名空间不匹配时的改名步骤、以及 CI 发布选项见 `PUBLISHING.md`。

## 9. 许可证

- 本项目：Apache-2.0（`LICENSE`）
- 依赖：`moonbitlang/parser` 0.4.6、`moonbitlang/x` 0.5.1，均为 Apache-2.0
- 算法引用（Weiser 1981；Ferrante–Ottenstein–Warren 1987）只引用思想，未复制代码
- 详见 `THIRD_PARTY.md`

## 五分钟复核

```bash
git clone https://github.com/NaIWaniubi/moon-slice
cd moon-slice
./dev.sh check
./dev.sh test
bash testdata/verify_corpus.sh
bash test/cli_smoke.sh
node web/smoke.mjs
./dev.sh run cmd/main -- dead --dir examples
```
