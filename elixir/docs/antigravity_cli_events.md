# Antigravity CLI 事件说明

Symphony 的 `antigravity_cli` provider 会以 print mode 运行 `agy`，并把 Antigravity CLI 的日志活动转换成类似 Codex worker update 的事件。这些事件用于刷新 orchestrator 的活动时间，也用于让 dashboard 更结构化地展示 Antigravity CLI 的进展和异常。

## 事件链路

1. `agy` 将运行日志写入 `--log-file` 指定的文件。
2. `SymphonyElixir.AgentProvider.AntigravityCli` 在 print turn 运行期间轮询该日志文件。
3. 每次发现新的有界日志样本，就发出 `antigravity_cli/event/log` 事件。
4. `SymphonyElixir.AgentRunner` 将事件转发给 orchestrator。普通日志事件按每个 turn 最多每秒一次节流；`fatal=true` 的异常事件不节流，会立即转发。
5. `SymphonyElixir.Orchestrator` 收到事件后更新 `last_codex_timestamp`、`last_codex_event` 和 `last_codex_message`。
6. terminal dashboard 和 Web dashboard 根据最新事件摘要展示 agent 活动。

## 日志事件结构

Antigravity CLI 日志活动继续使用已有 method 名称：

```json
{
  "method": "antigravity_cli/event/log",
  "params": {
    "text": "I0601 printmode.go:71] Print mode: starting\n",
    "text_bytes": 44,
    "text_truncated": false,
    "bytes_read": 44,
    "bytes_available": 44,
    "offset_start": 0,
    "offset_end": 44,
    "status": "running",
    "category": "activity",
    "fatal": false,
    "summary": "I0601 printmode.go:71] Print mode: starting",
    "log_file": "/path/to/.symphony/antigravity-cli-agy-turn-1.log",
    "turn_id": "agy-turn-1",
    "conversation_id": "antigravity-cli"
  }
}
```

字段说明：

- `offset_start` / `offset_end`：本次 probe 观察到的日志文件范围。
- `bytes_available`：该范围内新增的总字节数。
- `bytes_read`：本次事件实际携带的有界样本字节数。
- `text_bytes`：本次新增日志范围的字节数，用于保留完整体量信息。
- `text_truncated`：事件中的 `text` 是否经过截断。
- `summary`：用于 dashboard 展示的一行摘要。
- `fatal`：是否匹配到需要提前失败的异常模式。

## 状态和分类

`status` 可能是：

- `running`：CLI 仍在产生非 fatal 活动。
- `failed`：日志样本匹配到 fatal 模式。
- `completed`：print turn 正常退出后捕获了 stdout。

`category` 可能是：

- `activity`：普通进展。
- `conversation`：观察到 conversation 创建或复用。
- `warning`：Antigravity 日志中出现 warning 严重级别。
- `error`：Antigravity 日志中出现 error 严重级别，但未被分类为 fatal。
- `auth_required`：Antigravity 未登录，或无法获取 OAuth token。
- `print_timeout`：Antigravity print mode 自身报告 timeout。
- `process_crash`：匹配到 panic、fatal error 或 uncaught exception。
- `stdout`：print turn 完成后的 stdout 捕获。

fatal 分类会让 provider 返回结构化错误，例如：

```elixir
{:error, {:antigravity_cli_fatal, :auth_required, "E0604 ... You are not logged into Antigravity."}}
```

这类错误会提前结束当前 turn，不再等待 Antigravity CLI 的 `print_timeout`。

## Dashboard 会展示什么

dashboard 展示时优先使用 `summary`，然后才回退到 `text` 或 `text_preview`。

常见展示示例：

```text
antigravity cli running/activity: Print mode: starting
antigravity cli running/conversation: Created conversation agy-thread-1
antigravity cli failed/auth_required: You are not logged into Antigravity.
antigravity cli failed/print_timeout: Print mode: timed out after 1494 polls
```

orchestrator 每次收到转发事件都会更新 `last_codex_timestamp`。Web dashboard 会在最新活动旁展示这个时间，中文界面使用北京时间格式，例如：

```text
session_started · 北京时间 2026-06-04 20:36:42
```

JSON API 中的 `last_codex_timestamp` 仍保留 UTC ISO8601 原始值，例如 `2026-06-04T12:36:42Z`，便于机器消费和跨时区排查。

## 内存边界

provider 的设计目标是不在长生命周期状态中保留完整 Antigravity 日志：

- stdout tail 上限为 64 KiB。
- 单个日志事件样本上限为 16 KiB。
- 当新增日志很大时，会采样新增范围的头部和尾部，既保留 conversation id 的机会，也能捕捉尾部 fatal 错误。
- `CodexUpdateCompactor` 会在事件进入 orchestrator 长生命周期状态前移除完整 `text`，只保留字节数和 240 字符 preview。
- orchestrator 状态只保存最后一次 compact 后的事件摘要。

因此内存使用受每个事件的固定上限约束，不会随日志文件总大小线性增长。

## 运行和验证

构建当前 escript：

```bash
cd /Users/ming/Code/symphony/elixir
mise exec -- make build
```

运行相关测试：

```bash
cd /Users/ming/Code/symphony/elixir
mise exec -- mix test test/symphony_elixir/agent_provider_test.exs test/symphony_elixir/codex_update_compactor_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

使用 Antigravity CLI workflow 启动 Symphony：

```bash
cd /Users/ming/Code/symphony/elixir
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4011 \
  ./WORKFLOW.en.powerchat-agy.md
```

运行期间可通过 JSON API 检查某个 issue 的最新事件：

```bash
curl -fsS http://127.0.0.1:4011/api/v1/FIR-32 | python3 -m json.tool
```

重点查看：

- `last_codex_event`
- `last_codex_timestamp`
- `last_codex_message.message.method == "antigravity_cli/event/log"`
- `params.status`
- `params.category`
- `params.summary`
- `params.fatal`
