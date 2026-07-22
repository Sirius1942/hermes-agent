# 迭代 04 设计：iOS 原生聊天 + Dashboard 看板工作台

## 1. 方案决定

采用方案 B，但把方案 B 定义为“原生聊天体验 + 后端协议复用”，不是“把 Hermes Runtime
编译进 iOS”。iOS 负责渲染和交互；Hermes backend 继续负责 Agent、Provider、工具、Session、
Profile、认证和所有管理事实。

```text
iOS SwiftUI
  ├─ ChatStore / MessageReducer / Composer / ToolCards
  ├─ HermesGatewayClient（URLSessionWebSocketTask，JSON-RPC）
  ├─ AuthSession（OAuth WebView ticket / 静态 token Keychain）
  └─ BoardWebView（完整 Dashboard，看板与高级功能）
          │
          ├─ HTTPS REST /api/status、/api/auth/ws-ticket、附件
          └─ WSS /api/ws：session、prompt、事件和审批
          │
Hermes backend：Agent Core、SessionDB、Tools、Profiles、Plugins、MCP、Dashboard
```

## 2. iOS 模块边界

| 模块 | 责任 | 不负责 |
| --- | --- | --- |
| `HermesIOSApp` | Scene、Tab、生命周期、深链和窗口入口 | Agent 或网络协议细节 |
| `GatewayConnectionStore` | URL、连接状态、重连退避、ticket 刷新 | 消息渲染 |
| `HermesGatewayClient` | JSON-RPC request/response、事件分发、请求超时 | 业务决策和 SwiftUI |
| `SessionStore` | 当前会话、列表、恢复、运行状态 | 私自复制后端历史 |
| `MessageReducer` | 按事件增量更新消息、工具和审批状态 | 发起 API 请求 |
| `ComposerStore` | 草稿、附件选择、提交 / 停止状态 | 直接持久化 token |
| `BoardWebView` | 登录、完整管理 Dashboard、ticket mint bridge | 原生聊天消息状态 |
| `SecureStore` | Keychain 保存服务器配置引用和静态 token | 普通 UserDefaults 保存秘密 |

实现时可以先把这些模块放在 `apps/ios/`，只有出现 macOS 和 iOS 的真实共同消费者后才
抽取共享 Swift Package，避免提前建空的跨平台基础设施。

## 3. 原生聊天工作台布局

### iPhone

```text
┌─────────────────────────┐
│ 当前会话 · Profile/Model │ 连接状态 / 看板入口
├─────────────────────────┤
│                         │
│  用户消息                │
│  助手流式回复             │  可折叠推理 / 工具卡片
│  工具活动 / 审批卡片       │
│                         │
├─────────────────────────┤
│ ＋附件  输入框      停止/发送 │
├─────────────────────────┤
│ 聊天        看板        设置 │
└─────────────────────────┘
```

- 会话列表通过导航栏按钮或侧滑 sheet 打开，不在消息首屏常驻占宽。
- 看板 Tab 进入完整 Dashboard；从看板返回时保留当前 `session_id`。
- 工具审批、澄清、sudo 和 secret 使用原生 sheet，不能被滚动消息淹没。

### iPadOS 未来适配

本轮不承诺 iPadOS；若人类批准，将采用 `NavigationSplitView` 把会话列表固定在左侧，
不改变 JSON-RPC 和消息 reducer 契约。

## 4. JSON-RPC 交互契约

### 必需方法

- `session.create`
- `session.list`
- `session.resume`
- `session.interrupt`
- `prompt.submit`

### 必需事件

- `gateway.ready`
- `session.info`
- `message.start`
- `message.delta`
- `message.complete`
- `thinking.delta` / `reasoning.delta` / `reasoning.available`
- `tool.start` / `tool.progress` / `tool.complete`
- `approval.request` / `clarify.request` / `sudo.request` / `secret.request`
- `error`

### 可选能力

- `image.attach_bytes`
- `pdf.attach`
- slash / command catalog
- 模型、Profile 和辅助模型读取接口

