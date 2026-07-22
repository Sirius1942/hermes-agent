# 迭代 01 记录

## 决策

| 日期 | 决策 | 理由 | 后果 |
| --- | --- | --- | --- |
| 2026-07-13 | 创建 `codex/devloop-setup` | 用户要求进入开发准备；当前配置远端与目标 fork 不一致 | 远端拓扑保留为后续明确事项 |
| 2026-07-13 | 适配而不是复制 Darkroom Loop 状态 | Darkroom 规则、完成任务和 RodSki 证据属于其他产品 | Hermes 获得干净队列和原生验证规则 |
| 2026-07-13 | 保留外部 TestLoop 工具 | 避免把另一个产品 vendoring 到核心树 | `TESTLOOP_BIN` 指向本地可复用工具 |
| 2026-07-13 | 分离规划与设计、开发和验收循环 | Anthropic Harness 说明自评和隐藏上下文交接不可靠 | 各循环拥有独立产物和文件化上下文 |
| 2026-07-13 | 使用硬量表门禁 | 高平均分可能掩盖关键流程失败或假完成 | 关键维度必须 >= 4/5 且阻塞项为零 |
| 2026-07-13 | 增加 `loopctl` | 长任务中没有受保护的状态转移会发生漂移 | 单活动任务、依赖、证据、pivot、stop 和审计可执行 |
| 2026-07-13 | 启动二次开发架构设计讨论 | 官网扩展指南、源码边界和本地 Loop 规则需要汇总成可执行的中文二开基线 | 生成架构说明和讨论记录，`DGL-001` 保持进行中，等待真实业务场景 |
| 2026-07-13 | 合并规划者与设计者职责 | 用户确认规划和设计属于同一个循环；独立验收不应留在 DesignLoop 内部 | DesignLoop 更名为规划与设计循环，DevLoop 仅属于开发者，设计和实现验收统一归 TestLoop，人类负责人不变 |
| 2026-07-13 | 确认首个二次开发产品目标 | 用户要求使用三循环构建提供 WebUI 全功能的明快 Swift App | 完成 DGL-001，创建 iteration-02 并进入问题定义 |

## 验证证据

| 日期 | 命令 | 结果 | 说明 |
| --- | --- | --- | --- |
| 2026-07-13 | `jq empty ...` | pass | 所有 Loop 配置为有效 JSON |
| 2026-07-13 | `node --test .loops/tests/*.test.mjs` | pass | 10 个状态、仓库和文档语言契约测试通过 |
| 2026-07-13 | `scripts/run_tests.sh tests/hermes_cli/test_commands.py -q` | pass | 173 个测试通过 |
| 2026-07-13 | `npm test`（`/Users/sirius.chen/Projects/testloop`） | pass | 外部 TestLoop 32 个测试通过 |
| 2026-07-13 | 三个 Loop `prepare` | pass | DGL-001、DL-001、TL-001 提示词生成；队列保持 9 open |
| 2026-07-13 | 所有 Loop 驱动 `bash -n` | pass | 所有入口脚本语法有效 |
| 2026-07-13 | `node .loops/loopctl.mjs --loop=design status --json` | pass | `DGL-001` 为唯一活动任务，状态为 `8 open / 1 in_progress` |
| 2026-07-13 | 角色模型契约测试 | pass | 10 个 Loop 契约测试通过；任务卡只允许规划与设计者、开发者和 TestLoop 验收者，TestLoop 同时声明设计/实现两种验收模式 |
| 2026-07-13 | `node .loops/loopctl.mjs --loop=design done/start` | pass | `DGL-001` 完成，`DGL-002` 在 iteration-02 中成为唯一活动任务 |
