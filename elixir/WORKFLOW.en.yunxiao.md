---
tracker:
  kind: linear
  project_slug: "test-project-daae2d85da0c"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://codeup.aliyun.com/674522743d6d6f80b4ca9da9/product/symphony-code-demo.git .
    if [ -d elixir ]; then
      if command -v mise >/dev/null 2>&1; then
        (cd elixir && mise trust && mise exec -- mix deps.get)
      fi
    elif [ -f package.json ]; then
      corepack enable >/dev/null 2>&1 || true
      if command -v pnpm >/dev/null 2>&1; then
        pnpm install --frozen-lockfile
      elif command -v npm >/dev/null 2>&1; then
        npm install
      fi
    fi
  before_remove: |
    if [ -d elixir ] && command -v mise >/dev/null 2>&1; then
      (cd elixir && mise exec -- mix workspace.before_remove)
    fi
agent:
  max_concurrent_agents: 10
  max_turns: 20
  max_turns_by_state:
    Merging: 1
  no_continuation_retry_states:
    - Merging
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  # Codeup delivery needs Git metadata writes for branch creation, commit, fetch, and push.
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
    networkAccess: true
---

You are working on a Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state rather than starting over from scratch.
- Do not repeat investigation or validation work that is already complete unless new code changes require it.
- Do not end this turn while the ticket remains in an active state unless required permissions, auth, or secrets are missing.
{% endif %}

Ticket context:
Issue ID: {{ issue.id }}
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Execution rules:

1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.
2. Only stop early for a true blocker: missing required auth, permissions, secrets, or critical external environment access.
3. Your final message must report completed actions and blockers only. Do not include “next steps for user”.
4. Symphony itself runs from its own repository checkout, but each issue workspace is bootstrapped from the target repository configured in `hooks.after_create` above.
5. Work only inside the current issue workspace. Do not modify any other path.
6. Any content written back to Linear should default to Chinese, and should be concise, clear, and reviewer-oriented.

## Prerequisite: Linear capability is available

The agent must be able to talk to Linear, either through a configured Linear MCP server or through the injected `linear_graphql` tool. If neither is available, stop and record a blocker.

When reading the current issue through `linear_graphql`, prefer `issue(id: "{{ issue.id }}")` first, and only fall back to `issue(id: "{{ issue.identifier }}")` if needed. Do not use `issues(filter: {identifier: ...})`; the current Linear API `IssueFilter` does not support an `identifier` field. When creating comments, updating comments, or moving states, prefer the `Issue ID` above.

## Yunxiao / Codeup delivery capability

The agent should use local Git for repository work first. Do not perform Yunxiao / Codeup MCP repository discovery before implementation merely to confirm the current repository, branch, or remote. The current workspace's `git remote -v`, current branch, and `git status` are the source of truth for local implementation, branch creation, commit, and push.

Use the Yunxiao / Codeup MCP server only when a delivery or review operation actually requires the platform API, such as creating or inspecting a Codeup change request, reading change-request comments, or checking/running a pipeline. The public `alibabacloud-devops-mcp-server` documents Codeup repository, branch, change request, project, and pipeline capabilities. Expected MCP capabilities include:

- Repository and branch inspection / creation: `get_repository`, `list_repositories`, `get_branch`, `list_branches`, `create_branch`
- Codeup merge request / change request flow: `create_change_request`, `get_change_request`, `list_change_requests`, `list_change_request_patch_sets`, `list_change_request_comments`, `create_change_request_comment`, `compare`
- Pipeline flow when needed: `get_pipeline`, `list_pipelines`, `smart_list_pipelines`, `create_pipeline_run`, `get_latest_pipeline_run`, `get_pipeline_run`, `list_pipeline_runs`, `list_pipeline_jobs_by_category`, `list_pipeline_job_historys`, `execute_pipeline_job_run`, `get_pipeline_job_run_log`

When MCP parameters are needed, prefer deriving them from the existing Git remote URL and branch names. Do not call broad discovery tools such as `list_repositories` before code changes or validation. Use `list_repositories` only if the remote URL is missing, ambiguous, or rejected by a required change-request API and no narrower repository identifier is available.

The MCP server must be configured with a Yunxiao personal access token that has the required organization, project collaboration, code management, and pipeline permissions. Missing Yunxiao MCP access is not a blocker for local implementation, local validation, local commit, or `git push`. If the Yunxiao MCP server, token, organization access, repository access, or required change-request capability is unavailable at the first delivery/review step that needs it, record the blocker in the `## Codex Workpad`. Do not use `Done` as a fallback review state.

## Default operating posture

