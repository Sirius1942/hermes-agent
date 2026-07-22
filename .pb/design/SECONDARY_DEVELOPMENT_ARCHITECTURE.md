# Hermes Agent 二次开发架构说明

**状态：** 生效中的二次开发基线  
**适用对象：** 需要在 Hermes Agent 上增加业务能力、接入模型或平台、扩展界面，或维护内部部署版本的开发者  
**维护方式：** 代码边界以当前仓库为准，产品行为以本地测试和官网开发指南为准；实现发生变化时，应在对应迭代中更新本文档

## 1. 产品定位与阅读结论

Hermes Agent 是一个共享 Agent 核心、多入口交付、多种扩展方式的个人 AI Agent。官网和仓库文档将它描述为可以在经典 CLI、消息网关、TUI、Dashboard、Electron Desktop、ACP、批处理和 Python 进程内调用之间复用同一套 Agent 能力的运行时。

面向二次开发最重要的结论不是“把所有逻辑放进 `run_agent.py`”，而是：

1. **核心是窄腰。** `AIAgent`、提示词构造、Provider 解析、工具注册和会话持久化构成稳定中心；新增能力优先放在既有扩展边界。
2. **表面负责交付。** CLI、Gateway、TUI、Dashboard、Desktop 和 ACP 共享 Agent 行为，但各自拥有输入、授权、渲染和传输责任。
3. **扩展优先于分叉。** Skill、Plugin、MCP、Provider Plugin、Platform Adapter、Memory Provider 和 Context Engine 已经是正式扩展路径。
4. **缓存和消息历史是架构约束。** 长会话的系统提示词前缀应保持稳定；消息角色必须保持合法交替。一次看似局部的 Prompt 或工具改动，可能影响所有入口和每轮 API 成本。
5. **二开应按可观察结果设计。** 先明确用户流程、受影响表面、配置和失败行为，再决定是否需要核心代码。

官网入口：<https://hermes-agent.nousresearch.com>。本说明以仓库内 `website/docs/developer-guide/` 的架构、Agent Loop、Prompt、Provider、Tools、Plugins、Gateway、ACP、Session Storage 和 Programmatic Integration 文档为主要依据。

## 2. 分层架构

```text
┌─────────────────────────────────────────────────────────────────────────┐
│  交付表面                                                               │
│  Classic CLI │ Gateway/平台 │ Ink TUI │ Dashboard │ Desktop │ ACP │ API │
└──────────────┬──────────────┬─────────────┬──────────────┬──────────────┘
               │              │             │              │
               └──────────────┴──────┬──────┴──────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Agent 运行时（窄核心）                                                  │
│  AIAgent.run_conversation() / chat()                                    │
│  Prompt Builder → Provider Runtime → API Transport → Tool Loop           │
│  Compression / Caching / Interrupt / Budget / Fallback / Callbacks       │
└──────────────┬───────────────────┬──────────────────┬───────────────────┘
               │                   │                  │
               ▼                   ▼                  ▼
       Prompt 与上下文       Provider 与传输      Tool Registry 与 Toolset
       `agent/`              `hermes_cli/`        `model_tools.py` / `tools/`
               │                   │                  │
               └───────────────────┴──────────────────┘
                                   ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  状态与外部后端                                                          │
│  SessionDB/SQLite/FTS5 │ Memory │ Context Engine │ Terminal/Browser/MCP │
│  Profile/HERMES_HOME   │ Cron   │ 文件、网络、远程执行和平台服务         │
└─────────────────────────────────────────────────────────────────────────┘

扩展层：skills / plugins / provider plugins / platform adapters / MCP
```

### 2.1 核心模块所有权

