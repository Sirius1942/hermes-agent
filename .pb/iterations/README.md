# 迭代管理

## 当前迭代

| 迭代 | 状态 | 目的 |
| --- | --- | --- |
| [`iteration-01`](iteration-01/README.md) | complete | 开发准备、三循环 Harness 与二次开发架构讨论 |
| [`iteration-02`](iteration-02/README.md) | accepted | Hermes macOS SwiftUI + Dashboard 完整兼容宿主 |
| [`iteration-03`](iteration-03/README.md) | pivoted | macOS 聊天优先壳讨论；人类选择原生方案 B 后停止 |
| [`iteration-04`](iteration-04/README.md) | design | iOS 原生聊天与 Dashboard 看板工作台 |
| [`iteration-05`](iteration-05/README.md) | design-review | macOS/iOS 双原生 Chat 工作台，开源 WebUI 不改 |

## 迭代规则

- 一个迭代只负责一个连贯结果。
- 需求描述行为，设计描述边界，任务描述执行，record 保存证据和决策。
- 每个任务必须有可观察完成条件和验证命令。
- 范围扩大、新依赖、Schema 迁移、新核心工具和缓存影响必须有明确决策记录。
- 只有 DevLoop 实现证据与 TestLoop 独立验证一致后，迭代才能关闭。

新建迭代时复制 `.pb/templates/iteration/`，改名为 `iteration-XX`，再更新本索引。
