# 迭代 04 记录

## 2026-07-15：承接人类批准的方案 B

人类负责人选择原生聊天客户端方案 B，明确产品目标是“聊天框 + 看板”的工作台，而不是
简单地把完整 Dashboard 缩小到手机上。

### 已确认取舍

- 低频能力从聊天主路径迁移到高级入口，但保留可查找、可使用和后端一致性。
- 默认进入 Chat；完整 Dashboard 是看板 / 管理中心。
- macOS 自动启动能力保留在高级设置；iOS 不启动本机 Hermes 进程，只连接远程或局域网服务。
- 后端、Agent、Session、Profile、认证和功能保持一致，iOS 只改变交互表面。
- 新聊天 App 首个平台为 iOS；Android、iPadOS 专门优化、macOS 原生聊天重写留待后续。

## 设计原则

1. 原生化聊天交互，不原生化 Agent Runtime。
2. 由真实 `/api/ws` JSON-RPC 驱动消息、工具、审批和会话，不用 mock 代替 wiring。
3. 看板继续使用完整 Dashboard，避免重复实现管理页面。
4. 后端可演进，客户端对未知事件和可选能力保持降级，不显示假按钮。
5. 移动网络和后台挂起是正常状态，断线恢复优先于“永远保持连接”的假设。

## 未决人类门禁

- iOS 首版是否严格 iPhone-only，还是同一 target 同时支持 iPadOS；当前按 iPhone-only 设计。
- 是否批准 `gateway.ready` 增加可选 `protocol_version` / `capabilities` 字段。
- 远程 OAuth 是否采用 Dashboard WebView mint ticket bridge，还是先限制为 Keychain 静态 token。
- iOS 首版是否包含图片/PDF和审批交互；当前契约将其列为第二切片，但协议边界已纳入设计。
- Bundle ID、签名团队、Keychain entitlement、TestFlight 与 App Store 门禁。

## 下一步

本轮设计已形成交接包，交给 TestLoop 做全新上下文的设计验收。TestLoop 未通过前，不写
iOS SwiftUI 产品代码。
