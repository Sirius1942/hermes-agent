# Hermes macOS WebUI 全功能对齐需求

> **状态：已废止。** 2026-07-15 用户澄清“WebUI”指 macOS App 自身 UI，不是 Hermes
> 开源 Dashboard。本文件仅保留历史追溯，不再授权 WKWebView、`hermes dashboard` 或 WebUI
> 宿主实现。当前权威需求为 `APPLE_NATIVE_CHAT_APPS.md`。

**需求 ID：** SWIFT-APP-001  
**状态：** 已废止，历史实现不得发布为当前目标  
**来源：** 用户请求  
**日期：** 2026-07-13  
**产品名：** Hermes macOS  

## 1. 用户结果

提供一个使用 Swift 和 SwiftUI 构建的 macOS App，使用户可以使用 Hermes Web Dashboard 的
全部管理与交互能力，并获得更明快、更现代的 App 视觉体验。

“全部功能”按行为对齐定义，不要求逐像素或逐页翻译 React。App 必须复用现有 Dashboard、
后端、Profile、Session、配置和安全边界，不复制 Agent Loop，也不能用不可点击的占位页
冒充完成。

## 2. 已接受架构

首版采用：

> SwiftUI 原生宿主 + 受控 WKWebView 加载现有完整 Hermes Dashboard SPA。

该架构已通过 TestLoop 设计验收并完成实现验收。SwiftUI 负责窗口、工具栏、连接状态、设置、
进程所有权、错误恢复和 App 专属明快主题；`WKWebView` 负责运行同一 Dashboard SPA，因此
内建页面、Chat PTY、REST、WebSocket、认证和动态插件页继续使用同一个事实源。

本地完整 SPA 命令为：

```bash
hermes dashboard --skip-build --no-open --host 127.0.0.1 --port 9119
```

`hermes serve` 是无 SPA 的 headless backend，不能作为 App WebUI 的本地加载目标。

## 3. 平台与运行约束

- 首个目标平台为 `macOS 14+`；实现使用 SwiftUI、AppKit 和 WebKit。
- App 不把 Python Agent Runtime 编译或嵌入 Swift 二进制。
- 默认连接 `http://127.0.0.1:9119/`；可连接现有本地或远程 HTTP/HTTPS Dashboard。
- 只有本机 HTTP Dashboard 不可达且用户开启自动启动时，App 才查找并启动 `hermes`。
- App 只持有和终止自己创建的 Dashboard 子进程，绝不执行全局 `hermes dashboard --stop`。
- 未原生化的页面不是待完成占位，而是由完整 Dashboard SPA 持续提供可操作兼容实现。

## 4. WebUI 功能基线

| 领域 | Web 路由/表面 | App 行为 |
| --- | --- | --- |
| Chat | `/chat` | 使用真实 Dashboard PTY/TUI，支持会话与终端交互 |
| Sessions | `/sessions` | 列表、搜索、详情、重命名、删除、导出和恢复 |
| Files | `/files` | 浏览、读取、上传、下载、创建目录和删除 |
| Analytics | `/analytics` | 使用量、模型、平台和 Skill 统计 |
| Models | `/models` | 主/辅助模型、MoA、Provider 目录和分析 |
| Logs | `/logs` | 日志源、级别、组件过滤和刷新 |
| Cron | `/cron` | 创建、编辑、暂停、恢复、触发、删除和蓝图 |
| Skills | `/skills` | 列表、启停、创建/编辑、搜索、安装和更新 |
| Plugins | `/plugins` | 安装、更新、删除、启停、Provider 和动态页面 |
| MCP | `/mcp` | Server、Catalog、安装、启停、测试和删除 |
| Channels | `/channels` | 平台配置、测试、Gateway 和 onboarding |
| Webhooks | `/webhooks` | 总开关、Route、启停、删除和 Gateway |
| Pairing | `/pairing` | 待审批用户、批准、撤销和清理 |
| Profiles | `/profiles` | 创建、克隆、切换、重命名、删除和 Soul 管理 |
| Config | `/config` | Schema 表单、嵌套配置和原始 YAML |
| Keys | `/env` | 秘密列表、设置、删除和受控显示 |
| System | `/system` | 状态、更新、诊断、备份、Hooks、Memory 等 |
| Docs | `/docs` | 内置文档与 Swagger/外部文档入口 |
| 动态插件 | 插件注入路由 | 使用同一插件导航和 Dashboard 运行时 |
| 全局壳层 | Sidebar/Header | Profile、认证、主题、语言、状态和插件导航 |

