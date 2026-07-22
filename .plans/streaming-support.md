# Hermes Agent 的 LLM 流式响应支持

> **文档状态：历史设计计划。** 本文保留早期流式响应方案，不覆盖当前源码、
> `AGENTS.md`、配置 Schema 或已经落地的 Streaming 实现。开始开发前必须验证当前
> `main` 的真实调用链。行为开关属于 `config.yaml`，不应作为新的非秘密 `.env` 设置。

## 概述

目标是在各平台提供逐 token/文本增量的 LLM 响应。启用后，用户能实时看到回复，
不必等待完整生成。流式能力应显式开启，关闭时保持现有非流式路径不变。

## 设计原则

1. **配置门控**：通过 `config.yaml` 的 `streaming.enabled` 及按平台覆盖项控制。
2. **Callback 驱动**：向 `AIAgent` 注入简单的 `stream_callback(text_delta)`，核心不关心消费者如何展示。
3. **优雅降级**：Provider 不支持流式或执行失败时，回退到非流式路径。
4. **平台无关核心**：AIAgent 的流式机制不依赖 CLI、Telegram、Discord 或 API Server。
5. **缓存与消息安全**：不得为了 Streaming 修改过去上下文、动态交换工具集或破坏角色交替。

## 架构

```text
                              stream_callback(delta)
                                       |
          LLM Stream ----------------->| 线程安全 queue
                                       |
                    +------------------+------------------+
                    |                  |                  |
                    v                  v                  v
              CLI 增量显示       Gateway 编辑消息      API Server SSE
```

Agent 在线程中运行，callback 将文本增量放入线程安全队列。每个消费者在自己的执行
上下文中读取：异步任务、主线程或 SSE writer。

## 配置

```yaml
streaming:
  enabled: false
  # 可选的按平台覆盖：
  # cli: true
  # telegram: true
  # discord: false
  # api_server: true
  edit_interval: 1.5
  min_tokens: 20
```

配置优先级建议：

1. API 请求显式的 `stream` 字段；
2. 按平台覆盖值；
3. `streaming.enabled`；
4. 默认关闭。

旧计划中的 `HERMES_STREAMING_ENABLED` 非秘密环境变量不再作为推荐用户配置；如仍有
兼容代码，应由 `config.yaml` 内部桥接，并在用户文档中只介绍配置文件方式。

## 第一阶段：AIAgent 核心流式基础设施

### 增加 callback

在 AIAgent 构造或当前合适的会话入口增加可选 callback：

```python
def __init__(self, ..., stream_callback: callable = None, ...):
    self.stream_callback = stream_callback
```

callback 为 `None` 时，行为必须与现有实现完全一致。

### Chat Completions 增量聚合

流式调用需要同时处理文本、usage 和分片 tool call：

```python
def _run_streaming_chat_completion(self, api_kwargs: dict):
    stream_kwargs = dict(api_kwargs)
    stream_kwargs["stream"] = True
    stream_kwargs["stream_options"] = {"include_usage": True}

    accumulated_content = []
    accumulated_tool_calls = {}
    final_usage = None

    try:
        stream = self.client.chat.completions.create(**stream_kwargs)
        for chunk in stream:
            if not chunk.choices:
                if chunk.usage:
                    final_usage = chunk.usage
                continue

            delta = chunk.choices[0].delta
            if delta.content:
                accumulated_content.append(delta.content)
                if self.stream_callback:
                    self.stream_callback(delta.content)

            if delta.tool_calls:
                # 按 index 合并 id、name 和 arguments 分片。
                ...

        # 构造与非流式后续路径兼容的响应对象。
        return build_compatible_response(
            content="".join(accumulated_content),
            tool_calls=accumulated_tool_calls,
            usage=final_usage,
        )
    except Exception:
        # Streaming 失败时回退到非流式调用。
        return self.client.chat.completions.create(**api_kwargs)
```

实现时不能吞掉 callback 自身以外的重要异常，也不能构造与现有 Provider 适配器不一致
的伪响应。优先复用当前仓库已经存在的响应规范化层。

### Responses API

Responses 流已经逐事件迭代时，只在文本 delta 事件上调用 callback：

```python
def _run_codex_stream(self, api_kwargs: dict):
    with self.client.responses.stream(**api_kwargs) as stream:
        for event in stream:
            if (
                self.stream_callback
                and getattr(event, "type", None) == "response.output_text.delta"
            ):
                self.stream_callback(event.delta)
        return stream.get_final_response()
```

### 中断调用分支

在当前 `_interruptible_api_call()` 或等价入口中，按 API mode 与 callback 决定走流式
还是非流式路径。必须保留现有中断、grace call、fallback 和 usage 统计语义。

