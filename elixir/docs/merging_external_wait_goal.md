# Merging external_waiting 交付说明

本文档是 FIR-16 / Codeup `Merging` 阶段修复的最终产出物。旧方案里“外部 CR
变化后唤醒一次 Codex 验证”的设计已经废弃；当前实现要求 `Merging` 阶段完全
不启动 Codex，由 Elixir 通过 Linear / Codeup API 完成监听和确定性收尾。

## 最终目标

当 Linear issue 进入 `Merging` 后，Symphony 必须满足以下不变量：

- issue 不会从 runtime state 或 dashboard 消失。
- Symphony 重启后，仍能从 Linear 当前 `Merging` 状态重新发现并纳管。
- 不启动 Codex agent，不进入 retry queue，不 wake verification run。
- 从 Workpad comment 或 issue description 读取 Delivery Metadata。
- 查询 Codeup CR 当前状态，并持续刷新 `last_checked_at`、CR status、observed key
  和错误信息。
- CR `MERGED` 后记录 evidence，并把 Linear issue 移到 `Done`。
- CR failed / closed / canceled 后记录 evidence，并把 Linear issue 移到 `Rework`
  或保持错误可见等待人工处理。
- metadata 缺失或 Codeup API 失败时不静默失败，必须在 dashboard/API 中显示。
- 新增 `external_waiting` 不能影响原有 running / retrying / blocked / manual resume
  流程。

## 当前实现

### Orchestrator 状态机

`SymphonyElixir.Orchestrator.State` 新增：

- `external_waiting`: 当前由外部系统推进的 no-Codex issue。
- `external_observations`: 每个 issue 最近一次观察到的 Codeup observed key。

每轮 poll 的顺序是：

1. reconcile running issues。
2. reconcile blocked issues。
3. reconcile external_waiting issues。
4. 从 Linear 拉取 candidate issues。
5. 先把 `Merging` / no-auto-Codex candidate 放进 `external_waiting`。
6. 再按 agent slots 调度普通可运行 issue。

因此 `external_waiting` 不依赖 agent slot。即使 `max_concurrent_agents` 已满或为
0，`Merging` issue 仍会被 runtime state 记录并展示。

### 冷启动恢复

冷启动或重启后，`Tracker.fetch_candidate_issues/0` 会按 workflow 的
`tracker.active_states` 拉取 Linear issue。当前 workflow 已把 `Merging` 配为
active state，并把 `Merging` 配为 `agent.no_auto_codex_states`。

符合条件的 issue 会进入 `external_waiting`，不会进入 ordinary dispatch。

### Codeup 监听

`SymphonyElixir.ExternalMergeWatcher` 负责轻量外部监听：

- 解析 fenced JSON Delivery Metadata。
- 当 issue description 没有 metadata 时，默认从 tracker comments 读取 Workpad
  comment。
- 用 metadata 查询 Codeup CR。
- 生成 observation：
  - provider
  - change_request_id
  - CR status
  - revision
  - observed_key
  - outcome
  - url

`TO_BE_MERGED` 等非终态只刷新 observation 并继续等待。metadata 缺失、Codeup API
错误或响应异常会写入 `external_waiting.error`，并把 `next_action` 标为
`needs_human`。

### 确定性收尾

`external_waiting` 的终态收尾不启动 Codex：

- `outcome: :merged` -> 创建 `External Merge Evidence` comment，并把 issue 移到
  `Done`。
- `outcome: :terminal_failure` -> 创建 `External Merge Evidence` comment，并把
  issue 移到 `Rework`。
- 如果创建 comment 或更新 Linear state 失败，issue 留在 `external_waiting`，
  error 会展示在 dashboard/API 中。

Evidence comment 会记录：

- provider
- change_request_id
- status
- revision
- observed_key
- url
- target_linear_state
- reason
- token_policy: no_codex
- recorded_at

### 和旧 blocked 行为的边界

