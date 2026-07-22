# Hermes Admin for macOS（旧 WebUI Demo）

> **当前状态：独立 Hermes Admin 产品。** 本目录只包含 SwiftUI + WKWebView Dashboard 宿主。
> 原生 Chat runtime 已迁入 `apps/macos-chat`，Admin 不再编译或依赖共享 Chat Gateway。按
> iteration-06 Round 33 决策，旧 WebUI Demo 正式命名为 **Hermes Admin**；新的
> **Hermes Chat for macOS** 是独立 target。正式迁移计划见
> `.designloop/work/iteration-06/22-round-33-chat-admin-product-separation.md`。

目标目录边界：

```text
apps/macos-admin/   Hermes Admin：保留 WKWebView / Dashboard 宿主
apps/macos-chat/    Hermes Chat：全新 SwiftUI 三栏聊天工作台，零 WebView
```

`0.5-candidate.1` 已获得人工批准并通过 TestLoop Round 34 设计验收。本目录使用独立 bundle、
UserDefaults suite、URL scheme 和进程 ownership，不作为 Hermes Chat 的功能回退。

Hermes Admin 是一个 SwiftUI 宿主 App。它加载现有 Hermes Web Dashboard，因此首次版本
即可提供 Dashboard 的 Chat、Sessions、Files、Analytics、Models、Logs、Cron、Skills、
Plugins、MCP、Channels、Webhooks、Pairing、Profiles、Config、Keys、System、Docs 和动态
插件页面等完整功能。

App 不复制 Agent Runtime。它优先连接现有 Dashboard；本地地址不可达时，可以查找已安装
的 `hermes` 并运行：

```bash
hermes dashboard --skip-build --no-open --host 127.0.0.1 --port 9119
```

App 自动启动时会增加 `--skip-build`，直接使用 Hermes 随安装提供的 `web_dist`，避免在 GUI
启动路径中阻塞执行 npm 构建。源码开发者需要先按仓库 WebUI 流程生成该目录。

## 构建

```bash
cd apps/macos-admin
xcodegen generate
xcodebuild \
  -project HermesAdmin.xcodeproj \
  -scheme HermesAdmin \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 测试

```bash
xcodebuild \
  -project HermesAdmin.xcodeproj \
  -scheme HermesAdmin \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## 运行

先启动 Dashboard，或让 App 自动启动：

```bash
hermes dashboard --skip-build --no-open
open .build/DerivedData/Build/Products/Debug/Hermes\ Admin.app
```

设置窗口可以配置 Dashboard URL、`hermes` 可执行文件路径、自动启动和明快主题。明快主题
只作用于 App 内 WebView，不会修改 `~/.hermes/config.yaml` 的共享 Dashboard 主题。

本地已有 Dashboard 时，App 只附着现有实例，不会停止它。本地地址不可达而由 App 启动
Dashboard 时，App 只持有并清理自己创建的进程；退出 App 不会调用全局
`hermes dashboard --stop`。用户直接点击的外部链接由系统浏览器打开，OAuth 服务端重定向
则保留在同一 WebKit Cookie 存储中完成认证往返。

## 与 Hermes Chat 的硬边界

- Hermes Admin 不属于 Hermes Chat MVP，也不能提供 Chat 的页面回退。
- 两个 App 必须使用不同 target、bundle identifier、显示名、UserDefaults suite、Keychain service
  和进程 ownership 标识。
- Hermes Chat 不链接 WebKit、不包含本目录的 `DashboardWebView`、不启动或停止 Hermes Admin。
- 两个 App 可以同时运行；任一 App 退出不得清理另一 App 所有的进程。
