# 迭代 05 决策记录

| 日期 | 决策 | 原因 | 影响 |
| --- | --- | --- | --- |
| 2026-07-15 | iteration-05 旧 WebUI+iOS 设计 `pivot` | “WebUI”被错误理解为开源 Dashboard | 旧 WebUI 截图不再是目标证据 |
| 2026-07-15 | macOS 采用 SwiftUI 原生工作台 | 用户要求 PC App 自有 UI | 现有 WKWebView 宿主必须替换 |
| 2026-07-15 | macOS 本地使用 `hermes serve` | 原生 App 只需要 headless backend | 开源 WebUI 和 Dashboard 不动 |
| 2026-07-15 | iOS 保留协议资产、重做工作台 | 连接层可复用，现有首屏不符合目标 | 抽取共享 Swift 核心 |
| 2026-07-15 | 最终 pass 需要截图和录像 | 用户明确指定视觉结果为准 | TestLoop 缺任一双端录像不得 pass |

