# 迭代 01 设计

## 结构

- `.pb/` 保存持久治理、迭代范围和决策证据。
- `.designloop/` 是规划与设计循环，由规划与设计者负责问题定义、备选方案、契约和验收交接。
- `.devloop/` 是开发循环，由开发者负责实现说明、自查和 TestLoop 交接。
- `.testloop/` 是验收循环，由验收评估者在全新上下文中验收设计或实现产物。
- `.loops/` 负责共享策略、量表、模板、驱动和通用设计/开发状态控制器。
- `.loops/README.md` 是操作者入口。

设计参考 Anthropic 长时应用 Harness 的分工、评估和文件交接原则，但保留 Hermes 自己的
缓存、窄核心、Profile 和测试约束。

## 二次开发架构讨论

- `.pb/design/SECONDARY_DEVELOPMENT_ARCHITECTURE.md` 汇总官网开发指南、源码所有权、
  核心执行链和扩展决策树，作为跨迭代中文架构基线。
- `.pb/iterations/iteration-01/二次开发设计讨论.md` 保存本轮候选方向、默认假设和待用户
  决策项。
- `DGL-001` 已在用户选择 Swift App 作为首个业务场景后完成；产品问题定义和设计转入
  `iteration-02` 的 `DGL-002`，在 TestLoop 设计验收前不进入 DevLoop 产品实现。

## 安全决策

- 驱动默认只准备提示词，除非显式提供 Agent 命令，否则不会调用 Agent。
- 没有驱动使用权限绕过参数。
- 运行日志和生成提示词属于本地过程数据。
- TestLoop 仍通过 `TESTLOOP_BIN` 使用外部工具，不能将其实现 vendoring 到 Hermes 核心。
- 规划与设计者、开发者和 TestLoop 验收者角色分离；前两者不能最终接受自己的工作。
- `pass` 要求每个关键量表维度 >= 4/5 且阻塞项为零。
- `pass`、`fix`、`pivot`、`stop` 都是带预算和人类门禁的持久决策。