上述表面由 Rodski Dashboard 兼容层 20 项用例覆盖，包括 Chat PTY、Kanban 和
Achievements 动态插件页。

## 5. 安全、认证和持久化

- App 不读取、记录或持久化 Dashboard Session token、Cookie 内容、密码、API Key 或
  OAuth 凭据。
- 远程认证继续由现有 Dashboard 登录页和 WebKit 默认 Cookie 数据存储完成。
- 用户直接点击的跨 Origin HTTP(S) 外链交给系统浏览器；服务端 OAuth 重定向留在同一
  WebView 完成往返。
- 拒绝 `file:`、`javascript:` 和未知 scheme。
- 下载进入用户 Downloads，清理路径穿越文件名并避免覆盖同名文件。
- App 偏好只保存 Dashboard URL、Hermes 可执行路径、自动启动和明快主题布尔值。
- Rodski 数据中不得保存账号、密码、API Key、Token 或 OAuth 凭据。

## 6. 明快视觉

- App 壳层使用温暖浅色渐变、原生 Material、清晰状态徽章和 macOS Toolbar。
- Dashboard 明快主题由 App 专属 `WKUserScript` 注入，不调用 `/api/dashboard/theme`，也不
  修改 `~/.hermes/config.yaml`。
- 主题 token 使用暖白画布、白色表面、明亮蓝、珊瑚橙、薄荷绿、黄色、紫色和危险红。
- 用户可以关闭 App 明快主题，恢复 Dashboard 自身主题。
- 危险操作保持明确红色；文字、状态和控件不得因装饰色失去辨识度。

## 7. 验收标准

- [x] AC-G01：仓库存在可由 XcodeGen、Xcode 和命令行构建的 macOS SwiftUI App。
- [x] AC-G02：App 可附着既有 Dashboard，或在本机 HTTP 地址不可达时启动完整 Dashboard。
- [x] AC-G03：App 只清理 owned Dashboard，不改变用户已有实例。
- [x] AC-G04：全部 WebUI 领域使用同一真实 SPA，无静态占位或第二套事实源。
- [x] AC-G05：Chat PTY、REST/WS、Profile、Session、配置和插件保持现有 Dashboard 行为。
- [x] AC-G06：明快主题可启停，不修改共享配置，明快/原始主题均保持内容可见。
- [x] AC-G07：离线、Hermes 缺失、启动失败和 Web 内容进程终止具有可恢复行为。
- [x] AC-G08：外链、OAuth、非法 scheme 和下载边界有行为测试。
- [x] AC-G09：实现不修改 Agent Loop、提示词缓存、消息角色或核心工具 Schema。
- [x] AC-G10：Swift 行为测试与 Rodski App/Dashboard 全量验收通过并保留可追溯证据。

## 8. 当前验证结论

- Swift 行为测试：15/15，通过。
- Rodski Hermes macOS App：6/6，通过。
- Rodski Dashboard 兼容层：20/20，通过。
- 用户既有 9119 Dashboard PID 在 App 验收前后不变。
- 隔离端口 19119/19120 测试后无残留监听。
- 明快主题验收前后共享 `~/.hermes/config.yaml` 哈希不变。
- 独立 `HermesMacUI` XCUITest 已实现；当前机器缺少 XCTest Automation/辅助访问授权，需
  授权后补跑真实工具栏点击。该项记录为环境门禁，不得通过删除测试或降低预期规避。

## 9. 非目标与后续门禁

- 不重新实现 Agent Runtime、Provider、工具、Gateway、SessionDB 或 Dashboard SPA。
- 不在本迭代逐页原生化 React 页面；未来逐页原生化必须保持兼容层回退并单独验收。
- 不自动安装 Hermes，不管理远程服务器进程，不绕过现有认证。
- 不默认支持 iOS/iPadOS、Windows 或 Linux。
- 签名、公证、安装器、自动更新、Mac App Store、品牌图标和正式发布仍需人类负责人批准。
