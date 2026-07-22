# 迭代 04：iOS 原生聊天与 Dashboard 看板工作台

> **状态：已被 iteration-05 取代。** 用户已澄清桌面目标是 macOS 原生 App UI，不是
> Dashboard/WKWebView 看板；本迭代只作为需求演进历史。

**状态：** 规划与设计产物已形成，等待 TestLoop 独立设计验收
**规划与设计者：** 规划与设计循环
**开发者：** 待 DevLoop 交接
**验收者：** TestLoop
**人类负责人：** 用户

## 人类批准方向

本迭代承接 iteration-03 的战略 pivot，采用方案 B：原生聊天客户端。首个新增客户端平台
限定为 iOS；Android、macOS 原生聊天重写和正式发布不在本迭代范围。

用户可见产品由两个互补表面组成：

```text
iOS 原生聊天工作台
  ├─ 原生会话列表、消息流、输入框、附件、工具活动和审批交互
  └─ 复用 Hermes /api/ws JSON-RPC 和现有会话事实源

Dashboard 看板 / 管理中心
  └─ 认证后的完整 WebUI：模型、文件、Skills、Plugins、MCP、Channels、Cron、System、Docs…
```

后端、Agent、模型、工具、Session、Profile、认证和管理功能保持一致；界面可以针对 iOS
的触控、键盘、窄屏和后台恢复重新设计。

## 平台解释

- iOS 第一阶段只连接远程或局域网可达的 Hermes Dashboard / headless backend。
- iOS 不能启动本机 `hermes` 进程，因此“自动启动”只在 macOS 客户端的高级设置中继续保留；
  iOS 只提供连接、认证、重试和服务地址管理，不伪造本地启动能力。
- 当前 `apps/macos/` 兼容宿主保留，不在本迭代删除或强行改造成原生聊天客户端；后续可在
  共享协议客户端稳定后再设计 macOS 工作台。

## 本轮状态

| 阶段 | 状态 | 主要产物 |
| --- | --- | --- |
| 适用性与预算 | 完成 | `.designloop/work/iteration-04/01-loop-charter.md` |
| 问题与用户结果 | 完成 | `.designloop/work/iteration-04/02-problem-frame.md` |
| 约束、协议与认证研究 | 完成 | `.designloop/work/iteration-04/03-constraints-research.md` |
| 方案 B 与备选方案 | 完成 | `.designloop/work/iteration-04/04-alternatives-and-decision.md` |
| 设计契约与验收量表 | 完成 | `.designloop/work/iteration-04/05-sprint-contract.md`、`05-design-rubric.md` |
| 交互方案与原型契约 | 完成 | `06-design-proposal.md`、`06-prototype-contract.md` |
| 低保真、验证矩阵与设计评审 | 完成 | `06-low-fidelity-wireframes.md`、`06-interaction-verification.md`、`06-design-review.md` |
| TestLoop 设计交接 | 完成 | `.designloop/work/iteration-04/07-testloop-handoff.md` |
| 独立设计验收 | 待执行 | `DGL-04-008` |

## 下一道门禁

TestLoop 必须在全新上下文中验证真实 JSON-RPC WebSocket、认证 ticket、会话恢复、流式消息、
工具审批、附件、断线重连、Dashboard 看板入口，以及低保真图与 15 个交互场景的对应关系。
没有独立设计验收 `pass`，不进入 iOS
SwiftUI 实现。
