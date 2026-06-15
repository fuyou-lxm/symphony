# Symphony Elixir

本目录包含 Elixir 代理编排服务。该服务会轮询 Linear、为每个 issue 创建独立工作区，并以 app-server 模式运行 Codex。

## 环境

- Elixir：通过 `mise` 使用 `1.19.x`（OTP 28）。
- 安装依赖：`mix setup`。
- 主要质量门禁：`make all`（格式检查、lint、覆盖率、dialyzer）。

## 代码库特定约定

- 运行时配置通过 `SymphonyElixir.Workflow` 和 `SymphonyElixir.Config` 从 `WORKFLOW.md` 的 front matter 加载。
- 在可行的情况下，使实现与 [`../SPEC.md`](../SPEC.md) 保持一致。
  - 实现可以是规范的超集。
  - 实现不得与规范冲突。
  - 如果实现变更显著改变了预期行为，应在可行时于同一次变更中更新规范，确保规范保持最新。
- 优先通过 `SymphonyElixir.Config` 添加配置访问，而不是临时读取环境变量。
- 工作区安全至关重要：
  - 不要在源码仓库中运行 Codex turn 的 cwd。
  - 工作区必须位于配置的工作区根目录之下。
- 编排器行为具有状态性且对并发敏感；必须保留重试、对账和清理语义。
- 遵循 `docs/logging.md` 中的日志约定，以及必需的 issue/session 上下文字段要求。

## 测试与验证

迭代时运行有针对性的测试，交付前运行完整门禁。

```bash
make all
```

## 必须遵守的规则

- `lib/` 中的公共函数（`def`）必须有相邻的 `@spec`。
- `defp` 的 spec 是可选的。
- `@impl` 回调实现不要求本地 `@spec`。
- 保持变更范围聚焦，避免无关重构。
- 遵循 `lib/symphony_elixir/*` 中既有的模块和风格模式。

验证命令：

```bash
mix specs.check
```

## PR 要求

- PR 正文必须严格遵循 `../.github/pull_request_template.md`。
- 需要时可在本地验证 PR 正文：

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## 文档更新策略

如果行为或配置发生变化，请在同一个 PR 中更新相关文档：

- `../README.md`：项目概念和目标。
- `README.md`：Elixir 实现和运行说明。
- `WORKFLOW.md`：工作流/配置契约变更。
