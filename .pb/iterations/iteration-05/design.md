# 迭代 05 设计摘要

```text
macOS SwiftUI App ─┐
                  ├─ HermesClientCore ─ HTTPS/WSS ─ hermes serve
iOS SwiftUI App ──┘                        │
                                          SessionDB / Agent / Tools
```

- macOS：三栏工作台，本地 owned serve 或远程连接。
- iOS：Chat 首屏、Session sheet、上下文/工具 sheet、远程连接。
- 共享：JSON-RPC、事件、Session 模型、reducer、安全存储接口。
- 不共享：平台导航、窗口、AppStore、生命周期和视觉组件。
- 不使用：WKWebView、Dashboard SPA、PTY/TUI 或 Electron 运行依赖。

完整设计见 `.designloop/work/iteration-06/`。

