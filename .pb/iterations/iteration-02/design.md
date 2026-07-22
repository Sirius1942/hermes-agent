# 迭代 02 设计

## 已接受架构

采用 SwiftUI 宿主 + 受控 `WKWebView` 完整 Dashboard 兼容层：

- `apps/macos/` 拥有 App 生命周期、连接状态、设置、进程、主题和 WebKit 安全策略。
- `hermes dashboard --skip-build --no-open` 提供完整 SPA、REST、WS、PTY 和插件页面。
- Web Dashboard、Profile、Session、配置和认证仍是单一事实源。
- Agent Core、工具、Provider、Gateway 和数据库保持不变。

## 方案选择

| 方案 | 结论 | 原因 |
| --- | --- | --- |
| 全原生 SwiftUI 重写 | 不用于首版 | 周期长，PTY 和动态插件会失去完整对齐 |
| 无边界 WebView 包装 | 不采用 | 缺少进程所有权、安全、恢复和 App 体验 |
| SwiftUI + 受控 WKWebView | 已采用 | 首版即可完整对齐，并保留逐页原生化空间 |

## 技术边界

- App 先探测 URL；可达即附着，不创建进程。
- 只自动启动本机 HTTP Dashboard，并只终止 owned `Process`。
- 直接跨 Origin 外链外开，OAuth 服务端重定向留在 WebView；未知 scheme 拒绝。
- 下载清理路径穿越并避免覆盖；Web 内容进程首次终止自动重载。
- 明快主题只在 App WebView 注入，不调用共享主题 API。
- 单元测试宿主不启动真实服务；独立 XCUITest 用显式环境标志执行真实连接。

## 视觉设计

SwiftUI 壳层使用温暖浅色渐变、Material、状态徽章和原生 Toolbar。Dashboard 注入主题使用
暖白画布、明亮蓝、珊瑚、薄荷、黄色、紫色和危险红；用户可以关闭注入并恢复自身主题。

## 风险与验证

| 风险 | 缓解 | 证据 |
| --- | --- | --- |
| 误用无 SPA 的 `serve` | 固定完整 dashboard 命令 | 启动参数单测、真实启动 |
| 误停用户 Dashboard | owned Process 模型 | PID/PPID/端口 Rodski |
| 主题污染共享配置 | App 专属脚本 | 配置哈希和亮度对比 |
| OAuth/外链策略冲突 | 区分直接点击与服务端重定向 | 行为单测 |
| 页面或插件不完整 | 同一完整 SPA | Dashboard 20/20 |
| UI 自动化权限缺失 | 独立 XCUITest scheme | 环境门禁记录，授权后补跑 |

## 后续原生化原则

任何逐页原生化都是后续独立迭代；在原生页通过功能对齐、失败恢复和 TestLoop 验收前，
WKWebView 兼容层持续作为可用回退，不能先删除完整功能。
