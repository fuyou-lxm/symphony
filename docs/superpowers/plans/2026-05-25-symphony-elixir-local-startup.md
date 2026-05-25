# Symphony Elixir Local Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and start the Elixir reference implementation in this repository by following the official README startup sequence and stop with a precise blocker report if the local environment is incomplete.

**Architecture:** This work does not change Symphony architecture. It validates the upstream operator path by executing the documented local bootstrap and startup commands in `elixir/`, using command output as the source of truth for success or blockers.

**Tech Stack:** mise, Erlang/OTP, Elixir/Mix, Symphony Elixir CLI

---

## File structure and responsibilities

- `elixir/README.md` — authoritative operator instructions for the reference implementation startup path.
- `elixir/AGENTS.md` — local implementation and validation rules for work inside `elixir/`.
- `elixir/.tool-versions` or `elixir/mise.toml` — toolchain versions consumed by `mise` during install.
- `elixir/mix.exs` — Mix project entry point used by `mix setup` and `mix build`.
- `elixir/WORKFLOW.md` — default workflow file passed to the Symphony binary during startup.
- `docs/superpowers/specs/2026-05-25-symphony-elixir-local-startup-design.md` — approved design for this work.
- `docs/superpowers/plans/2026-05-25-symphony-elixir-local-startup.md` — this execution plan.

### Task 1: Verify repository startup inputs

**Files:**
- Read: `elixir/README.md`
- Read: `elixir/AGENTS.md`
- Read: `elixir/mix.exs`
- Read: `elixir/WORKFLOW.md`
- Read: `elixir/.tool-versions` or `elixir/mise.toml`

- [ ] **Step 1: Read the local operator instructions and project rules**

Read these files:

```text
/Users/ming/Code/symphony/elixir/README.md
/Users/ming/Code/symphony/elixir/AGENTS.md
```

Confirm the startup sequence remains:
- `mise trust`
- `mise install`
- `mise exec -- mix setup`
- `mise exec -- mix build`
- `mise exec -- ./bin/symphony ./WORKFLOW.md`

- [ ] **Step 2: Read the Mix project entry point**

Read:

```text
/Users/ming/Code/symphony/elixir/mix.exs
```

Confirm the project is a normal Mix application and note any custom aliases or setup tasks that affect `mix setup` or `mix build`.

- [ ] **Step 3: Read the default workflow file used at startup**

Read:

```text
/Users/ming/Code/symphony/elixir/WORKFLOW.md
```

Confirm whether it references required environment variables such as `LINEAR_API_KEY` that may block startup without credentials.

- [ ] **Step 4: Read the toolchain version file used by mise**

Read whichever exists:

```text
/Users/ming/Code/symphony/elixir/.tool-versions
/Users/ming/Code/symphony/elixir/mise.toml
```

Document the required Erlang/OTP and Elixir versions before running installs.

- [ ] **Step 5: Commit the planning baseline**

```bash
git add docs/superpowers/specs/2026-05-25-symphony-elixir-local-startup-design.md docs/superpowers/plans/2026-05-25-symphony-elixir-local-startup.md
git commit -m "docs: add symphony elixir local startup plan"
```

### Task 2: Execute the documented bootstrap commands

**Files:**
- Use: `elixir/README.md:61-71`
- Use: `elixir/mix.exs`
- Use: `elixir/WORKFLOW.md`

- [ ] **Step 1: Run the trust step exactly as documented**

Run:

```bash
cd /Users/ming/Code/symphony/elixir && mise trust
```

Expected:
- exit code 0, or
- a clear error showing `mise` is not installed or not available in PATH.

- [ ] **Step 2: Run the install step exactly as documented**

Run:

```bash
cd /Users/ming/Code/symphony/elixir && mise install
```

Expected:
- toolchain installation completes, or
- a specific install failure naming the missing dependency or unsupported version.

- [ ] **Step 3: Run setup exactly as documented**

Run:

```bash
cd /Users/ming/Code/symphony/elixir && mise exec -- mix setup
```

Expected:
- dependencies and local project setup complete successfully, or
- a concrete Mix/dependency error that identifies the blocker.