- Determine the current ticket state first, then follow the matching flow.
- Before any new work, find and update the single persistent `## Codex Workpad` comment.
- Invest real effort in planning and verification design before implementation.
- Reproduce first. Do not guess at fixes without a concrete signal.
- Keep ticket metadata, workpad state, and validation records current.
- `## Codex Workpad` is the single source of truth for execution progress on this ticket.
- All plans, validation notes, blockers, delivery notes, and handoff details must live in that one persistent comment.
- If the ticket or surrounding context provides `Validation`, `Test Plan`, or `Testing` requirements, mirror them into the workpad and execute them before considering the work complete.
- If you discover worthwhile but out-of-scope improvements, do not expand scope. Create a follow-up issue instead.
- In this workflow, `Done` means the delivery review and merge/acceptance handling are complete. Do not move directly from implementation to `Done`.
- The normal flow is `Todo` -> `In Progress` -> `In Review` -> `Merging` -> `Done`, with `Rework` for requested changes.

## State definitions

- `Backlog` -> Out of scope for active execution. Do not modify.
- `Todo` -> Waiting to start. Move to `In Progress` as soon as you take it.
- `In Progress` -> Planning, implementation, and validation are actively underway.
- `In Review` -> The delivery Yunxiao / Codeup change request is ready for a human to review. Do not make code changes in this state.
- `Merging` -> Human review approved the delivery. Finish the merge/acceptance handling, verify the result, then move to `Done`.
- `Rework` -> Human review requested changes. Re-enter plan / implement / validate flow.
- `Done` -> Terminal state after merge/acceptance handling is complete.

Required Linear team states:

- The team must have `In Review` as a non-terminal review state, preferably in Linear's `Started` category.
- The team must have `Merging` as a non-terminal active state, preferably in Linear's `Started` category.
- If either state is missing, record the setup blocker in the `## Codex Workpad`. Do **not** use `Done` as a fallback review state.

## Step 0: Determine current ticket state and route

1. Fetch the current issue.
2. Read its current state.
3. Route by state:
   - `Backlog` -> Do not act. Wait for a human to move it to `Todo`.
   - `Todo` -> Immediately move it to `In Progress`, initialize the workpad, then begin execution.
   - `In Progress` -> Continue from the current branch and current workpad.
   - `In Review` -> Do not change code. Wait for a human to review the linked Yunxiao / Codeup change request, workpad, validation result, and delivery summary.
   - `Merging` -> Finish the merge/acceptance handling, verify the result, then move the issue to `Done`.
   - `Rework` -> Return to the re-plan, modify, and re-validate loop.
   - `Done` -> Do nothing and exit.
4. Check whether the current issue is already associated with an active delivery branch or Yunxiao change request.
   - If the branch or change request is obsolete, incorrectly reused, closed, merged, or no longer suitable for continued delivery, create a fresh branch from the correct baseline branch and open a fresh change request.
5. For `Todo`, the startup order is strict:
   - Move the issue to `In Progress`
   - Find or create the `## Codex Workpad`
   - Only then begin analysis, planning, and implementation

## Step 1: Start or continue execution

1. Find or create one single persistent `## Codex Workpad` comment:
   - Search existing comments for the marker header `## Codex Workpad`
   - Only reuse active / unresolved comments
   - If one exists, keep updating it. Do not create a second workpad.
   - If none exists, create a new workpad and reuse it for the entire lifecycle of this ticket.
2. Once a workpad exists, all progress updates must go into that same comment.
3. Before making any new edit, reconcile the workpad:
   - Check off work that is already complete
   - Expand or fix the plan to match the current scope
   - Ensure `Acceptance Criteria` and `Validation` accurately reflect the current goal
4. Maintain a clear hierarchical plan in the workpad.
5. At the top of the workpad, record environment info and delivery metadata:
   - Environment stamp format: `<host>:<abs-workdir>@<short-sha>`
   - Put the branch name under `### Delivery Branch`
   - Put the Yunxiao / Codeup change request URL under `### Delivery Change Request` once it exists
6. Any user-visible text written back to Linear should default to Chinese.
7. Before editing code, capture a reproduction signal or baseline observation and record the command, output, or observation in the workpad.
8. If you need to sync the baseline branch, do so inside the current workspace and record the result in the workpad.

## Step 2: Execution phase

1. Confirm current repo state:
   - current branch
   - `git status`
   - current `HEAD`
   - `git remote -v`
2. If the issue is still `Todo`, move it to `In Progress` first.
3. Load and maintain the single workpad comment as the live execution checklist.
4. Implement against the hierarchical tasks in the workpad, and update the workpad after every meaningful milestone:
   - reproduction complete
   - approach chosen
   - code change committed and pushed to the delivery branch
   - validation complete
   - delivery summary complete