| 关注点 | 主要位置 | 二开边界 |
| --- | --- | --- |
| Agent 生命周期、工具循环、重试、预算、回退 | `run_agent.py` | 只有跨所有表面的共享行为才进入这里；先证明不能由扩展层解决 |
| Prompt 组装、技能、上下文文件、缓存标记 | `agent/prompt_builder.py`、`agent/` | 不在会话中途重建稳定系统提示词；新增动态信息要区分稳定、上下文和易变层 |
| Provider 解析、凭据和 API mode | `hermes_cli/auth.py`、`hermes_cli/runtime_provider.py`、`providers/` | OpenAI 兼容服务优先使用 Provider Plugin；原生协议才增加 adapter/API mode |
| 工具 Schema、发现和分发 | `model_tools.py`、`tools/registry.py`、`toolsets.py` | 新工具会进入每次模型调用的 Schema；优先 Skill、Plugin、MCP 或 `check_fn` 门控 |
| CLI、配置和 slash command | `cli.py`、`hermes_cli/` | slash command 先加入 `COMMAND_REGISTRY`；行为配置写 `config.yaml` |
| 消息网关和平台适配 | `gateway/`、`gateway/platforms/` | 平台特有连接、授权和发送逻辑留在 adapter；统一会话语义交给 Gateway |
| TUI 与 JSON-RPC | `ui-tui/`、`tui_gateway/` | TUI 是 Dashboard 主聊天体验的来源，不在 Dashboard 另做一套 transcript/composer |
| Dashboard 支持界面 | `web/`、`hermes_cli/pty_bridge.py` | 可增加侧栏、检查器和摘要；主聊天仍嵌入真实 TUI |
| Desktop 聊天 | `apps/desktop/`、`apps/shared/` | Desktop 是独立聊天表面；共享传输和状态使用 `apps/shared` 的既有协议 |
| 会话、Profile 和日志 | `hermes_state.py`、`gateway/session.py`、`hermes_constants.py`、`hermes_logging.py` | 所有持久路径使用 `get_hermes_home()`，测试使用临时 `HERMES_HOME` |
| 定时任务、批处理、ACP、API Server | `cron/`、`batch_runner.py`、`acp_adapter/`、API Server 入口 | 复用 Provider、工具和会话契约，不复制 Agent Loop |

## 3. 一次请求的真实执行链

```text
用户输入/平台事件/API 请求
  → 表面级授权、会话键和配置解析
  → 构造或恢复 AIAgent
  → Prompt Builder 组装稳定层、上下文层、易变层
  → Runtime Provider 解析 provider / model / api_mode / credentials
  → 将内部 OpenAI 风格消息转换为目标 API 格式
  → 发起可中断的模型调用
  → 若返回 tool_calls：model_tools → registry → handler → tool result
  → 保持角色合法后继续循环，直到文本响应、预算耗尽或中断
  → 记忆同步、会话持久化、轨迹/日志和表面交付
```

内部消息格式是跨 Provider 的共同契约，典型形态为：

```python
{"role": "system", "content": "..."}
{"role": "user", "content": "..."}
{"role": "assistant", "content": "...", "tool_calls": [...]}
{"role": "tool", "tool_call_id": "...", "content": "..."}
```

Provider 可以使用 `chat_completions`、`codex_responses` 或 `anthropic_messages` 等模式，但进入和离开 Agent Loop 时应回到统一的内部消息语义。二次开发不能假定只有一种请求格式，也不能只修复 CLI 路径而遗漏 Gateway、Cron、ACP、批处理和辅助模型调用者。

## 4. Prompt、缓存与上下文

系统提示词可以按以下思路理解：

```text
稳定层：身份、工具说明、固定规则、稳定 Skill 内容
上下文层：上下文文件、项目资料、长期约束
易变层：Profile、记忆、时间、预算提示和会话状态
```

二开规则：