### 结束信号

历史方案使用 `None` 表示流结束：

```python
if self.stream_callback:
    self.stream_callback(None)
```

正式实现应明确区分“正常完成”“中断”“Provider 失败”，必要时使用结构化事件，而不是
让一个 `None` 同时承担多种语义。

### 第一阶段测试

- callback 按顺序收到正确文本增量；
- callback 为 `None` 时完全走非流式路径；
- Provider 流式失败时按契约回退；
- tool call 参数分片能够正确聚合；
- usage-only 尾包被正确处理；
- 中断和结束信号不会产生重复响应；
- 使用当前仓库的真实响应规范化代码，而不是只测 `SimpleNamespace` mock。

## 第二阶段：Gateway 消费者

### 读取配置

Gateway 应从当前权威配置加载器读取 `streaming` 段，先检查按平台覆盖，再检查全局值。
不得新增面向用户的非秘密 `.env` 开关。

### Queue 与 callback

```python
_stream_q = queue.Queue()
_stream_done = threading.Event()

def _on_token(delta):
    if delta is None:
        _stream_done.set()
    else:
        _stream_q.put(delta)
```

该 callback 传给 AIAgent。消费者需要保证异常、中断和取消时最终能设置完成状态并清理任务。

### 消息预览任务

支持编辑消息的平台可以累积增量并周期性更新一条消息：

```python
async def stream_preview():
    accumulated = []
    token_count = 0
    last_edit = 0.0

    while not _stream_done.is_set():
        try:
            chunk = _stream_q.get(timeout=0.1)
        except queue.Empty:
            continue

        accumulated.append(chunk)
        token_count += 1
        now = time.monotonic()
        if token_count >= min_tokens and now - last_edit >= edit_interval:
            await send_or_edit("".join(accumulated) + " ▌")
            last_edit = now

    # 排空队列，并用最终处理后的文本完成最后一次编辑。
```

关键要求：

- 第一批内容足够稳定后才创建消息；
- 编辑频率必须符合平台限制；
- 中断时移除光标并保留已输出内容；
- 最终编辑使用后处理后的 `final_response`，不能直接使用原始 token 拼接；
- 没有文本增量的 tool-call 轮次不能发送空消息。

### 避免重复发送

最大风险是预览消息已经显示回复，而原有发送路径又发送一次最终结果。历史方案建议
在结果元数据中加入 `_streamed_msg_id`，由基础适配器跳过常规 `send()`。

正式实现必须验证这一标记不会泄漏到用户协议，也不会破坏不支持流式的平台。更优方案
是使用现有结构化交付状态，而不是临时 dict 字段。

### 平台差异

| 平台 | 编辑支持 | 建议方式 |
| --- | --- | --- |
| Telegram | 支持 | 受限频率编辑同一消息 |
| Discord | 支持 | 按每消息 rate limit 编辑 |
| Slack | 支持 | 使用 `chat.update` 并限频 |
| WhatsApp | 通常不支持 | 回退到非流式最终发送 |
| Home Assistant | 不适用消息编辑 | 回退到非流式路径 |
| API Server | 原生 SSE | 直接发送 SSE 事件 |

### 第二阶段测试

- 预览只创建一次，并按限频编辑；
- 已流式交付时不会重复发送最终消息；
- 不支持编辑的平台优雅回退；
- 按平台配置覆盖正确；
- thread/chat 元数据完整传递；
- 中断、取消和异常都能清理后台任务。

## 第三阶段：CLI 流式显示

### Callback 与显示线程

CLI 可以使用 queue 和完成事件收集增量，再以小批次刷新终端：

```python
def _cli_stream_callback(delta):
    if delta is None:
        _stream_done.set()
    else:
        _stream_q.put(delta)

def _stream_display():
    first_chunk = True
    while not _stream_done.is_set():
        batch = collect_small_batch(_stream_q, timeout=0.05)
        if not batch:
            continue
        if first_chunk:
            print_response_top_border()
            first_chunk = False
        render_batch(batch)
    drain_remaining_tokens()
    print_response_bottom_border()
```

### prompt_toolkit 集成风险

经典 CLI 使用 `prompt_toolkit` 控制终端。后台线程直接写 stdout 可能破坏输入区和
Spinner。实现应复用现有 `patch_stdout`/显示抽象，并以短时间批次刷新，不能逐 token
调用高成本 renderer。

### 第三阶段测试

- callback 安装和移除正确；
- 流式与非流式响应框边界一致；
- 输入区、Spinner 和工具进度不互相覆盖；
- 禁用 Streaming 时回到原路径；
- 中断后终端状态恢复正常。

## 第四阶段：API Server 真实 SSE

### Callback wiring

