# 验收对照表

按「2026 MoonBit 国产基础软件开源大赛-10 月黑客松」验收指南逐条对照。所有
命令都在仓库根目录执行；当前版本 `v0.5.0`，`master` 已有 50+ 个提交。

| # | 验收要求 | 状态 | 证据 |
| --- | --- | --- | --- |
| 1 | MoonBit 为主要实现语言，moonc >= 0.10.16 | 通过 | `moonc -v` = `v0.10.17+d971670cd` |
| 2 | 仓库公开、提交记录清晰 | 通过 | https://github.com/cs6210501-lab/moon-slice，50+ commits，tag `v0.5.0` |
| 3 | 源代码结构清晰，核心功能可完成 | 通过 | 8 个库包 + CLI + playground；见下方命令 |
| 4 | README：目标、安装、使用、示例、可复现 | 通过 | `README.md` / `README.zh-CN.md`，quickstart 逐条可运行 |
| 5 | CI 覆盖检查、构建、测试 | 通过 | `.github/workflows/ci.yml` 的 `test` / `action` 两个 job |
| 6 | 至少一个可运行示例 | 通过 | `examples/` 10 个；在线 playground |
| 7 | 完整测试覆盖核心路径 | 通过 | 284 个测试 + corpus + CLI smoke + web smoke |
| 8 | 发布到 mooncakes.io | **待完成** | 打包已验证；缺维护者 `moon login`，见 `PUBLISHING.md` |
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
git tag --sort=-v:refname   # v0.5.0 v0.4.2 v0.4.1 ...
```

公开地址：https://github.com/cs6210501-lab/moon-slice

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
```

## 4. README 与可复现性

- 英文：`README.md`；中文：`README.zh-CN.md`
- 目标、架构、安装、quickstart、支持子集、诚实的局限性都在 README 内
- 报告示例：`docs/report.html`（自包含）、`docs/report.png`
- 在线 playground：https://cs6210501-lab.github.io/moon-slice/

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
- `action` job：`uses: ./` 真实执行 `action.yml`（安装工具链、构建、`dead --dir src --fail-on-findings`）

最近一次全绿：CI `41014834580`（`test` + `action`，284 tests，含 playground 预设检查），Pages `41014834554`。
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
# Total tests: 284, passed: 284, failed: 0.
```

覆盖层次：

- 单元/白盒：parser adapter、CFG、def-use、CDG（两套构造）、PDG、query、report
- 跨包：切片节点集合、过程间返回 cone、真实仓库回归（`real_world_test.mbt`）
- 精度：路径枚举预言器逐对比较 reaching definitions；40 个种子化生成程序检查
  结构不变量、切片闭包、行投影、过程间超集
- 端到端：10 个 corpus 示例的精确行集合
- CLI：`test/cli_smoke.sh`（所有命令、JSON/SARIF、基线、门禁退出码、错误路径）
- 浏览器：`web/smoke.mjs` 与真实 Chrome 的 `web/playground_e2e.mjs`

## 8. mooncakes.io

**当前未发布。** 这是唯一需要维护者账号动作的条目：

```bash
moon login              # 交互式，需要终端和浏览器
bash tools/publish.sh   # 校验、打包、预览、确认后发布
```

已经验证到登录前一步：

```bash
moon package
# Package to .../_build/publish/chen-moon-slice-0.5.0.zip  (976 KB, 122 files)
```

若登录账号的命名空间不是 `chen`，`PUBLISHING.md` 给出了改模块名和 11 处
自引用的完整命令。发布后的验证步骤也在同一文件里。

## 9. 许可证

- 本项目：Apache-2.0（`LICENSE`）
- 依赖：`moonbitlang/parser` 0.4.6、`moonbitlang/x` 0.5.1，均为 Apache-2.0
- 算法引用（Weiser 1981；Ferrante–Ottenstein–Warren 1987）只引用思想，未复制代码
- 详见 `THIRD_PARTY.md`

## 五分钟复核

```bash
git clone https://github.com/cs6210501-lab/moon-slice
cd moon-slice
./dev.sh check
./dev.sh test
bash testdata/verify_corpus.sh
bash test/cli_smoke.sh
node web/smoke.mjs
./dev.sh run cmd/main -- dead --dir examples
```