- 不能在普通回合中修改过去消息或替换工具集来“即时刷新”系统提示词。
- 需要主动改变模型、工具或 Prompt 时，应走明确的用户动作和会话边界，例如新会话或已有的模型切换流程。
- 上下文过长时只能通过既有压缩契约或 Context Engine 处理；压缩后的列表仍必须是合法的 OpenAI 风格消息序列。
- 新增 Memory Provider、Context Engine 或 Skill 时，说明它何时加载、向模型注入什么、是否有网络 I/O，以及会不会把工作区内容发送到云端。
- 任何声称“缓存安全”的改动都必须做字节稳定性和同类路径验证，而不是只看一次模型调用成功。

## 5. 交付表面与选型

| 需求 | 首选表面 | 说明 |
| --- | --- | --- |
| 终端交互和开发者工作流 | Classic CLI 或 Ink TUI | 复用 Agent Loop；slash command 使用集中注册表 |
| Telegram、Discord、Slack 等消息服务 | Gateway + Platform Plugin/Adapter | 平台接入、授权、消息分片和发送留在 adapter |
| IDE 原生 Agent | ACP | 面向 VS Code、Zed、JetBrains 的 stdio/JSON-RPC 协议 |
| 自定义完整聊天客户端 | TUI Gateway JSON-RPC 或 Desktop | TUI 与 `tui_gateway` 负责完整交互；Desktop 有独立聊天实现 |
| 浏览器访问已有 TUI | Dashboard | 通过 PTY 嵌入 `hermes --tui`；可以增加支持性面板 |
| OpenAI 客户端兼容接入 | API Server | 不要为此复制一份 Agent Loop |
| Python 进程内调用 | `AIAgent.chat()` 或 `run_conversation()` | 需要自己管理运行边界、错误和会话策略 |
| 定时自动化 | Cron + Skill/脚本 | Cron 是 Agent 任务，不是把任意 shell 任务硬塞进核心 |

## 6. 扩展方式决策树

```text
能力是否能由现有 terminal/file/web 工具 + 说明完成？
  ├─ 是 → Skill（必要时配 CLI 命令）
  └─ 否
      ├─ 只属于某个部署或第三方？
      │   ├─ 是 → Plugin / MCP
      │   └─ 否
      ├─ 只在有凭据或服务时出现？
      │   ├─ 是 → 服务门控工具（check_fn）或 Provider/Platform Plugin
      │   └─ 否
      ├─ 是全局基础能力且必须结构化调用？
      │   ├─ 是 → 评估新增核心工具
      │   └─ 否 → 回到既有模块，避免新核心表面
```

### 6.1 常见二开类型

**业务流程或团队知识。** 先做 `skills/<category>/<name>/SKILL.md`，需要安装、配置或状态管理时增加 CLI 命令。Skill 可以声明平台、工具集、非秘密 `config.yaml` 设置和秘密环境变量，但不把 API Key 写进 Prompt。

**OpenAI 兼容模型服务。** 优先做 `plugins/model-providers/<name>/` 或用户目录下的 Provider Plugin。只有需要 OAuth、特殊模型目录、原生协议或首要 UX 时，才改 `auth.py`、`runtime_provider.py`、模型菜单和 `run_agent.py`。

**结构化外部能力。** 先判断是否由 Skill 通过现有工具调用即可；若必须有精确 Schema、二进制处理、流式或专用认证，优先 Plugin 或 MCP。只有几乎所有用户都需要且无法通过终端、文件或 MCP 完成时，才考虑 `tools/` 中的核心工具。

**消息平台。** 社区或内部平台优先 Platform Plugin；需要纳入官方发行版、统一文档和长期维护时，才按 `BasePlatformAdapter` 的 `connect`、`disconnect`、`send` 和事件转发契约进入核心。

**长期记忆。** 实现 `MemoryProvider`，使用 `initialize(session_id, hermes_home=...)`、非阻塞 `sync_turn`、工具 Schema 和生命周期 Hook；所有存储必须按 Profile 隔离。

**上下文管理。** 实现 `ContextEngine` 并通过 `config.yaml` 显式选择；一次只能激活一个引擎。必须验证压缩、工具注入、会话重置和模型切换后的状态。

