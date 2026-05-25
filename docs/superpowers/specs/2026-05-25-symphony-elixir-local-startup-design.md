# Symphony Elixir reference implementation local startup design

## Goal

Use the official experimental Elixir reference implementation in this repository and follow the documented startup path to reach a local runnable state.

## Scope

- Work inside `elixir/` in the current `openai/symphony` repository.
- Follow the official run sequence from `elixir/README.md`.
- Verify whether the implementation can be built and started locally on this machine.
- If startup is blocked by missing local tooling, dependencies, or required environment variables, identify the exact blocker.

## Out of scope

- No real Linear integration or issue orchestration validation.
- No customization for another repository.
- No redesign or feature work on the Elixir implementation.
- No source changes unless a small local fix is required to make the documented path work as written.

## Chosen approach

Follow the official shortest path from `elixir/README.md:61-71`:

1. `mise trust`
2. `mise install`
3. `mise exec -- mix setup`
4. `mise exec -- mix build`
5. `mise exec -- ./bin/symphony ./WORKFLOW.md`

This intentionally stays close to the reference implementation and treats any failure as useful signal about missing prerequisites on the local machine.

## Why this approach

- It is the closest match to the repository’s “Option 2. Use our experimental reference implementation” guidance in `README.md:28-35`.
- It minimizes interpretation drift from the upstream instructions.
- It gives a clear yes/no answer on whether the reference implementation starts locally via the supported path.

## Expected outcomes

### Success case

- The Elixir project dependencies install successfully.
- The project builds successfully.
- The `symphony` binary starts with `./WORKFLOW.md`.

### Failure case

If startup does not succeed, the result should still be actionable:

- exact failing command
- exact error output
- classification of the blocker:
  - missing `mise`
  - missing Erlang/Elixir toolchain
  - dependency install/build failure
  - required environment variable such as `LINEAR_API_KEY`
  - missing Codex runtime or related runtime dependency

## Constraints

- Do not inject real production credentials.
- Do not claim successful startup without actually running the command.
- Prefer environment diagnosis over speculative fixes.

## Verification

Verification will be based on actually running the official commands and recording their outputs. A successful conclusion requires observed command results, not inference from docs.

## Handoff after this spec

If the spec is approved, the next step is to turn it into an implementation plan and then execute the startup sequence in the repository.
