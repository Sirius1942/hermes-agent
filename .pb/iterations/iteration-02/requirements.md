# 迭代 02 需求

## 问题

Hermes 的 Web Dashboard 横跨内建管理页、REST、WebSocket、PTY Chat、认证、Profile、
Session 和动态插件。首版纯 Swift 逐页重写无法可信满足“全部 WebUI 功能”，还会制造第二套
事实源。

## 目标结果

交付 macOS 14+ 的 SwiftUI App：原生管理窗口、连接、进程和主题，使用受控 `WKWebView`
运行同一完整 Dashboard SPA，让全部 WebUI 功能在首个版本中可操作并可由 Rodski 验收。

## 验收标准

- [x] AC-01：完整 WebUI 功能、协议、认证和危险操作具有可追溯基线。
- [x] AC-02：比较全原生、纯包装和混合/兼容方案，接受 SwiftUI + WKWebView 方案。
- [x] AC-03：TestLoop 设计验收关键维度均 >=4/5 且无阻塞项。
- [x] AC-04：创建可生成、构建、测试的 macOS SwiftUI 工程，不修改 Agent Core。
- [x] AC-05：实现附着/自动启动、owned 进程清理、明快主题和全部 SPA 页面。
- [x] AC-06：验证离线、Hermes 缺失、启动/内容进程失败和重试入口。
- [x] AC-07：TestLoop 在真实 App 和 Dashboard 上执行 Rodski，App 6/6、页面 20/20。
- [x] AC-08：保护既有 Dashboard、共享配置、Session/Profile 和凭据边界。

## 非目标

- 逐页原生重写全部 Dashboard 页面。
- 在 Swift 进程内重写或嵌入 Python Agent Runtime。
- 自动安装 Hermes、管理远程服务进程或绕过现有认证。
- iOS/iPadOS、Mac App Store、自动更新、签名、公证、安装器和正式品牌资产。

## 约束

- App 不修改提示词缓存、消息交替、工具 Schema 或 Agent Loop。
- Profile/Session/config 继续由 Dashboard 与 `HERMES_HOME` 管理；App 偏好与后端配置分离。
- App 和 Rodski 都不得保存 Dashboard token、密码、API Key 或 OAuth 凭据。
- 不能破坏 Web Dashboard、Electron Desktop、TUI 或 API Server 消费者。
