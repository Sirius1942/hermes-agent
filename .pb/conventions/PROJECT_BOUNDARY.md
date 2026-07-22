# Hermes Agent 项目边界

## 产品边界

Hermes 是一个通过多种表面交付的 Agent 核心：经典 CLI、消息网关、Ink TUI、Dashboard、
ACP 和 Electron Desktop。共享 Agent 行为属于核心或既有共享模块；表面专属交互属于
对应适配器或应用。

## 不可违反的不变量

- 除上下文压缩外，对话缓存的提示词前缀必须保持字节稳定。
- 消息历史必须保持合法角色交替，不能在 Agent 回合中插入合成 user 消息。
- 保持模型工具 Schema 窄小；新增能力优先使用已有代码、CLI+skill、服务门控工具、
  插件或 MCP，最后才考虑新的核心工具。
- 用户行为配置属于 `config.yaml`；`.env` 只保存凭据和秘密。
- 持久化 Hermes 路径必须使用 `get_hermes_home()`；用户可见路径必须使用
  `display_hermes_home()`。
- 插件必须停留在插件表面；第三方产品集成不能耦合进核心仓库。
- 测试断言行为和不变量，不能冻结预期会变化的目录快照、模型数量或版本字面量。
- 仓库测试必须通过 `scripts/run_tests.sh`，禁止直接调用 `pytest`。

## 表面所有权

| 关注点 | 负责人 |
| --- | --- |
| Agent Loop、工具调用、缓存、压缩 | `run_agent.py`、`agent/`、`model_tools.py` |
| 工具发现与暴露 | `tools/registry.py`、`tools/`、`toolsets.py` |
| 经典 CLI | `cli.py`、`hermes_cli/` |
| 消息平台 | `gateway/`、`gateway/platforms/` |
| Ink TUI | `ui-tui/`、`tui_gateway/` |
| Dashboard 支持 UI 与嵌入 TUI | `web/`、`hermes_cli/pty_bridge.py` |
| Electron Desktop 聊天 | `apps/desktop/`、`apps/shared/` |
| 定时任务 | `cron/` |
| 扩展 | `plugins/`、`skills/`、`optional-skills/`、MCP catalog |

Dashboard 不得重做主 transcript 或 composer。Desktop 是独立聊天表面，可以拥有自己的渲染流程。

## 变更门禁

实现前，任务必须说明：

- 观察到的问题或请求的结果；
- 所属表面和受影响同类路径；
- 行为契约和明确非目标；
- 提示词缓存与消息交替影响；
- 配置与 Profile 影响；
- 验证命令和所需端到端证据。

没有具体消费者，不得增加投机性的 hook、callback、manager 或扩展点。