- [ ] **Step 4: Run build exactly as documented**

Run:

```bash
cd /Users/ming/Code/symphony/elixir && mise exec -- mix build
```

Expected:
- successful build artifacts, or
- a compile/build error with exact failing module or dependency.

- [ ] **Step 5: Commit any purely local startup-support changes if required**

If no files changed, record that no commit is needed.

If a small local fix was required and approved, commit it with exact files only:

```bash
git add <exact-file-paths>
git commit -m "fix: unblock local symphony startup"
```

### Task 3: Attempt startup and classify the result

**Files:**
- Use: `elixir/WORKFLOW.md`
- Observe: runtime output from `./bin/symphony`

- [ ] **Step 1: Start Symphony with the default workflow file**

Run:

```bash
cd /Users/ming/Code/symphony/elixir && mise exec -- ./bin/symphony ./WORKFLOW.md
```

Expected:
- the process starts and emits runtime logs, or
- startup fails with a concrete missing prerequisite such as `LINEAR_API_KEY`, Codex runtime availability, invalid workflow config, or another boot-time dependency.

- [ ] **Step 2: Record the exact startup outcome**

Capture:
- the exact command run
- exit code or evidence that the process remained running
- the first blocking error line if startup failed

Expected output format:

```text
Command: mise exec -- ./bin/symphony ./WORKFLOW.md
Result: <running | exited>
Blocker: <none | exact blocker>
```

- [ ] **Step 3: Classify the result against the approved spec**

Map the result into one of:
- success
- missing `mise`
- missing Erlang/Elixir toolchain
- dependency install/build failure
- required environment variable such as `LINEAR_API_KEY`
- missing Codex runtime or related runtime dependency
- other startup dependency

Expected:
- one final classification only, based on observed output.

- [ ] **Step 4: Run the relevant verification command for the final state**

If startup never reached build success, rerun the failing command once only if needed to confirm the same blocker.

If build succeeded and the app started, run:

```bash
cd /Users/ming/Code/symphony/elixir && mise exec -- mix build
```

Expected:
- PASS for the build verification, plus evidence that startup previously reached a running state.

- [ ] **Step 5: Commit any documentation updates needed to reflect a reproducible startup fix**

If no docs changed, record that no commit is needed.

If startup required a small documented fix, update the exact docs and commit:

```bash
git add elixir/README.md elixir/AGENTS.md docs/superpowers/specs/2026-05-25-symphony-elixir-local-startup-design.md docs/superpowers/plans/2026-05-25-symphony-elixir-local-startup.md
git commit -m "docs: clarify symphony local startup steps"
```

### Task 4: Summarize final status for handoff

**Files:**
- Read: command outputs from Task 2 and Task 3
- Optionally modify: `elixir/README.md` only if an approved clarification is necessary

- [ ] **Step 1: Write the final operator summary in the response**

Include:
- whether `mix setup` succeeded
- whether `mix build` succeeded
- whether `./bin/symphony ./WORKFLOW.md` started
- the exact blocker if it did not start

Expected format:

```text
Setup: <passed|failed>
Build: <passed|failed>
Startup: <running|failed>
Next requirement: <none|exact prerequisite>
```

- [ ] **Step 2: Verify there are no unreviewed code changes before handoff**

Run:

```bash
git status --short
```

Expected:
- either clean working tree, or
- only intentional files related to this startup exercise.

- [ ] **Step 3: If code or docs changed, request code review before claiming completion**

Use the required completion review flow before claiming the task is done.

Expected:
- no completion claim without verification and review when changes exist.

- [ ] **Step 4: Leave the repo in a known state**

If Symphony is still running from Task 3, stop it explicitly after verification and note that it was stopped.

Expected:
- no stray background process left behind unless the user asks to keep it running.

## Self-review

- Spec coverage: the plan covers reading the official inputs, executing the exact README startup commands, attempting startup, and classifying success or blockers with observed output.
- Placeholder scan: no `TBD`, `TODO`, or “handle appropriately” placeholders remain.
- Type consistency: not applicable in the normal coding sense because this plan is command-driven, but the same command names and file paths are used consistently throughout.
