# 迭代 05：macOS/iOS 双原生 Chat 工作台

**状态：** DesignLoop 产物完成，等待独立 TestLoop 设计验收
**需求：** `../../requirements/APPLE_NATIVE_CHAT_APPS.md`
**设计运行：** `.designloop/runs/iteration-06/progress.json`

## 目标

把错误的 macOS WKWebView Dashboard 宿主方向 pivot 为 macOS SwiftUI 原生工作台，并继续
完善 iOS SwiftUI 原生 Chat。Hermes 开源 WebUI、Dashboard、TUI 和 Electron Desktop 不改。

## 当前门禁

- 交互设计校验：15 个低保真场景、15 个矩阵场景，通过。
- 设计质量校验：15 个轨迹、P0/P1 未决假设 0，通过。
- 独立 TestLoop 设计验收尚未执行；不得进入 DevLoop 产品重写。

## 可复用资产

- iOS Foundation `/api/ws` Gateway、JSON、URL、Keychain 和 reducer。
- prompt response 协议形状测试。
- lazy Agent 初始化期间立即 Stop 的 gateway 修复和测试。

## 必须替换

- `apps/macos` 的 Dashboard 配置、探针、进程控制、WKWebView 和 WebView 主题逻辑。
- iOS 以连接 Form 为首屏的结构。

