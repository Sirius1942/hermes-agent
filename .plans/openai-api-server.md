# Hermes Agent 的 OpenAI 兼容 API Server

> **文档状态：历史设计计划。** 本文用于保留早期设计背景，不覆盖当前源码、
> `AGENTS.md`、配置 Schema 或现有 API 契约。实现前必须先确认当前 `main` 是否已经
> 提供相关能力。行为设置属于 `config.yaml`，`.env` 只保存 API key 等秘密。

## 动机

Open WebUI、LobeChat、LibreChat、AnythingLLM、NextChat、ChatBox、Jan、HF Chat-UI、
big-AGI 等主流聊天前端都能通过 OpenAI 兼容 REST API 和 SSE 流连接后端。暴露该
接口后，Hermes Agent 可以直接作为这些前端的后端，不需要为每个前端编写适配器。

## 能力范围

```text
Open WebUI / LobeChat / LibreChat / 其他 OpenAI 客户端
                         |
                         | POST /v1/chat/completions
                         | Authorization: Bearer <key>
                         v
                 Hermes Agent Gateway/API Server
                         |
                         +-- 非流式 JSON
                         +-- SSE 流式响应
```

用户流程：

1. 在 `config.yaml` 中启用 API Server 并设置 host/port。
2. 密钥通过受保护配置或秘密环境变量提供。
3. 运行 `hermes gateway` 或当前版本提供的等价服务入口。
4. 将聊天前端指向 `http://localhost:8642/v1`。

## 端点

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/v1/chat/completions` | Chat Completions，支持流式和非流式 |
| POST | `/v1/responses` | Responses API 与服务端状态链 |
| GET | `/v1/models` | 返回可用模型 |
| GET | `/health` | 健康检查 |

## 架构方案

### 方案 A：Gateway 平台适配器（原计划推荐）

在 `gateway/platforms/api_server.py` 中实现 `BasePlatformAdapter` 适配器。

优点：

- 复用 Gateway 的会话、认证、上下文和中断基础设施；
- 与其他平台适配器运行在同一异步循环中；
- 复用消息处理和会话持久化；
- 使用已有依赖 `aiohttp.web`。

适配器在 `connect()` 中启动 `aiohttp.web.Application`，并把请求路由到标准消息处理管线。

### 方案 B：独立组件

在 `gateway/api_server.py` 中创建独立 HTTP Server，直接构造 `AIAgent`。

该方案表面简单，但会重复会话和认证逻辑，因此只有在当前 Gateway 架构不再适用时
才应重新评估。

## 请求与响应格式

### 非流式 Chat Completions

```http
POST /v1/chat/completions
Authorization: Bearer hermes-api-key-here
Content-Type: application/json
```

```json
{
  "model": "hermes-agent",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What files are in the current directory?"}
  ],
  "stream": false,
  "temperature": 0.7
}
```

响应示例：

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1710000000,
  "model": "hermes-agent",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "..."},
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 50,
    "completion_tokens": 200,
    "total_tokens": 250
  }
}
```

### 流式 Chat Completions

请求设置 `"stream": true`，响应使用 SSE：

```text
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

### 模型列表

```http
GET /v1/models
Authorization: Bearer hermes-api-key-here
```

```json
{
  "object": "list",
  "data": [{
    "id": "hermes-agent",
    "object": "model",
    "created": 1710000000,
    "owned_by": "hermes-agent"
  }]
}
```

## 关键设计决策

### 会话管理

OpenAI API 默认是无状态协议，每次请求携带完整对话；Hermes 会话则可能包含 memory、
skill 和工具上下文。

历史计划采用混合方式：

- 默认无状态：`messages` 数组就是完整对话；
- 通过 `X-Session-ID` 显式启用持久会话；
- 同一 session 正在运行时，新请求可以触发中断；
- Responses API 使用 `previous_response_id` 恢复服务端保存的完整内部上下文。

当前实现如果已经采用不同的 session contract，应以现行实现和测试为准。

### 流式响应

- 第一阶段可以返回单个 SSE 内容块加 `[DONE]`，只满足协议兼容，不是真实 token 流。
- 后续阶段通过线程安全队列接收 `AIAgent` 的文本增量，并实时写入 SSE。
- 工具调用进度是否透明必须显式启用，默认只返回最终助手文本。

### 工具透明度

- **不透明模式（默认）**：工具调用只在服务端运行，前端只看到最终结果。
- **透明模式（显式启用）**：以 OpenAI 格式输出 tool call/result，适用于 Agent 感知前端。

### 认证

- 使用 `Authorization: Bearer <key>`；
- 密钥属于秘密配置；
- 只绑定 `127.0.0.1` 时，可以设计显式的本地无认证模式；
- 非本地绑定必须强制认证并有真实安全边界测试。

### 模型映射

前端可以发送 `"model": "hermes-agent"`，实际模型由服务端配置决定。允许客户端覆盖
模型属于行为配置，必须通过 `config.yaml` 显式开启，并验证 Provider、权限和预算影响。

## 配置示例

```yaml
api_server:
  enabled: true
  port: 8642
  host: "127.0.0.1"
  allow_model_override: false
  max_concurrent: 5
```

密钥不得作为普通行为配置提交到仓库；通过当前版本支持的秘密配置机制提供。

## 历史实施阶段

### 第一阶段：非流式 MVP

1. 增加 API Server 适配器和端点。
2. 增加 Bearer token 认证中间件。
3. Chat Completions 使用请求 `messages` 作为对话。
4. Responses API 保存包含工具消息的内部会话链。
5. 增加真实导入、认证、会话和协议格式测试。

### 第二阶段：SSE Streaming

1. 为两个端点增加真实增量流。
2. 通过 callback queue 桥接 Agent 线程和异步 SSE writer。
3. 客户端断开时取消运行并清理资源。
4. 验证 Chat Completions 与 Responses 的不同事件格式。

### 第三阶段：增强能力

1. 工具调用透明模式。
2. 模型覆盖门禁。
3. 并发请求限制。
4. 使用量与速率限制。
5. 浏览器前端所需的受控 CORS。
6. `GET /v1/responses/{id}` 与 `DELETE /v1/responses/{id}`。

## 预期变更区域

| 文件 | 历史计划中的变化 |
| --- | --- |
| `gateway/platforms/api_server.py` | API Server 适配器 |
| `gateway/config.py` | 平台和配置定义 |
| `gateway/run.py` | 适配器注册 |
| `tests/gateway/test_api_server.py` | 协议、认证、会话和流式测试 |
| `cli-config.yaml.example` | `api_server` 配置示例 |
| 用户文档 | 平台入口和连接方式 |

## 兼容目标

设计目标是让 Hermes Agent 作为 OpenAI 兼容后端连接 Open WebUI、NextChat、LobeChat、
AnythingLLM、ChatBox、LibreChat、Jan、HF Chat-UI 和其他支持自定义 OpenAI endpoint 的
客户端。每个客户端的具体配置应由当前用户文档维护，不在历史计划中冻结。
