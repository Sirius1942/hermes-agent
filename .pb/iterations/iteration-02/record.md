# 迭代 02 记录

## 决策

| 日期 | 决策 | 理由 | 后果 |
| --- | --- | --- | --- |
| 2026-07-13 | 目标平台为 macOS 14+ | 用户请求 Swift App，当前本机开发环境完整 | iOS/iPadOS 保留为后续非目标 |
| 2026-07-13 | 接受 SwiftUI + WKWebView 完整兼容层 | 同一 SPA 可在首版提供全部 WebUI、PTY 和动态插件 | 不逐页复制 React，不制造第二事实源 |
| 2026-07-13 | 本地使用 `hermes dashboard --skip-build --no-open` | `serve` 无 SPA；GUI 启动不能阻塞 npm build | App 可附着或快速启动完整 WebUI |
| 2026-07-13 | 明快主题只在 App 注入 | 满足视觉要求且不改变用户共享 Dashboard | 主题可关闭，共享配置保持不变 |
| 2026-07-14 | 进程所有权只覆盖 owned 子进程 | 用户已有 Dashboard 是外部状态 | 不调用全局 stop，退出只清理自己创建的实例 |
| 2026-07-14 | Rodski 为 TestLoop 实现验收必选 | 需要真实 App、进程、主题、页面和 PTY 证据 | 用例、截图、录像、结果与追溯矩阵均持久化 |

## 验证证据

| 日期 | 命令/检查 | 结果 | 证据或说明 |
| --- | --- | --- | --- |
| 2026-07-13 | TestLoop 设计验收 | pass | 总体 4.4/5，关键维度 >=4，阻塞项 0 |
| 2026-07-14 | Swift `HermesMac` scheme | pass | 15/15，0 failure |
| 2026-07-14 | Rodski App 全量 | pass | 6/6，含 attach、owned、主题、离线和缺失恢复 |
| 2026-07-14 | Rodski Dashboard 全量 | pass | 20/20，含 Chat PTY 和动态插件 |
| 2026-07-14 | 进程与端口 | pass | 9119 PID 前后不变，19119/19120 无残留 |
| 2026-07-14 | 共享配置哈希 | pass | 明快主题测试前后 SHA-256 不变 |
| 2026-07-14 | XCUITest | 环境门禁 | Automation Mode/辅助访问未授权；测试资产保留 |

## 实现中发现并修复

- GUI 启动路径会触发 npm build：加入 `--skip-build`。
- 单元测试宿主可能启动真实 Dashboard：通过测试环境隔离。
- owned Dashboard 异常退出后状态可能残留：termination handler 清理所有权状态。
- 下载建议文件名可能包含路径：取最后路径分量并避免覆盖。
- Rodski 首轮 OCR 和 PID 等待不稳：按真实中英文 UI 和可观察状态修正，不改变产品预期。

## 当前剩余门禁

产品实现与 Rodski 验收已通过。系统级真实 XCUITest 点击等待 macOS Automation/辅助访问授权；
签名、公证、安装包、App Store 和远端发布仍需人类批准。