可选能力缺失时，iOS 隐藏对应按钮并显示后端版本提示；不能把禁用功能渲染成可以点击的
空壳。对于未知事件，客户端记录非敏感类型并忽略 payload，保证后端向前扩展不使聊天崩溃。

## 5. 认证和隐私

### OAuth / gated backend

1. Dashboard `WKWebView` 打开服务地址并完成既有登录。
2. WebView 在受限 origin 检查下调用现有 `POST /api/auth/ws-ticket`。
3. 只把一次性 30 秒 ticket 通过受限 message handler 交给原生连接层。
4. 原生使用 `wss://…/api/ws?ticket=…`，ticket 只保存在内存，断线重新 mint。

原生层不读取 OAuth cookie，不把密码或刷新凭据写入日志；WebView message handler 只允许
当前服务 origin 和固定消息名。

### 静态 token / 局域网开发

- 用户明确输入的 token 使用 iOS Keychain，界面只展示末尾预览。
- 生产连接要求 HTTPS/WSS；HTTP 只在开发构建和用户明确开启的局域网模式中允许。
- 普通 UserDefaults 只保存服务 URL、Profile、界面偏好和是否显示高级入口。

## 6. 生命周期与恢复

```text
disconnected
  → authenticating
  → connecting
  → ready
  → streaming / awaitingInput
  → backgrounded
  → reconnecting
  → ready 或 reauthRequired / failed
```

- iOS 进入后台不保证 WebSocket 继续；前台恢复后重新获取 ticket、重连并 `session.resume`。
- 如果后端 turn 仍运行，界面显示“后台运行中”并继续接收后续事件；如果已完成，重新读取
  后端历史，不重复插入本地消息。
- 网络失败时保留未发送草稿；在用户明确点击前不自动重发，避免不确定状态造成重复执行。
- `prompt.submit` 请求的 ACK、事件流和 `message.complete` 分开处理，不能把长任务误报为超时。

## 7. 后端演进兼容

优先使用现有 `/api/status` 的 `version` / `auth_required` 信息和方法级错误。为了让 iOS
能够可靠地隐藏可选功能，设计允许给 `gateway.ready.payload` 增加可选字段：

```json
{
  "protocol_version": 1,
  "capabilities": ["session.resume", "image.attach_bytes", "approval.request"]
}
```

旧客户端忽略新字段；新客户端在字段缺失时按最低基线运行。这个扩展不进入 Agent Core、
Prompt 或模型工具 Schema，只作用于网关边缘，且必须由 TestLoop 验证旧后端兼容。

## 8. 看板策略

看板使用同一认证后的 Dashboard `WKWebView`，承载完整现有功能。iOS 原生层只提供：

- 看板入口和返回聊天入口；
- 服务连接状态和重新认证入口；
- 必要的外链、下载和安全策略；
- 当前 Profile / server 上下文提示。

不在本轮逐页原生化 Models、Files、Plugins、MCP、Channels、Cron 或 System 页面。

## 9. 分期建议

### 第一切片：聊天闭环

连接、认证、session.list/create/resume、文本流式、停止、重试、断线恢复和看板入口。

### 第二切片：工作能力

工具卡片、审批 / 澄清 / secret、图片/PDF、模型/Profile 选择和 slash command palette。

### 第三切片：移动体验

后台恢复优化、草稿保护、深链、通知或语音；每项必须先补后端契约和隐私评估。

本轮 DevLoop 只接收第一切片和已批准的第二切片边界，不把第三切片偷偷并入。

## 10. 低保真与交互验证

交互设计不以本文件中的单张布局图为完成证据。权威交互产物为：

- `.designloop/work/iteration-04/06-low-fidelity-wireframes.md`：六组状态图；
- `.designloop/work/iteration-04/06-interaction-verification.md`：15 个可执行场景；
- `.designloop/work/iteration-04/06-design-review.md`：设计完整性评审。

低保真图中的连接、会话、发送、停止、工具、审批、附件、看板和恢复动作均有场景 ID；涉及
认证、WebSocket、Session、附件、网络和生命周期的场景必须在真实 backend 上验证，不能
只用静态 SwiftUI preview 或 mock server 代替。
