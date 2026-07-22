# Hermes Agent 项目工作簿

本目录是当前检出版本的项目管理入口，补充但不替代仓库已有工程规则。

## 权威顺序

文档冲突时按以下顺序处理：

1. `AGENTS.md` 和 `CONTRIBUTING.md`
2. `.pb/conventions/PROJECT_BOUNDARY.md`
3. `.pb/specs/SPECS_CONTRACT_ARCHITECTURE.md`
4. `.pb/iterations/` 下的当前迭代
5. 功能专属计划或实现说明

代码和测试描述当前行为，但不能单独覆盖刻意设计。改变行为前先复现问题，并检查
相关机制的历史意图。

## 工作区域

| 区域 | 用途 |
| --- | --- |
| `conventions/` | 稳定的项目边界和不可违反的不变量 |
| `requirements/` | 需求进入和产品级需求索引 |
| `design/` | 架构地图和跨迭代设计决策 |
| `specs/` | 契约层级、变更门禁和验收所有权 |
| `iterations/` | 当前迭代的需求、设计、任务和证据 |
| `templates/` | 新迭代的可复制文件 |

## 开发入口

1. 阅读 `AGENTS.md` 和 `.pb/conventions/PROJECT_BOUNDARY.md`。
2. 打开 `.pb/iterations/README.md` 中的当前迭代。
3. 由规划与设计者使用 `.designloop/` 定义问题、方案和迭代契约。
4. 将设计产物交给 `.testloop/` 进行全新上下文的设计验收。
5. 设计验收通过后，由开发者使用 `.devloop/` 实现一个边界明确的切片。
6. 将真实实现产物交给 `.testloop/` 进行实现验收。
7. Python 测试只通过 `scripts/run_tests.sh` 运行。

共享 Harness、量表、预算、模板和操作命令见 `.loops/README.md` 与
`.loops/HARNESS_DESIGN.md`。