`external_waiting` 不替代 blocked：

- Codex `turn_input_required` / approval required 仍然进入 blocked。
- `manual_resume` 仍然只唤醒 blocked issue，并安排一次 retry。
- 只有历史上因为 `"automatic codex dispatch suppressed"` 或
  `"continuation retry suppressed"` 进入 blocked 的 no-auto issue，才会迁移到
  `external_waiting`。
- operator-blocked 的 no-auto issue 会继续留在 blocked，不会被误迁移。

状态释放路径也会清理 `external_waiting`，避免它污染 running / retrying /
blocked 的生命周期。

## Dashboard 和 API

Web/API presenter 新增：

- `counts.external_waiting`
- 顶层 `external_waiting` 列表
- issue detail 的 `status: "external_waiting"`
- issue detail 的 `external_waiting` payload

Web dashboard 新增 `External waiting` 指标卡和独立表格，字段包括：

- issue
- Linear state
- Codeup CR
- CR status
- token policy
- last checked
- next action / error

Terminal dashboard 也新增 `External waiting` section，避免只在 Web 上可见。

## 运维判断

看到 `external_waiting` 时，含义是：

- Symphony 正在监听外部 CR。
- 当前阶段不会消耗 Codex token。
- 不是 retry queue。
- 不是 Codex 卡住。

常见 next action：

- `wait`: CR 还不是终态，继续等待。
- `finalize`: 已观察到终态，正在或已经尝试收尾。
- `needs_human`: metadata 缺失、Codeup API 失败、Linear mutation 失败或其他需要人工处理的错误。

常见 error：

- `:metadata_missing`: Workpad / issue description 中没有可解析的 Delivery Metadata。
- `:missing_yunxiao_access_token`: 缺少 `YUNXIAO_ACCESS_TOKEN` 或 `CODEUP_ACCESS_TOKEN`。
- `{:codeup_api_status, status}`: Codeup API 返回非 2xx。
- `:comment_create_failed` / `:issue_update_failed`: Linear comment 或状态更新失败。

## 关键文件

- `lib/symphony_elixir/orchestrator.ex`
- `lib/symphony_elixir/external_merge_watcher.ex`
- `lib/symphony_elixir/codeup/client.ex`
- `lib/symphony_elixir/tracker.ex`
- `lib/symphony_elixir/linear/adapter.ex`
- `lib/symphony_elixir_web/presenter.ex`
- `lib/symphony_elixir_web/live/dashboard_live.ex`
- `lib/symphony_elixir/status_dashboard.ex`
- `priv/static/dashboard.css`
- `WORKFLOW.md`
- `WORKFLOW.en.yunxiao.md`

## 验证覆盖

已覆盖的测试场景：

- no-auto `Merging` candidate 不会被 ordinary polling dispatch。
- 冷启动 poll 会把 `Merging` issue 放入 `external_waiting`，即使没有 agent slots。
- cold-start 已 merged CR 会直接 Done，不进 retry。
- unchanged Codeup CR 会刷新 observation 并继续等待。
- CR `MERGED` 会记录 evidence 并把 issue 移到 `Done`。
- CR `CLOSED` / terminal failure 会记录 evidence 并把 issue 移到 `Rework`。
- metadata 缺失会留在 `external_waiting` 并在 dashboard/API 显示 error。
- Workpad comment metadata 可被 watcher 默认读取。
- operator-blocked no-auto issue 不会被误迁移到 `external_waiting`。
- manual resume 仍然只作用于 blocked issue。
- API state 和 issue detail 展示 `external_waiting`。
- Web dashboard 展示 issue、Linear state、Codeup CR、CR status、token policy、
  last checked、next action/error。
- Terminal dashboard 展示 External waiting section。

最后一次全量验证：

```bash
cd /Users/ming/Code/symphony/elixir
mise exec -- mix test
```

结果：

```text
262 tests, 0 failures, 2 skipped
```