**界面。** 主聊天要先判断所属表面：Dashboard 不重做 TUI 的 transcript/composer；Desktop 可以独立演进；共享 JSON-RPC 或 WebSocket 协议必须先更新契约和真实消费者，再改 UI。

## 7. 推荐的二次开发目录与交付物

每个二开功能建议按以下顺序留下证据：

```text
.pb/requirements/                         用户结果、范围、非目标、验收标准
.pb/design/                               所有权、数据流、失败和兼容设计
.pb/iterations/iteration-XX/              本轮需求、任务、设计、记录和证据
plugins/<category>/<name>/                可插拔实现及 manifest/README
skills/<category>/<name>/                 工作流说明、脚本和验证步骤
tests/                                    行为契约、同类路径和真实环境测试
website/docs/                             面向用户/贡献者的使用与维护说明
```

实现前必须填写：

- 观察到的症状或用户结果，而不是只写“增加一个模块”；
- 所属表面、共享消费者和可能遗漏的同类路径；
- 配置键、秘密来源、Profile 路径和权限边界；
- Prompt 缓存、消息角色、Provider mode、工具 Schema 的影响；
- 正向、负向、中断、恢复和清理行为；
- 最小可交付切片、明确非目标、回滚和上游同步方案。

## 8. 配置、Profile 与安全

| 数据类型 | 存放位置 | 规则 |
| --- | --- | --- |
| API Key、Token、密码、OAuth 秘密 | `~/.hermes/.env` 或认证存储 | 只通过既有凭据解析，不能写入代码、Prompt、日志或普通配置 |
| 行为配置、路径、阈值、显示偏好、功能开关 | `~/.hermes/config.yaml` | 不为非秘密设置新增用户可见 `HERMES_*` 环境变量 |
| 会话、搜索索引、Profile 数据 | `get_hermes_home()` 下的 SQLite/文件 | 必须按 Profile 隔离，测试使用临时目录 |
| 用户可见路径 | `display_hermes_home()` | 不把机器真实路径泄露到 UI 或文档 |
| 远程执行环境变量 | Skill/工具声明的 passthrough | 明确哪些变量会进入 Docker、SSH、Modal 等后端 |

第三方 Memory、观察性或 SaaS 集成不能直接耦合进核心仓库。若一个能力服务于少数用户或外部产品，应做独立 Plugin Repo，并通过插件安装和配置进入 Hermes。

## 9. 测试与验收分层

二开不能只用 mock 证明“函数被调用”。建议按风险选择证据：

1. **静态契约：** JSON、Schema、命令注册表、TypeScript 类型、文档链接和 `git diff --check`。
2. **局部行为：** handler、解析器、adapter 和纯函数的聚焦单测。
3. **同类路径：** CLI、Gateway、Cron、ACP、API、辅助模型等共享调用者是否都能解析同一配置或 Provider。
4. **真实集成：** 使用临时 `HERMES_HOME`，真实导入插件、读取配置、创建 SQLite、执行 JSON-RPC/HTTP/PTY 或调用本地服务。
5. **负向和恢复：** 缺失凭据、不可用工具、网络失败、超时、中断、并发写入、Profile 切换和会话压缩。
6. **界面验证：** UI 改动要有真实操作、截图或录屏；不能用静态组件渲染代替完整流程。

Python 测试统一通过 `scripts/run_tests.sh`；测试应断言行为关系和不变量，不冻结会持续变化的模型目录、平台数量或版本字面量。

## 10. 上游同步与版本策略

Hermes 上游变化频繁，二开分支应减少与核心大文件的冲突面：

- 业务能力尽量留在独立 Plugin、Skill 或 `apps/`/`website/` 目录；
- 必须修改核心时，先记录上游文件、符号、行为契约和兼容 shim 的移除条件；
- 以小的、可独立验证的迭代提交变更，避免把文档、迁移和多个产品表面混成无法回滚的一次提交；
- 升级前先跑 Provider、工具注册表、消息角色、缓存、会话和相关 UI 的同类路径测试；
- 不重写外部贡献者历史；可复用的工作优先通过 cherry-pick 保留作者信息。

