# 迭代 04 需求：iOS 原生聊天工作台

**需求 ID：** CHAT-IOS-004
**状态：** 已形成设计契约，等待 TestLoop 验收
**来源：** 人类负责人 2026-07-15 批准方案 B 和 iOS 首个平台

## 1. 用户结果

用户在 iPhone 上打开 Hermes 后，能够像使用 ChatGPT 或 Codex 一样快速进入聊天、继续会话、
查看流式回复、处理工具请求、上传图片/PDF，并在需要管理模型、Skills、Plugins、MCP、Files、
Cron 或系统状态时进入同一后端提供的 Dashboard 看板。

聊天和看板是同一个 Hermes 工作台的两个视角，而不是两个后端、两个 SessionDB 或两套 Agent。

## 2. 当前行为与问题

当前 Swift App 是 macOS 专用的 SwiftUI + `WKWebView` 宿主；完整 Dashboard 和 Chat PTY 已
经可用，但它没有原生 iOS 目标，也没有针对触控、移动网络、后台挂起和窄屏重新组织聊天。

现有后端已经提供 iOS 原生客户端所需的大部分边界：

- `/api/ws` JSON-RPC WebSocket；
- `gateway.ready`、`message.start/delta/complete`、`thinking`、`reasoning`、`tool.*`、
  `approval/clarify/sudo/secret` 等事件；
- `session.create`、`session.list`、`session.resume`、`session.interrupt`、`prompt.submit`；
- `image.attach_bytes` 和 `pdf.attach` 的远程附件路径；
- Dashboard `/api/status` 的版本 / 认证门禁信息；
- gated 模式的 `POST /api/auth/ws-ticket` 一次性 30 秒 WebSocket ticket。

## 3. 范围内

### 原生聊天

- iOS SwiftUI 聊天工作台，默认进入 Chat。
- 会话列表、搜索入口、创建会话、恢复会话、当前会话状态和未发送草稿。
- 用户消息、Markdown / 代码、流式回复、推理折叠、工具活动、错误、停止和重试。
- 工具审批、澄清、sudo 和 secret 请求使用原生确认 / 输入 sheet。
- 图片和 PDF 附件使用系统选择器，上传通过现有远程附件方法。
- 模型 / Profile / 基础会话设置复用后端事实源，客户端只保存界面偏好。
- 网络断开、应用切后台、恢复前台和 ticket 过期后的重连与会话重新绑定。

### 看板 / 管理中心

- 使用认证后的 `WKWebView` 打开完整 Dashboard，而不是在 iOS 中复制所有管理页面。
- 保留既有 Models、Files、Skills、Plugins、MCP、Channels、Webhooks、Profiles、Config、
  System、Docs 和动态插件能力。
- 从原生聊天可以进入看板，从看板可以回到当前会话；切换不创建第二个 Session。

### 后端兼容

- 使用现有 `/api/ws` JSON-RPC 和 REST / auth 边界，不改 Agent Loop、Prompt、工具 Schema、
  SessionDB 或 Provider 行为。
- 对 `gateway.ready` 新增的可选版本 / capability 字段保持向后兼容；老后端缺少字段时按
  基线能力工作，缺少必需方法时明确阻止，而不是显示假按钮。
- iOS 只接受 HTTPS / WSS 的生产连接；局域网 HTTP 仅在明确的开发模式中允许。

## 4. 非目标

- Android、Windows、Linux 和本轮正式 App Store 发布。
- iOS 本地启动、安装或管理 `hermes` 进程；iOS 没有 macOS 的 owned Process 能力。
- 在 iOS 中原生重写完整 Dashboard 管理页面。
- 复制 Agent Core、工具注册表、模型调用或消息持久化。
- 默认离线生成、后台无限时长流式任务、推送通知和语音通话；这些需要单独后端契约。
- 为了短期 UX 而把 Session 消息完整复制到 iOS 私有数据库。

## 5. 核心验收标准

| ID | 可观察行为 | 真实证据 |
| --- | --- | --- |
| IOS-CHAT-01 | iOS App 可通过 HTTPS/WSS 连接真实 Hermes backend 并完成认证 | iOS Simulator / 真机 + 真实服务 |
| IOS-CHAT-02 | 能创建、列出、恢复会话，历史来自后端而非本地假数据 | JSON-RPC 记录 + SessionDB 对照 |
| IOS-CHAT-03 | `prompt.submit` 后按顺序显示 message/tool/reasoning 事件并结束于 complete/error | 真实长回复和工具调用 |
| IOS-CHAT-04 | 流式期间可停止，失败后可重试且不重复提交同一用户消息 | 断网 / 中断 / 重试场景 |
| IOS-CHAT-05 | approval、clarify、sudo、secret 请求不会被忽略或误自动批准 | 真实交互场景和安全审查 |
| IOS-CHAT-06 | 图片/PDF 上传使用后端远程附件方法，不暴露本地路径和凭据 | 真实文件上传 + 数据扫描 |
| IOS-CHAT-07 | 后台挂起后前台恢复能重连、重新绑定 Session，并正确显示仍在运行或已完成的 turn | iOS 生命周期场景 |
| IOS-BOARD-01 | 看板可以打开完整 Dashboard，并从 Chat 返回不丢失会话 | WKWebView 真实导航 |
| IOS-COMPAT-01 | 老后端 / 可选能力缺失时隐藏对应入口并给出可行动提示 | capability 缺失夹具 + 真实旧服务 |
| IOS-SEC-01 | token / ticket / cookie 不进入日志、截图、崩溃信息或普通 UserDefaults | 源码、运行日志和持久化扫描 |

## 6. 性能与体验目标

- 已连接且认证有效时，从 App 前台到聊天可输入状态不超过 2 秒（不含模型首 token）。
- 断线后不显示无限旋转；最多 3 次自动重连后展示明确的“重新连接 / 更换服务器 / 打开看板”
  操作。
- 流式消息不因单个 delta 重建整个会话列表；消息 reducer 必须按 session_id 和消息标识增量更新。
- 首屏只展示当前会话和必要状态；管理能力不在聊天首屏堆叠。

## 7. 人类门禁

- iOS Bundle ID、签名团队、Keychain entitlement、App Store / TestFlight 计划。
- 是否接受给 `gateway.ready` 增加可选 `protocol_version` / `capabilities` 字段。
- 远程 OAuth、静态 token 和局域网开发模式的发布策略。
- 是否把 iPadOS 纳入同一目标；当前默认为 iPhone-only。

## 8. DesignLoop 交互产物要求

本迭代必须遵守 `.designloop/INTERACTION_DESIGN_STANDARD.md`。在 TestLoop 设计验收前，以下
产物必须相互一致：

- `06-low-fidelity-wireframes.md`：覆盖连接、聊天、会话、审批、看板和断线恢复；
- `06-interaction-verification.md`：每个主要动作映射稳定 `IOS-UX-*` 场景；
- `06-design-review.md`：唯一结论为 `ready_for_testloop`，但不冒充 TestLoop `pass`；
- `07-testloop-handoff.md`：把低保真、验证场景和真实证据要求交给独立验收者。

缺少任何一项、关键状态未覆盖、只有静态截图或没有真实 backend wiring 计划时，设计不能
进入 DevLoop。
