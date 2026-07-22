# 迭代 02 任务

| ID | 任务 | Loop/角色 | 依赖 | 完成定义 | 状态 |
| --- | --- | --- | --- | --- | --- |
| SW-001 | WebUI 功能、协议和视觉基线盘点 | 规划与设计循环 | - | 功能矩阵、默认假设和待决策项完整 | done |
| SW-002 | 比较原生、WebView 和混合架构 | 规划与设计循环 | SW-001 | 推荐方案、风险、兼容和回滚明确 | done |
| SW-003 | 建立首切片设计契约和视觉原型 | 规划与设计循环 | SW-002 | 可观察验收、真实产物和预算明确 | done |
| SW-004 | TestLoop 设计验收 | TestLoop `design` | SW-003 | `pass` 或有可执行反馈 | done |
| SW-005 | 创建 SwiftUI 工程和 Dashboard 客户端 | DevLoop 开发者 | SW-004 | 工程可构建，完整 Dashboard SPA 连通 | done |
| SW-006 | 实现明快 App 壳层和完整兼容层 | DevLoop 开发者 | SW-005 | 正常、失败、进程和安全流程可真实操作 | done |
| SW-007 | TestLoop 实现验收 | TestLoop `implementation` | SW-006 | Swift 15/15、Rodski App 6/6、Dashboard 20/20 | done |
| SW-008 | 记录渐进原生化和发布门禁 | 规划与设计循环 | SW-007 | 兼容回退、后续范围和人类门禁明确 | done |