当请求包含 `stream=true` 时，API Server 创建队列并把 callback 传入 Agent 运行路径。
Agent 必须在后台 task/executor 中运行，SSE writer 与之并发消费队列；不能先等待完整
Agent 结果再开始“流式”输出。

### Chat Completions SSE

SSE writer 的职责：

1. 准备 `text/event-stream` 响应；
2. 发送 role chunk；
3. 把文本增量转换为 `choices[0].delta.content`；
4. 正常完成时发送 finish chunk 和 `[DONE]`；
5. 客户端断开时取消 Agent 并清理队列；
6. 失败时遵循 OpenAI 兼容错误契约。

### Responses API SSE

Responses API 使用不同事件：

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"Hello"}

event: response.completed
data: {"type":"response.completed","response":{...}}
```

两个端点应使用各自 writer 或共享的结构化事件层，不能混用 wire format。

### 第四阶段测试

- 使用受控 Agent 流验证真实 SSE 增量；
- 校验 Chat Completions 与 Responses 的事件格式；
- 客户端断开时 Agent 被中断且资源清理；
- callback 不可用时按明确契约回退；
- 并发请求、背压和慢客户端不会无限占用内存。

## 集成问题与边界场景

### 工具调用期间无文本

模型返回 tool call 时可能没有文本增量。预览任务不能因此发送空消息。工具执行完成后，
下一次模型调用产生文本时继续 Streaming。现有工具进度展示保持独立。

### 重复消息

流式预览和常规最终发送必须只有一个交付所有者。需要通过行为测试验证各种成功、失败、
中断和无 token 情况，不仅检查 happy path。

### 响应后处理

最终响应可能经过 think block 移除、尾部空白清理和媒体 tag 追加。流中显示的是原始增量，
最终一次编辑必须用后处理后的响应覆盖，避免用户最终看到不一致内容。

### 上下文压缩

压缩发生在 API 调用之间，不应修改已经发出的增量。实现不得为了 Streaming 在对话中途
重建系统提示词或交换工具集。

### 中断

用户在 Streaming 期间发送新消息时，应关闭当前 Provider 流、保留已输出内容、移除光标，
并按现有中断语义处理新消息。必须同时满足 Gateway 的两层控制消息 guard。

### 多模型与 fallback

主模型失败并切换 fallback 时，流状态需要明确重置。fallback 不支持 Streaming 时应回退，
但不能重复发送主模型已经交付的内容。

### 编辑速率限制

- Telegram：需要保守限制编辑频率；
- Discord：遵循每消息编辑限制；
- Slack：遵循 API 调用限制；
- 遇到 429 时跳过当前编辑周期并重试，不能让预览失败终止 Agent 主流程。

## 变更区域摘要

| 文件 | 阶段 | 历史计划中的变化 |
| --- | --- | --- |
| `run_agent.py` | 1 | callback、流式 Chat Completions、Responses 事件、可中断调用 |
| `gateway/run.py` | 2 | 配置、queue/callback、预览 task、最终交付状态 |
| `gateway/platforms/base.py` | 2 | 跳过重复最终发送 |
| `cli.py` | 3 | callback、批量 token 显示、响应框集成 |
| `gateway/platforms/api_server.py` | 4 | 真实 SSE writer 和并发 Agent task |
| `hermes_cli/config.py` | 1 | Streaming 配置默认值 |
| `cli-config.yaml.example` | 1 | Streaming 配置示例 |
| 所属测试文件 | 1-4 | 单元、不变量、集成和端到端测试 |

实际变更路径必须以当前代码所有权为准，不能照搬历史文件清单。

## 发布计划

1. **核心阶段**：默认关闭，验证 callback、Provider 和非流式兼容。
2. **Gateway 阶段**：先在一个支持编辑的平台进行真实验证，再逐平台开启。
3. **CLI 阶段**：验证多种终端、prompt_toolkit、Spinner 和中断。
4. **API Server 阶段**：使用真实 OpenAI 客户端验证 SSE、断开和错误格式。

每个阶段都应独立可合并、可测试、可回滚。是否修改默认值属于独立产品决策，不能因为
所有阶段技术稳定就自动开启。

## 最终配置参考

```yaml
streaming:
  enabled: false          # 总开关，默认关闭
  cli: true               # 按平台覆盖
  telegram: true
  discord: true
  slack: true
  api_server: true        # 客户端请求 stream=true 时使用
  edit_interval: 1.5      # 消息编辑间隔（秒）
  min_tokens: 20          # 首次显示前的最小增量数量
```

用户文档只应介绍当前 `config.yaml` 权威配置。任何遗留环境变量都属于内部兼容层，必须
有弃用路径，不能作为新用户的推荐设置。
