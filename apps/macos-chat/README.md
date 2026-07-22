# Hermes Chat for macOS MVP

这是全新的原生 Hermes Chat 工作台，与 `apps/macos-admin` 的 WKWebView Dashboard 宿主是两个独立
产品。Chat 直接连接 Hermes headless backend 和 `/api/ws`，复用 Hermes 的 Session、Provider、
Agent、工具和 Prompt 契约，不加载 Dashboard，也不建立第二套 Agent 或 SessionDB。

## 产品边界

- 产品名：`Hermes Chat`
- Bundle：`com.nousresearch.hermes.chat.macos`
- URL scheme：`hermes-chat`
- UserDefaults suite：`com.nousresearch.hermes.chat.macos.preferences`
- Keychain service：`com.nousresearch.hermes.chat.macos.keychain`
- WebKit：禁止
- 本机后端：优先 `hermes serve --no-open`；旧运行时只允许受控
  `dashboard --skip-build --no-open` headless 命令名兼容
- 进程所有权：只停止本 App 创建的 backend，不停止 Dashboard、Gateway 或 Hermes Admin

## MVP 页面

- `MAC-WORKBENCH`：Session / Chat / Inspector 三栏工作台；窄窗口先折叠 Inspector；
- `MAC-CONNECTION`：本机 owned backend、远程连接、重试和错误恢复；
- `MAC-PROMPT`：approval、clarify、secret、sudo，取消和 Escape 默认拒绝；
- `MAC-MANAGEMENT`：连接、Provider、Session、自动启动、日志和搜索六个真实模块；
- Provider 恢复：中文摘要、配置服务、折叠诊断、保存后等待明确重试，不自动重发。

## 构建和测试

```bash
cd apps/macos-chat
xcodegen generate --spec project.yml
xcodebuild \
  -project HermesChatMac.xcodeproj \
  -scheme HermesChatMac \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

真实 UI 验收使用 `HermesChatMacUI` scheme，并要求输出当前构建截图、连续录像、Accessibility、
RPC、SessionDB、进程/网络、系统错误和隐私证据。单元测试或旧 Hermes Admin 截图不能替代正式验收。
