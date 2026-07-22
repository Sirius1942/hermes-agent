# 迭代 03：macOS 聊天优先体验收敛

**状态：** 已经人类批准 pivot，未进入实现
**规划与设计者：** 规划与设计循环
**开发者：** 待 DevLoop 交接
**验收者：** 待 TestLoop 设计验收
**人类负责人：** 用户

## 目标

在不复制 Hermes Agent Core、Dashboard Chat 协议或第二套会话事实源的前提下，把当前
macOS App 从“完整 Dashboard 安全宿主”优化为“聊天优先的 macOS 工作台”。

本轮重点是减少主路径上的基础设施噪声、缩短进入聊天的路径、改善连接失败和会话恢复，
并保留完整 WebUI 作为管理和高级功能入口。

## Pivot 结果

2026-07-15，人类负责人选择原生聊天客户端方案 B，并把首个新增平台收敛为 iOS。完整
Dashboard 继续作为看板 / 管理中心，低频能力移入高级入口但不物理删除；macOS 现有宿主和
自动启动能力继续保留。本迭代在设计契约前停止，后续设计转入 `iteration-04`，本文保留为
决策历史，不回写成从未推荐过方案 A。

## 当前证据

- `apps/macos/HermesMac/ContentView.swift` 当前把完整 Dashboard 放进主内容区，工具栏同时暴露
  明快主题、重新加载、在浏览器中打开和设置。
- `apps/macos/HermesMac/SettingsView.swift` 当前把 Dashboard 地址、自动启动、Hermes 路径和
  明快主题全部放在一个设置表单中。
- 当前 WebView 已经通过真实 Dashboard 提供 Chat PTY、会话、模型、文件、插件和管理页面；
  上一轮 TestLoop 结果为 App `6/6`、Dashboard `20/20`。
- 上一轮架构契约明确：不能复制 Agent Loop，不能制造第二套 Dashboard 事实源，不能破坏
  既有 Profile、Session、配置、认证和 WebUI。

## 本轮工作状态

| 阶段 | 结果 | 产物 |
| --- | --- | --- |
| 适用性与预算 | 已完成 | `.designloop/work/iteration-03/01-loop-charter.md` |
| 问题、目标与非目标 | 已完成 | `.designloop/work/iteration-03/02-problem-frame.md` |
| 约束与真实产物研究 | 已完成 | `.designloop/work/iteration-03/03-constraints-research.md` |
| 备选方案与取舍 | 已完成 | `.designloop/work/iteration-03/04-alternatives.md` |
| 设计契约与量表 | 待讨论 | `DGL-03-005` |
| 交互方案与原型契约 | 待讨论 | `DGL-03-006` |
| TestLoop 设计验收交接 | 待讨论 | `DGL-03-007` |

## 本迭代原推荐（已被人类 pivot）

采用“轻量聊天优先壳”：App 默认进入 `/chat`，继续使用真实 Dashboard Chat，不在 Swift
中重写 transcript、composer、工具调用或消息协议；完整 Dashboard 通过明确的“管理中心”
入口保留。明快主题、浏览器打开、手动 Hermes 路径和自动启动等低频基础设施能力移入高级
设置，不再占据聊天主路径。

该推荐未进入实现。当前已批准方向见 `../iteration-04/`。
