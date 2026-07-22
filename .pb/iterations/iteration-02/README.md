# 迭代 02：Hermes macOS 完整 Dashboard 宿主

**状态：** 实现验收通过，进入发布准备  
**规划与设计者：** 规划与设计循环  
**开发者：** DevLoop  
**验收者：** TestLoop  
**目标：** 交付可运行的 SwiftUI macOS App，并以同一 Dashboard SPA 提供全部 WebUI 功能

## 已交付结果

`apps/macos/` 是 macOS 14+ 的 SwiftUI App。它提供原生窗口、工具栏、设置、连接状态、
进程所有权、错误恢复和明快主题，并通过受控 `WKWebView` 加载完整 Hermes Dashboard SPA。
因此全部内建页面、Chat PTY、认证和动态插件页在首个实现迭代即可真实使用。

## 范围

- 范围内：SwiftUI 工程、Dashboard 连接/自动启动、owned 进程清理、完整 WebUI 兼容层、
  明快主题、外链/OAuth/下载安全、失败恢复、Swift 与 Rodski 验收。
- 范围外：Agent Core 复制、逐页原生重写、iOS/iPadOS、签名、公证、App Store、安装器、
  自动更新和未批准的新后端协议。

## 运行事实

本地完整 WebUI 使用：

```bash
hermes dashboard --skip-build --no-open --host 127.0.0.1 --port 9119
```

`hermes serve` 是无 SPA 的 headless backend，不是本 App 的本地 WebUI 启动命令。

## 退出门禁状态

- [x] 规划与设计循环产物通过 TestLoop `design` 验收。
- [x] SwiftUI/WKWebView 架构经人类请求确认并由 DevLoop 实现。
- [x] Swift 行为测试 15/15 通过。
- [x] Rodski App 6/6、Dashboard 兼容层 20/20 通过。
- [x] 既有 Dashboard、共享配置和隔离端口安全不变量通过。
- [ ] 独立 XCUITest 在获批系统 Automation/辅助访问权限后补跑。
- [ ] 签名、公证、安装包和正式发布由人类负责人另行批准。