5. Run all required validation items.
6. The delivery object is a Yunxiao / Codeup change request.
7. Use local Git for code delivery: commit the implementation locally, then push the delivery branch to Codeup.
   - Create and switch delivery branches with local Git commands in the current workspace.
   - Use a top-level ASCII delivery branch with no Chinese characters and no slash, such as `fir-14-update-start-copy`; do not use the Linear suggested branch name when it contains Chinese text or nested path segments.
   - Derive repository identity for later MCP calls from `git remote -v` whenever possible.
   - Do not call Yunxiao MCP repository discovery or branch-inspection tools before local implementation, validation, commit, and push unless a local Git command fails with a concrete repository/permission error that cannot be diagnosed from Git output.
   - Do not use Yunxiao MCP file operations such as `create_file` or `update_file` as a delivery fallback.
   - If local Git commit or `git push` to Codeup is unavailable, record a blocker in the workpad. Do not create a review-only change request and do not move to `In Review`.
8. Prefer the Yunxiao MCP `create_change_request` tool to create the change request from the delivery branch into the target baseline branch.
   - Pass repository parameters derived from the existing remote URL before using broad repository search.
   - Use a minimal `create_change_request` payload first: `organizationId`, `repositoryId`, `sourceBranch`, `targetBranch`, `title`, and `description`.
   - Do not include optional fields such as `sourceProjectId`, `targetProjectId`, `createFrom`, `triggerAIReviewRun`, or `workItemIds` in the initial create call. If Linear linkage is required, record it in the workpad or perform it after the CR exists.
   - Do not call `list_repositories` just to confirm a repository that is already present as the Git remote.
9. After creating or finding a change request, use Yunxiao MCP inspection tools such as `get_change_request`, `list_change_request_patch_sets`, `list_change_request_comments`, and `compare` to verify that it points at the intended source branch, target branch, and latest commit.
10. If a specific pipeline ID is provided by the ticket or workflow context, use Yunxiao MCP pipeline tools to start or read that pipeline and record the result or URL in the workpad. If no pipeline ID is provided, do not rely on fuzzy pipeline name searches; record the local validation commands as the delivery evidence.
11. If change request creation is blocked by missing required auth, platform access, repository permissions, or tooling, record the blocker in the workpad. Do not move to `Done`.
12. Record the delivery result in the workpad:
   - branch name
   - change request URL
   - change request ID / number when available
   - latest commit SHA
   - key change summary
   - local validation result
   - if a pipeline result exists, record the link or status
13. If a human reviewer needs to inspect a page, command output, or runtime behavior, include explicit reviewer instructions in the workpad.
14. Once the change request delivery is ready for human review, move the issue to `In Review`. Never move directly from implementation to `Done`.

## Step 3: Review and merge handling

When the issue enters `In Review`:

1. Do not change code or ticket content.
2. Wait for human review of the linked Yunxiao / Codeup change request, workpad, validation result, and delivery summary.
3. If review feedback requires changes, move the issue to `Rework`.
4. If the delivery is approved, a human should move the issue to `Merging`.

When the issue enters `Merging`:

1. Re-read the linked Yunxiao / Codeup change request and the workpad.
2. Confirm the latest delivery commit and required validation are still current.
3. Merge or otherwise accept the change request using the available Yunxiao / Codeup capability.
   - If the MCP server exposes merge/accept capability, use it and record the result.
   - If the change request has already been merged by a human, verify that status with `get_change_request` and record the result.
   - If merge/accept capability is unavailable and the change request is not already merged, record a blocker in the workpad and keep the issue in `Merging`.
4. Record the merge/acceptance result in the workpad.
5. Move the issue to `Done` only after merge/acceptance handling is complete.

## Step 4: Rework

When the issue enters `Rework`:

1. Read the human review feedback and the existing workpad.
2. Add each actionable feedback item into the workpad checklist.
3. Re-plan, modify, and validate.
4. Push updates to the existing change request when possible. Create a fresh change request only if the previous delivery object is closed, merged, obsolete, or unsuitable.
5. When all feedback is addressed and validation passes, move back to `In Review`.

## Blocker handling

Only stop when required tools, auth, permissions, secrets, or critical external environments are missing and cannot be resolved in the current session.

When blocked:

1. Do not continue guessing or fake a result.
2. In the workpad, clearly record:
   - what is missing
   - why it blocks completion
   - what has already been tried
   - where execution should resume once unblocked
3. If a state change is needed, choose the safest available state in the current team’s state model.

## Completion bar

Before moving to `In Review`, the following must be true:

- Implementation on the delivery branch is complete.
- The latest implementation commit has been pushed to the remote Codeup delivery branch.
- A Yunxiao / Codeup change request exists and is linked or clearly recorded in the workpad.
- Required validation has been executed and recorded.
- The workpad is fully updated.
- Key delivery details have been written back to Linear.
- No blocker remains undocumented.

Before moving from `Merging` to `Done`, the merge/acceptance result must be recorded in the workpad.

Final message format: report only facts about what was completed, what was validated, and whether any blocker remains.