## 11. 建议的第一阶段路线

在业务方向尚未确定时，不应先制造一个猜测性的核心功能。推荐先完成一个低 footprint 的垂直切片：

1. 选定一个明确场景和唯一主表面，例如“CLI + Skill”或“Gateway + Platform Plugin”。
2. 用 `.pb/requirements/` 写用户结果、范围、非目标和可观察验收标准。
3. 依照 Footprint Ladder 比较 Skill、Plugin、MCP、服务门控工具和核心改动。
4. 由规划与设计者在 DesignLoop 中形成设计契约，明确缓存、角色历史、配置、Profile、权限和失败行为。
5. 将设计交给 TestLoop 用全新上下文验收；设计 `pass` 后，开发者才能进入 DevLoop。
6. DevLoop 只实现一个可交付切片，再由 TestLoop 独立验收真实实现产物。
7. 通过后再扩展第二个表面；不要从第一天就同时改 CLI、Gateway、TUI、Desktop 和核心 Loop。

本仓库当前的设计讨论记录在 `.pb/iterations/iteration-01/二次开发设计讨论.md`。后续用户选定场景后，应把其中的候选方向收敛成新的需求文件和 DevLoop 迭代契约。

## 12. 二次开发三循环职责

| 循环 | 角色 | 主要输出 | 是否拥有最终验收权 |
| --- | --- | --- | --- |
| 规划与设计循环（DesignLoop） | 规划与设计者 | 问题规格、备选方案、设计契约、原型和验收交接 | 否；只能提交给 TestLoop |
| 开发循环（DevLoop） | 开发者 | 实现、开发者自查、实现说明和验收交接 | 否；自查不能替代 TestLoop |
| 验收循环（TestLoop） | 验收评估者 | 设计验收或实现验收报告、阻塞项、反馈和 `pass/fix/pivot/stop` 决策 | 是；但范围、预算、战略 pivot 和外部状态仍由人类负责人决定 |
| 人类负责人 | 人类决策者 | 范围、预算、不可逆变更、战略 pivot 和最终发布授权 | 保留最终治理责任 |

职责流转固定为：

```text
规划与设计者
  → TestLoop 设计验收
  → 开发者（DevLoop）
  → TestLoop 实现验收
  → 人类负责人发布/外部状态门禁
```

设计验收失败返回规划与设计循环；实现验收失败返回 DevLoop；连续三次同类关键失败、范围扩大、新依赖、迁移、新核心工具、缓存失效或安全边界变化，必须进入人类负责人门禁。

## 13. 参考资料

- 官网：<https://hermes-agent.nousresearch.com>
- 本地架构总览：`website/docs/developer-guide/architecture.md`
- Agent Loop：`website/docs/developer-guide/agent-loop.md`
- Prompt 与缓存：`website/docs/developer-guide/prompt-assembly.md`、`website/docs/developer-guide/context-compression-and-caching.md`
- Provider：`website/docs/developer-guide/provider-runtime.md`、`website/docs/developer-guide/adding-providers.md`、`website/docs/developer-guide/model-provider-plugin.md`
- Tools：`website/docs/developer-guide/tools-runtime.md`、`website/docs/developer-guide/adding-tools.md`
- 扩展：`website/docs/developer-guide/creating-skills.md`、`website/docs/developer-guide/plugins/index.md`
- 平台与协议：`website/docs/developer-guide/adding-platform-adapters.md`、`website/docs/developer-guide/gateway-internals.md`、`website/docs/developer-guide/acp-internals.md`
- 本地项目边界：`.pb/conventions/PROJECT_BOUNDARY.md`
- 本地代码地图：`.pb/design/CODEBASE_MAP.md`
