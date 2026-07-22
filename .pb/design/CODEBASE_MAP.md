# Hermes Agent 代码地图

## 系统形状

Hermes 是一个 Python Agent Runtime，外围连接多个交付表面和扩展系统。稳定中心是
对话循环与工具编排；产品广度应主要位于适配器、插件、skill 和客户端。

```text
CLI / Gateway / TUI Gateway / ACP / Batch
                    |
                    v
             AIAgent（run_agent.py）
                    |
          model_tools.py + toolsets.py
                    |
        tools/registry.py -> tools/*.py

Desktop / Web 支持 UI -> JSON-RPC / WebSocket -> tui_gateway 或 serve
Plugins / Skills / MCP   -> 围绕窄核心的扩展表面
```

## 关键路径

| 路径 | 责任 | 主要风险 |
| --- | --- | --- |
| `run_agent.py` | 对话生命周期、Provider 调用、工具循环 | 提示词缓存和角色历史回归 |
| `model_tools.py` | 工具发现、Schema 解析、分发 | 永久 Schema 成本和插件时序 |
| `toolsets.py` | 各表面的工具暴露 | 工具可用性意外变化 |
| `agent/` | Provider、memory、compression、routing、transport | 跨 Provider 契约漂移 |
| `cli.py`、`hermes_cli/` | 交互式 CLI、命令和配置 UX | 重复配置与命令路由 |
| `gateway/` | 会话和消息适配器 | 并发、控制命令和交付问题 |
| `ui-tui/`、`tui_gateway/` | Ink UI 与 JSON-RPC 后端 | 客户端/后端协议漂移 |
| `apps/desktop/`、`apps/shared/` | Electron 渲染器与共享传输 | Desktop 专属状态和兼容 |
| `web/` | Dashboard 支持界面 | 意外重做第二套聊天体验 |
| `plugins/`、`skills/` | 可扩展能力 | 反向耦合回核心 |
| `tests/` | 契约与端到端证据 | 只有 mock 或快照的虚假信心 |

## 常见变更路径

### 新 slash command

从 `hermes_cli/commands.py` 开始，只在所属表面添加必要 handler。注册表消费者会自动
生成帮助、alias、补全、Telegram 和 Slack 元数据。

### 新能力

遵循 Footprint Ladder：扩展现有代码、CLI+skill、服务门控工具、插件、MCP，最后才是核心工具。

### 配置

把行为写入 `config.yaml` 默认值，并追踪所有配置加载器。`.env` 只保存凭据。使用隔离的
`HERMES_HOME` 测试。

### UI 工作

遵循所属表面。共享 TypeScript 传输位于 `apps/shared`；共享状态使用按功能所有的小型
nanostore。保持路由根和 hook 窄小。

## 验证策略

- 局部行为使用聚焦单元测试。
- 共享注册表和映射使用不变量测试。
- 配置和解析链使用真实导入测试。
- 远程后端、安全边界、持久化、WebSocket/JSON-RPC 和文件/网络 I/O 使用端到端测试。
- Python 测试唯一入口是 `scripts/run_tests.sh`。
