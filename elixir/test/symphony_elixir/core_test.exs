defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), no_auto_codex_states: ["Merging"])
    assert Config.settings!().agent.no_auto_codex_states == ["merging"]
    assert Config.no_auto_codex_for_state?("merging")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "Yunxiao workflow avoids repository-specific bootstrap and CR parameter pitfalls" do
    workflow_path = Path.expand("WORKFLOW.en.yunxiao.md", File.cwd!())

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(workflow_path)

    hooks = Map.fetch!(config, "hooks")
    after_create = Map.fetch!(hooks, "after_create")

    assert after_create =~ "if [ -d elixir ]; then"
    assert after_create =~ "(cd elixir && mise trust && mise exec -- mix deps.get)"
    assert after_create =~ "elif [ -f package.json ]; then"
    refute after_create =~ ~r/^\s*cd elixir &&/m

    agent = Map.fetch!(config, "agent")
    assert Map.fetch!(agent, "max_turns_by_state") == %{"Merging" => 1}
    assert Map.fetch!(agent, "no_continuation_retry_states") == ["Merging"]
    assert Map.fetch!(agent, "no_auto_codex_states") == ["Merging"]

    assert prompt =~ "Use a top-level ASCII delivery branch"
    assert prompt =~ "minimal `create_change_request` payload"
    assert prompt =~ "Do not include optional fields such as `sourceProjectId`"
  end

  test "PowerChat workflow detaches dev server from hook pipes while keeping watch stdin open" do
    workflow_path = Path.expand("WORKFLOW.en.powerchat.md", File.cwd!())

    assert {:ok, %{config: config}} = Workflow.load(workflow_path)

    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")

    assert before_run =~ "nohup sh -c"
    assert before_run =~ "rm -f .symphony/keep_powerchat_preview"
    assert before_run =~ "tail -f /dev/null |"
    assert before_run =~ "CHECK_TIMEOUT=30"
    assert before_run =~ "< /dev/null > \"$WORKSPACE_ROOT/.symphony/powerchat.log\" 2>&1 &"
  end

  test "PowerChat workflow keeps review preview and cleans it when external waiting starts" do
    workflow_path = Path.expand("WORKFLOW.en.powerchat.md", File.cwd!())

    assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.load(workflow_path)

    hooks = Map.fetch!(config, "hooks")
    after_run = Map.fetch!(hooks, "after_run")
    after_external_waiting_start = Map.fetch!(hooks, "after_external_waiting_start")

    assert after_run =~ ".symphony/keep_powerchat_preview"
    assert after_run =~ "exit 0"
    assert after_external_waiting_start =~ ".symphony/keep_powerchat_preview"
    assert after_external_waiting_start =~ ".symphony/powerchat.pid"
    assert after_external_waiting_start =~ "POWERCHAT_PORT"
    assert after_external_waiting_start =~ "tailwindcss.*--watch"

    assert prompt =~ "POWERCHAT_URL"
    assert prompt =~ ".symphony/keep_powerchat_preview"
    assert prompt =~ "### Review Preview"
  end

  test "Antigravity PowerChat workflow starts preview on demand with a bounded Node heap" do
    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())

    assert {:ok, %{config: config, prompt_template: prompt}} = Workflow.load(workflow_path)

    after_create = config |> Map.fetch!("hooks") |> Map.fetch!("after_create")
    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")

    assert after_create =~ "git clone --depth 1"
    assert after_create =~ "packages/spark-chat/package.json"
    refute after_create =~ "npm ci"
    refute after_create =~ "npm install"
    refute after_create =~ "pnpm install"
    assert before_run =~ ".symphony/start_powerchat_preview.sh"
    assert before_run =~ ".symphony/ensure_powerchat_deps.sh"
    assert before_run =~ "SYMPHONY_PNPM_STORE_DIR"

    assert before_run =~
             "pnpm install --store-dir \"$PNPM_STORE_DIR\" --frozen-lockfile --config.dangerouslyAllowAllBuilds=true --prefer-offline"

    assert before_run =~ "pnpm run dev"
    refute before_run =~ ~r/(^|[^[:alnum:]_-])npm run dev/
    assert before_run =~ "SYMPHONY_POWERCHAT_AUTO_START_PREVIEW:-0"
    assert before_run =~ "SYMPHONY_POWERCHAT_NODE_MAX_OLD_SPACE_MB:-256"
    assert before_run =~ "--max-old-space-size="
    assert prompt =~ "on demand"
    assert prompt =~ "pnpm"
    assert prompt =~ ".symphony/start_powerchat_preview.sh"
    assert prompt =~ ".symphony/ensure_powerchat_deps.sh"
  end

  test "Antigravity PowerChat before_run hook does not start preview by default" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-powerchat-agy-on-demand-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())
    assert {:ok, %{config: config}} = Workflow.load(workflow_path)
    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")
    workspace = Path.join(test_root, "MT-AGY-ON-DEMAND")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: before_run
    )

    assert :ok = Workspace.run_before_run_hook(workspace, "MT-AGY-ON-DEMAND")

    env = File.read!(Path.join([workspace, ".symphony", "powerchat.env"]))
    assert env =~ "POWERCHAT_PREVIEW_MODE=on_demand"
    assert env =~ "POWERCHAT_NODE_MAX_OLD_SPACE_MB=256"
    assert env =~ "POWERCHAT_START_COMMAND=./.symphony/start_powerchat_preview.sh"
    refute env =~ "POWERCHAT_URL="
    refute File.exists?(Path.join([workspace, ".symphony", "powerchat.pid"]))
    assert File.exists?(Path.join([workspace, ".symphony", "start_powerchat_preview.sh"]))
    assert File.exists?(Path.join([workspace, ".symphony", "ensure_powerchat_deps.sh"]))

    ensure_deps = File.read!(Path.join([workspace, ".symphony", "ensure_powerchat_deps.sh"]))
    assert ensure_deps =~ "pnpm-lock.yaml"
    assert ensure_deps =~ "package-lock.json"
    assert ensure_deps =~ "pnpm import"
    assert ensure_deps =~ "corepack enable"
    assert ensure_deps =~ "SYMPHONY_PNPM_STORE_DIR"
    assert ensure_deps =~ "SYMPHONY_PNPM_LOCK_CACHE_DIR"
    assert ensure_deps =~ "cleanup_generated_pnpm_lock"

    assert ensure_deps =~
             "pnpm install --store-dir \"$PNPM_STORE_DIR\" --frozen-lockfile --config.dangerouslyAllowAllBuilds=true --prefer-offline"

    refute ensure_deps =~ "pnpm config set store-dir"
    refute ensure_deps =~ "npm ci"
    refute ensure_deps =~ ~r/(^|[^[:alnum:]_-])npm install/
  end

  test "Antigravity PowerChat dependency helper imports package lock and installs with pnpm store" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-powerchat-agy-pnpm-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())
    assert {:ok, %{config: config}} = Workflow.load(workflow_path)
    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")
    workspace = Path.join(test_root, "MT-AGY-PNPM")
    spark_chat = Path.join([workspace, "packages", "spark-chat"])
    fake_bin = Path.join(test_root, "bin")
    pnpm_calls = Path.join(test_root, "pnpm.calls")
    pnpm_lock_cache = Path.join(test_root, "pnpm-lock-cache")

    File.mkdir_p!(spark_chat)
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(spark_chat, "package.json"), ~s({"scripts":{"dev":"dumi dev"}}))
    File.write!(Path.join(spark_chat, "package-lock.json"), ~s({"lockfileVersion":3}))
    File.write!(Path.join(fake_bin, "corepack"), "#!/bin/sh\nexit 0\n")

    File.write!(
      Path.join(fake_bin, "pnpm"),
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{pnpm_calls}"
      if [ "$1" = "import" ]; then
        printf 'lockfileVersion: "9.0"\\n' > pnpm-lock.yaml
      fi
      exit 0
      """
    )

    File.chmod!(Path.join(fake_bin, "corepack"), 0o755)
    File.chmod!(Path.join(fake_bin, "pnpm"), 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: before_run
    )

    assert :ok = Workspace.run_before_run_hook(workspace, "MT-AGY-PNPM")

    ensure_deps = Path.join([workspace, ".symphony", "ensure_powerchat_deps.sh"])

    env = [
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_PNPM_STORE_DIR", Path.join(test_root, "shared-pnpm-store")},
      {"SYMPHONY_PNPM_LOCK_CACHE_DIR", pnpm_lock_cache}
    ]

    assert {_, 0} = System.cmd(ensure_deps, [], cd: workspace, env: env, stderr_to_stdout: true)
    assert {_, 0} = System.cmd(ensure_deps, [], cd: workspace, env: env, stderr_to_stdout: true)

    refute File.exists?(Path.join(spark_chat, "pnpm-lock.yaml"))
    assert length(Path.wildcard(Path.join([pnpm_lock_cache, "*", "pnpm-lock.yaml"]))) == 1

    calls = File.read!(pnpm_calls)
    call_lines = String.split(calls, "\n", trim: true)
    assert Enum.count(call_lines, &(&1 == "import")) == 1

    assert calls =~
             "install --store-dir #{Path.join(test_root, "shared-pnpm-store")} --frozen-lockfile --config.dangerouslyAllowAllBuilds=true --prefer-offline"

    assert Enum.count(call_lines, &String.starts_with?(&1, "install ")) == 2
    refute calls =~ ~r/(^|[^[:alnum:]_-])npm/
  end

  test "Antigravity PowerChat dependency helper preserves an existing pnpm lockfile" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-powerchat-agy-pnpm-existing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())
    assert {:ok, %{config: config}} = Workflow.load(workflow_path)
    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")
    workspace = Path.join(test_root, "MT-AGY-PNPM-EXISTING")
    spark_chat = Path.join([workspace, "packages", "spark-chat"])
    fake_bin = Path.join(test_root, "bin")
    pnpm_calls = Path.join(test_root, "pnpm.calls")

    File.mkdir_p!(spark_chat)
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(spark_chat, "package.json"), ~s({"scripts":{"dev":"dumi dev"}}))
    File.write!(Path.join(spark_chat, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n")

    File.write!(
      Path.join(fake_bin, "pnpm"),
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{pnpm_calls}"
      exit 0
      """
    )

    File.chmod!(Path.join(fake_bin, "pnpm"), 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: before_run
    )

    assert :ok = Workspace.run_before_run_hook(workspace, "MT-AGY-PNPM-EXISTING")

    ensure_deps = Path.join([workspace, ".symphony", "ensure_powerchat_deps.sh"])

    env = [
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_PNPM_STORE_DIR", Path.join(test_root, "shared-pnpm-store")}
    ]

    assert {_, 0} = System.cmd(ensure_deps, [], cd: workspace, env: env, stderr_to_stdout: true)

    assert File.read!(Path.join(spark_chat, "pnpm-lock.yaml")) == "lockfileVersion: '9.0'\n"

    calls = File.read!(pnpm_calls)
    refute calls =~ "import"

    assert calls =~
             "install --store-dir #{Path.join(test_root, "shared-pnpm-store")} --frozen-lockfile --config.dangerouslyAllowAllBuilds=true --prefer-offline"
  end

  test "Antigravity PowerChat dependency helper cleans temporary pnpm lockfile after install failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-powerchat-agy-pnpm-fail-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())
    assert {:ok, %{config: config}} = Workflow.load(workflow_path)
    before_run = config |> Map.fetch!("hooks") |> Map.fetch!("before_run")
    workspace = Path.join(test_root, "MT-AGY-PNPM-FAIL")
    spark_chat = Path.join([workspace, "packages", "spark-chat"])
    fake_bin = Path.join(test_root, "bin")
    pnpm_calls = Path.join(test_root, "pnpm.calls")

    File.mkdir_p!(spark_chat)
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(spark_chat, "package.json"), ~s({"scripts":{"dev":"dumi dev"}}))
    File.write!(Path.join(spark_chat, "package-lock.json"), ~s({"lockfileVersion":3}))

    File.write!(
      Path.join(fake_bin, "pnpm"),
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{pnpm_calls}"
      if [ "$1" = "import" ]; then
        printf 'lockfileVersion: "9.0"\\n' > pnpm-lock.yaml
        exit 0
      fi
      exit 42
      """
    )

    File.chmod!(Path.join(fake_bin, "pnpm"), 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: before_run
    )

    assert :ok = Workspace.run_before_run_hook(workspace, "MT-AGY-PNPM-FAIL")

    ensure_deps = Path.join([workspace, ".symphony", "ensure_powerchat_deps.sh"])

    env = [
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_PNPM_STORE_DIR", Path.join(test_root, "shared-pnpm-store")},
      {"SYMPHONY_PNPM_LOCK_CACHE_DIR", Path.join(test_root, "pnpm-lock-cache")}
    ]

    assert {_, 42} = System.cmd(ensure_deps, [], cd: workspace, env: env, stderr_to_stdout: true)

    refute File.exists?(Path.join(spark_chat, "pnpm-lock.yaml"))
    assert File.read!(pnpm_calls) =~ "install"
  end

  test "Antigravity PowerChat workflow reserves realistic memory for each cold-start dispatch" do
    workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())

    assert {:ok, %{config: config}} = Workflow.load(workflow_path)

    agent = Map.fetch!(config, "agent")
    max_concurrent_agents = Map.fetch!(agent, "max_concurrent_agents")
    max_rss_bytes = Map.fetch!(agent, "max_process_tree_rss_bytes")
    reservation_bytes = Map.fetch!(agent, "dispatch_rss_reservation_bytes")

    assert Map.fetch!(agent, "provider") == "antigravity_cli"
    assert max_concurrent_agents == 10
    assert max_rss_bytes == 5 * 1024 * 1024 * 1024
    assert reservation_bytes <= div(max_rss_bytes, max_concurrent_agents)
    assert reservation_bytes * max_concurrent_agents <= max_rss_bytes - 1 * 1024 * 1024 * 1024
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms, delay_type: :continuation} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
  end

  test "normal worker exit blocks continuation retry for configured active states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_continuation_retry_states: ["Merging"]
    )

    issue_id = "issue-no-continuation"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-560",
      state: "Merging",
      title: "Awaiting external merge",
      description: "Do not keep spending Codex turns",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NoContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %{issue | state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(1_200)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute MapSet.member?(state.completed, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
    assert %{identifier: "MT-560", issue: ^issue} = state.blocked[issue_id]
  end

  test "abnormal worker exit moves no-auto-Codex states to external waiting without retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue_id = "issue-merging-crash"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "Merging",
      title: "Awaiting Codeup merge",
      description: "Do not retry Codex while waiting",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NoAutoCodexCrashOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-562",
      issue: issue,
      retry_attempt: 1,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(1_200)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    refute Map.has_key?(state.retry_attempts, issue_id)
    refute Map.has_key?(state.blocked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             identifier: "MT-562",
             issue: ^issue,
             token_policy: :no_codex,
             next_action: :needs_human,
             error: ":metadata_missing"
           } = Map.fetch!(Map.get(state, :external_waiting, %{}), issue_id)
  end

  test "stalled no-auto-Codex issue moves to external waiting without scheduling retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"],
      codex_stall_timeout_ms: 1
    )

    issue_id = "issue-merging-stall"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      state: "Merging",
      title: "Stalled while waiting for Codeup merge",
      description: "Do not retry Codex while waiting",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid) do
        send(worker_pid, :stop)
      end
    end)

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: "MT-565",
      issue: issue,
      retry_attempt: 1,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      last_codex_timestamp: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, blocked_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    refute Map.has_key?(blocked_state.running, issue_id)
    refute Map.has_key?(blocked_state.retry_attempts, issue_id)
    refute Map.has_key?(blocked_state.blocked, issue_id)
    assert MapSet.member?(blocked_state.claimed, issue_id)

    assert %{
             identifier: "MT-565",
             issue: ^issue,
             token_policy: :no_codex,
             next_action: :needs_human,
             error: ":metadata_missing"
           } = Map.fetch!(Map.get(blocked_state, :external_waiting, %{}), issue_id)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 38_000, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 8_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "external state change finalizes an external-waiting merge without retrying Codex" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      no_auto_codex_states: ["Merging"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-external-finalize"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      state: "Merging",
      title: "Finalize after Codeup merge",
      description: "External merge finalization must not resume Codex",
      labels: []
    }

    state = external_waiting_state_for_issue(issue)

    metadata = %{
      provider: "codeup",
      change_request_id: "3",
      from_state: "TO_BE_MERGED",
      to_state: "MERGED",
      status: "MERGED",
      revision: "8867ebd",
      observed_key: "codeup:org-123:6907286:3:MERGED:8867ebd",
      outcome: :merged,
      url: "https://codeup.example/change/3"
    }

    assert {:reply, %{queued: false, finalized: true, reason: :external_merged}, finalized_state} =
             Orchestrator.handle_call({:external_state_changed, issue_id, metadata}, {self(), make_ref()}, state)

    refute Map.has_key?(Map.get(finalized_state, :external_waiting, %{}), issue_id)
    refute MapSet.member?(finalized_state.claimed, issue_id)
    refute Map.has_key?(finalized_state.running, issue_id)
    refute Map.has_key?(finalized_state.retry_attempts, issue_id)
    assert finalized_state.codex_totals.total_tokens == 0

    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "External Merge Evidence"
    assert body =~ "MERGED"
    assert body =~ "token_policy: no_codex"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
  end

  test "manual resume wakes a blocked no-auto-Codex issue once" do
    issue_id = "issue-manual-resume"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-566",
      state: "Merging",
      title: "Human requested recheck",
      description: "Manual resume may run Codex once",
      labels: []
    }

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      blocked: %{
        issue_id => %{
          issue_id: issue_id,
          identifier: "MT-566",
          issue: issue,
          worker_host: nil,
          workspace_path: "/tmp/MT-566",
          session_id: "thread-turn",
          error: "automatic Codex dispatch suppressed for state Merging",
          blocked_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil
        }
      },
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, reason: :manual_resume}, resumed_state} =
             Orchestrator.handle_call({:manual_resume, issue_id}, {self(), make_ref()}, state)

    refute Map.has_key?(resumed_state.blocked, issue_id)

    assert %{
             attempt: 1,
             delay_type: :external,
             identifier: "MT-566",
             error: "manual resume requested",
             workspace_path: "/tmp/MT-566"
           } = resumed_state.retry_attempts[issue_id]
  end

  test "candidate no-auto-Codex issue is not dispatched by ordinary polling" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue = %Issue{
      id: "issue-merging-candidate",
      identifier: "MT-569",
      state: "Merging",
      title: "Do not dispatch from ordinary poll",
      description: "Waiting for external merge state",
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      max_concurrent_agents: 10
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "cold-start poll tracks candidate no-auto-Codex issue as external waiting without agent slots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue_id = "issue-cold-start-merging"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-570",
      state: "Merging",
      title: "Cold-start external wait",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)

    Application.put_env(
      :symphony_elixir,
      :external_merge_watcher_result,
      {:unchanged, %{observed_key: "codeup:org-123:6907286:3:TO_BE_MERGED:no-revision", provider: "codeup", change_request_id: "3", status: "TO_BE_MERGED", outcome: :active}}
    )

    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      max_concurrent_agents: 0,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert_receive {:external_merge_watcher_check, ^issue, opts}
    assert Keyword.get(opts, :fetch_tracker_comments) == true
    refute Map.has_key?(updated_state.running, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute Map.has_key?(updated_state.blocked, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)

    assert %{
             identifier: "MT-570",
             issue: ^issue,
             token_policy: :no_codex,
             cr_status: "TO_BE_MERGED",
             next_action: :wait
           } = Map.fetch!(Map.get(updated_state, :external_waiting, %{}), issue_id)
  end

  test "cold-start poll pauses new agent dispatch when process tree memory exceeds configured limit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-memory-dispatch-gate-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    running_pids = []

    on_exit(fn ->
      Enum.each(running_pids, fn pid ->
        if is_pid(pid) and Process.alive?(pid) do
          Process.exit(pid, :shutdown)
        end
      end)

      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 6 * 1024 * 1024, command: "beam.smp"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: test_root,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024
    )

    issue = %Issue{
      id: "issue-memory-gated",
      identifier: "MT-MEM-GATE",
      state: "Todo",
      title: "Memory gated dispatch",
      description: "",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert updated_state.running == %{}
    assert updated_state.claimed == MapSet.new()
    refute File.exists?(Path.join(test_root, "MT-MEM-GATE"))
  end

  test "poll stops the oldest running agent for retry when process tree memory exceeds configured limit" do
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
    end)

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 6 * 1024 * 1024, command: "beam.smp"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024
    )

    issue_id = "issue-memory-pressure"

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> terminate_test_pids([worker_pid]) end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-MEM-PRESSURE",
      state: "In Progress",
      title: "Memory pressure running issue",
      description: "",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    running_entry = %{
      pid: worker_pid,
      ref: Process.monitor(worker_pid),
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 0,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      blocked: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)

    assert %{
             attempt: 1,
             identifier: "MT-MEM-PRESSURE",
             error: "process tree memory limit exceeded: 6442450944 bytes >= 5368709120 bytes"
           } = Map.fetch!(updated_state.retry_attempts, issue_id)

    refute Process.alive?(worker_pid)
  end

  test "poll ignores workspace preview memory when enforcing process tree limit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-memory-pressure-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    workspace_path = Path.join(test_root, "MT-WORKSPACE-MEM")
    File.mkdir_p!(Path.join(workspace_path, ".symphony"))
    File.write!(Path.join([workspace_path, ".symphony", "powerchat.pid"]), "90000\n")

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 128 * 1024, command: "beam.smp"},
      %{pid: 90_000, ppid: 1, rss_kb: 3 * 1024 * 1024, command: "sh"},
      %{pid: 90_001, ppid: 90_000, rss_kb: 3 * 1024 * 1024, command: "agy"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024
    )

    issue_id = "issue-workspace-memory-pressure"

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> terminate_test_pids([worker_pid]) end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-WORKSPACE-MEM",
      state: "In Progress",
      title: "Workspace memory pressure running issue",
      description: "",
      labels: []
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    running_entry = %{
      pid: worker_pid,
      ref: Process.monitor(worker_pid),
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 0,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      workspace_path: workspace_path,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      blocked: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    assert Process.alive?(worker_pid)
  end

  test "memory watchdog stops the oldest running agent for retry without polling tracker" do
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_issues_file = Application.get_env(:symphony_elixir, :memory_tracker_issues_file)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:memory_tracker_issues_file, previous_issues_file)
    end)

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 6 * 1024 * 1024, command: "beam.smp"}
    ])

    Application.put_env(:symphony_elixir, :memory_tracker_issues_file, "/tmp/symphony-watchdog-must-not-read.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      memory_watchdog_interval_ms: 1_000
    )

    issue_id = "issue-memory-watchdog"

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> terminate_test_pids([worker_pid]) end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-MEM-WATCHDOG",
      state: "In Progress",
      title: "Memory watchdog running issue",
      description: "",
      labels: []
    }

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 0,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      blocked: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      memory_watchdog_timer_ref: make_ref(),
      memory_watchdog_token: watchdog_token = make_ref(),
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info({:memory_watchdog, watchdog_token}, state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    assert is_reference(updated_state.memory_watchdog_timer_ref)
    assert is_reference(updated_state.memory_watchdog_token)

    assert %{
             attempt: 1,
             identifier: "MT-MEM-WATCHDOG",
             error: "process tree memory limit exceeded: 6442450944 bytes >= 5368709120 bytes"
           } = Map.fetch!(updated_state.retry_attempts, issue_id)

    refute Process.alive?(worker_pid)
  end

  test "memory watchdog ignores workspace preview memory when enforcing process tree limit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-memory-watchdog-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    workspace_path = Path.join(test_root, "MT-WATCHDOG-WORKSPACE-MEM")
    File.mkdir_p!(Path.join(workspace_path, ".symphony"))
    File.write!(Path.join([workspace_path, ".symphony", "powerchat.pid"]), "92000\n")

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 128 * 1024, command: "beam.smp"},
      %{pid: 92_000, ppid: 1, rss_kb: 3 * 1024 * 1024, command: "sh"},
      %{pid: 92_001, ppid: 92_000, rss_kb: 3 * 1024 * 1024, command: "agy"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      memory_watchdog_interval_ms: 1_000
    )

    issue_id = "issue-memory-watchdog-preview"

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> terminate_test_pids([worker_pid]) end)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-WATCHDOG-WORKSPACE-MEM",
      state: "In Progress",
      title: "Memory watchdog ignores workspace preview",
      description: "",
      labels: []
    }

    running_entry = %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 0,
      started_at: DateTime.add(DateTime.utc_now(), -10, :second),
      workspace_path: workspace_path,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }

    state = %Orchestrator.State{
      running: %{issue_id => running_entry},
      blocked: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{},
      memory_watchdog_timer_ref: make_ref(),
      memory_watchdog_token: watchdog_token = make_ref(),
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info({:memory_watchdog, watchdog_token}, state)

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    assert Process.alive?(worker_pid)
  end

  test "poll cycle does not postpone an already scheduled memory watchdog" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      poll_interval_ms: 500,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      memory_watchdog_interval_ms: 1_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    watchdog_token = make_ref()
    watchdog_timer_ref = Process.send_after(self(), {:memory_watchdog, watchdog_token}, 60_000)

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      memory_watchdog_timer_ref: watchdog_timer_ref,
      memory_watchdog_token: watchdog_token,
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    on_exit(fn ->
      if is_reference(updated_state.tick_timer_ref), do: Process.cancel_timer(updated_state.tick_timer_ref)
      Process.cancel_timer(watchdog_timer_ref)
    end)

    assert updated_state.memory_watchdog_timer_ref == watchdog_timer_ref
    assert updated_state.memory_watchdog_token == watchdog_token
  end

  test "cold-start poll reserves process tree memory per new dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-memory-dispatch-reservation-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 4 * 1024 * 1024, command: "beam.smp"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: test_root,
      max_concurrent_agents: 10,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      dispatch_rss_reservation_bytes: 512 * 1024 * 1024
    )

    issues =
      for index <- 1..3 do
        %Issue{
          id: "issue-memory-reserved-#{index}",
          identifier: "MT-MEM-#{index}",
          state: "Todo",
          title: "Memory reserved dispatch #{index}",
          description: "",
          labels: []
        }
      end

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    running_pids =
      updated_state.running
      |> Map.values()
      |> Enum.map(&Map.get(&1, :pid))

    on_exit(fn -> terminate_test_pids(running_pids) end)

    assert map_size(updated_state.running) == 2
    assert MapSet.size(updated_state.claimed) == 2
    assert Map.has_key?(updated_state.running, "issue-memory-reserved-1")
    assert Map.has_key?(updated_state.running, "issue-memory-reserved-2")
    refute Map.has_key?(updated_state.running, "issue-memory-reserved-3")
    assert MapSet.member?(updated_state.claimed, "issue-memory-reserved-1")
    assert MapSet.member?(updated_state.claimed, "issue-memory-reserved-2")
    refute MapSet.member?(updated_state.claimed, "issue-memory-reserved-3")

    terminate_test_pids(running_pids)
  end

  test "PowerChat Antigravity workflow dispatches ten issues with a 1GiB Symphony RSS baseline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-powerchat-agy-ten-dispatch-budget-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    try do
      workflow_path = Path.expand("WORKFLOW.en.powerchat-agy.md", File.cwd!())
      assert {:ok, %{config: workflow_config}} = Workflow.load(workflow_path)

      workspace_root = Path.join(test_root, "workspaces")
      fake_agy = Path.join(test_root, "fake-agy-dispatch-budget")
      File.mkdir_p!(workspace_root)

      File.write!(fake_agy, """
      #!/bin/sh
      log_file=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --log-file=*)
            log_file="${1#--log-file=}"
            ;;
        esac
        shift
      done

      mkdir -p "$(dirname "$log_file")"
      printf 'I0601 server.go:755] Created conversation agy-budget-%s\\n' "$$" >> "$log_file"
      sleep 30
      """)

      File.chmod!(fake_agy, 0o755)

      symphony_pid = System.pid() |> String.to_integer()

      Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
        %{pid: symphony_pid, ppid: 1, rss_kb: 1 * 1024 * 1024, command: "beam.smp"}
      ])

      issues =
        for index <- 1..10 do
          %Issue{
            id: "issue-powerchat-agy-dispatch-budget-#{index}",
            identifier: "MT-AGY-BUDGET-#{index}",
            state: "In Progress",
            title: "PowerChat AGY dispatch budget #{index}",
            description: "",
            labels: []
          }
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 60_000,
        max_concurrent_agents: get_in(workflow_config, ["agent", "max_concurrent_agents"]),
        max_process_tree_rss_bytes: get_in(workflow_config, ["agent", "max_process_tree_rss_bytes"]),
        dispatch_rss_reservation_bytes: get_in(workflow_config, ["agent", "dispatch_rss_reservation_bytes"]),
        observability_terminal_dashboard_enabled: false
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      state = %Orchestrator.State{
        running: %{},
        blocked: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        codex_rate_limits: nil
      }

      assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

      running_pids =
        updated_state.running
        |> Map.values()
        |> Enum.map(&Map.get(&1, :pid))

      on_exit(fn -> terminate_test_pids(running_pids) end)

      assert map_size(updated_state.running) == 10
      assert MapSet.size(updated_state.claimed) == 10

      terminate_test_pids(running_pids)
    after
      File.rm_rf(test_root)
    end
  end

  test "poll ignores workspace preview memory when reserving dispatch memory" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-preview-memory-dispatch-reservation-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(test_root)
    end)

    workspace_path = Path.join(test_root, "MT-RUNNING-PREVIEW")
    File.mkdir_p!(Path.join(workspace_path, ".symphony"))
    File.write!(Path.join([workspace_path, ".symphony", "powerchat.pid"]), "91000\n")

    symphony_pid = System.pid() |> String.to_integer()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 4 * 1024 * 1024, command: "beam.smp"},
      %{pid: 91_000, ppid: 1, rss_kb: 3 * 1024 * 1024, command: "sh"},
      %{pid: 91_001, ppid: 91_000, rss_kb: 3 * 1024 * 1024, command: "agy"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      workspace_root: test_root,
      max_concurrent_agents: 10,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      dispatch_rss_reservation_bytes: 512 * 1024 * 1024
    )

    running_issue = %Issue{
      id: "issue-running-preview",
      identifier: "MT-RUNNING-PREVIEW",
      state: "In Progress",
      title: "Running issue with preview memory",
      description: "",
      labels: []
    }

    candidate_issue = %Issue{
      id: "issue-preview-ignored-dispatch",
      identifier: "MT-PREVIEW-IGNORED-DISPATCH",
      state: "Todo",
      title: "Dispatch despite preview memory",
      description: "",
      labels: []
    }

    running_worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> terminate_test_pids([running_worker_pid]) end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [running_issue, candidate_issue])

    state = %Orchestrator.State{
      running: %{
        running_issue.id => %{
          pid: running_worker_pid,
          ref: make_ref(),
          identifier: running_issue.identifier,
          issue: running_issue,
          retry_attempt: 0,
          started_at: DateTime.add(DateTime.utc_now(), -10, :second),
          workspace_path: workspace_path,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0
        }
      },
      blocked: %{},
      claimed: MapSet.new([running_issue.id]),
      retry_attempts: %{},
      max_concurrent_agents: 10,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    running_pids =
      updated_state.running
      |> Map.values()
      |> Enum.map(&Map.get(&1, :pid))

    on_exit(fn -> terminate_test_pids(running_pids) end)

    assert Map.has_key?(updated_state.running, running_issue.id)
    assert Map.has_key?(updated_state.running, candidate_issue.id)
    refute Map.has_key?(updated_state.retry_attempts, running_issue.id)
    refute Map.has_key?(updated_state.retry_attempts, candidate_issue.id)
    assert Process.alive?(running_worker_pid)

    terminate_test_pids(running_pids)
  end

  @tag timeout: 40_000
  test "cold-start poll dispatches ten Antigravity CLI issues in parallel with bounded memory" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-antigravity-memory-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_agy = Path.join(test_root, "fake-agy-orchestrator-memory")
      started_file = Path.join(test_root, "started.txt")
      release_file = Path.join(test_root, "release.flag")
      released_file = Path.join(test_root, "released.txt")

      File.mkdir_p!(workspace_root)
      File.write!(started_file, "")
      File.write!(released_file, "")

      File.write!(fake_agy, """
      #!/bin/sh
      log_file=""
      issue_identifier=""
      started_file='#{started_file}'
      release_file='#{release_file}'
      released_file='#{released_file}'
      expected="10"
      stdout_bytes=2000000
      log_bytes=2000000

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --log-file=*)
            log_file="${1#--log-file=}"
            ;;
          --add-dir)
            shift
            issue_identifier="$(basename "$1")"
            ;;
        esac
        shift
      done

      printf 'started\\n' >> "$started_file"

      for _ in $(seq 1 100); do
        if [ -f "$release_file" ]; then
          break
        fi
        sleep 0.05
      done

      count=$(wc -l < "$started_file" 2>/dev/null | tr -d ' ')
      printf 'released:%s:%s\\n' "${issue_identifier:-unknown}" "${count:-0}" >> "$released_file"

      mkdir -p "$(dirname "$log_file")"
      python3 - "$log_file" "$log_bytes" <<'PY'
      import os
      import sys

      path = sys.argv[1]
      size = int(sys.argv[2])

      with open(path, "ab") as log:
          log.write(f"I0601 server.go:755] Created conversation agy-orch-{os.getpid()}\\n".encode())
          log.write(b"L" * size)
          log.write(b"\\nlog-tail\\n")
      PY

      python3 - "$stdout_bytes" <<'PY'
      import sys

      size = int(sys.argv[1])
      sys.stdout.buffer.write(b"start-marker\\n")
      sys.stdout.buffer.write(b"x" * size)
      sys.stdout.buffer.write(b"\\ntail-marker\\n")
      PY
      """)

      File.chmod!(fake_agy, 0o755)

      symphony_pid = System.pid() |> String.to_integer()

      Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
        %{pid: symphony_pid, ppid: 1, rss_kb: 128 * 1024, command: "beam.smp"}
      ])

      issues =
        for index <- 1..10 do
          %Issue{
            id: "issue-orchestrator-antigravity-memory-#{index}",
            identifier: "MT-AGY-ORCH-#{index}",
            state: "In Progress",
            title: "Orchestrator Antigravity memory #{index}",
            description: "Run a bounded Antigravity CLI turn",
            labels: []
          }
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 15_000,
        max_concurrent_agents: 10,
        max_turns: 1,
        observability_terminal_dashboard_enabled: false
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      before_memory = core_memory_snapshot()

      state = %Orchestrator.State{
        running: %{},
        blocked: %{},
        claimed: MapSet.new(),
        retry_attempts: %{},
        max_concurrent_agents: 10,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        codex_rate_limits: nil
      }

      assert {:noreply, dispatched_state} = Orchestrator.handle_info(:run_poll_cycle, state)
      assert map_size(dispatched_state.running) == 10

      assert wait_for_file_line_count(started_file, 10, 5_000)
      File.write!(release_file, "release\n")
      assert wait_for_file_line_count(released_file, 10, 5_000)

      release_counts =
        released_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(fn "released:" <> entry ->
          [identifier, count] = String.split(entry, ":", parts: 2)
          {identifier, String.to_integer(count)}
        end)
        |> Enum.uniq_by(fn {identifier, _count} -> identifier end)

      assert length(release_counts) == 10
      assert Enum.all?(release_counts, fn {_identifier, count} -> count == 10 end)

      for _ <- 1..10 do
        assert_receive {:DOWN, _ref, :process, _pid, :normal}, 30_000
      end

      messages = drain_core_stress_messages([])
      stdout_messages = Enum.filter(messages, &(&1.method == "antigravity_cli/event/stdout"))
      log_messages = Enum.filter(messages, &(&1.method == "antigravity_cli/event/log"))

      assert length(stdout_messages) == 10
      assert length(log_messages) >= 10

      assert Enum.all?(stdout_messages, fn message ->
               message.text_bytes >= 2_000_000 and
                 message.text_truncated == true and
                 message.text_size <= 65_536 and
                 message.text_referenced <= 65_536 and
                 message.raw_size <= 65_536 and
                 message.raw_referenced <= 65_536
             end)

      assert Enum.all?(log_messages, fn message ->
               message.text_bytes >= 16_384 and
                 message.text_truncated == true and
                 message.text_size <= 16_384 and
                 message.text_referenced <= 16_384 and
                 message.raw_size <= 16_384 and
                 message.raw_referenced <= 16_384
             end)

      after_memory = core_memory_snapshot()

      assert after_memory.total < 5 * 1024 * 1024 * 1024
      assert after_memory.binary < 256 * 1024 * 1024
      assert after_memory.total - before_memory.total < 512 * 1024 * 1024
    after
      File.rm_rf(test_root)
    end
  end

  test "cold-start poll runs external-waiting start hook once and keeps workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-external-waiting-start-hook-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-external-waiting-start-hook"
    issue_identifier = "MT-570-HOOK"
    workspace = Path.join(test_root, issue_identifier)
    hook_marker = Path.join(test_root, "external-waiting-start.log")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "artifact.txt"), "preview stays until merge finalization")

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      workspace_root: test_root,
      no_auto_codex_states: ["Merging"],
      hook_after_external_waiting_start: "basename \"$PWD\" >> \"#{hook_marker}\""
    )

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "Merging",
      title: "Start external waiting hook",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:TO_BE_MERGED:rev-hook",
      provider: "codeup",
      change_request_id: "3",
      status: "TO_BE_MERGED",
      revision: "rev-hook",
      outcome: :open,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:unchanged, observation})

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      max_concurrent_agents: 0,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert File.read!(hook_marker) == "#{issue_identifier}\n"
    assert File.dir?(workspace)
    assert File.read!(Path.join(workspace, "artifact.txt")) == "preview stays until merge finalization"

    assert %{
             identifier: ^issue_identifier,
             token_policy: :no_codex,
             cr_status: "TO_BE_MERGED",
             next_action: :wait
           } = Map.fetch!(Map.get(updated_state, :external_waiting, %{}), issue_id)

    assert {:noreply, polled_again_state} = Orchestrator.handle_info(:run_poll_cycle, updated_state)
    assert File.read!(hook_marker) == "#{issue_identifier}\n"
    assert Map.has_key?(Map.get(polled_again_state, :external_waiting, %{}), issue_id)
  end

  test "cold-start poll finalizes already-merged Codeup CR without Codex retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      no_auto_codex_states: ["Merging"]
    )

    issue_id = "issue-cold-start-already-merged"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-572",
      state: "Merging",
      title: "Cold-start merged external wait",
      description: codeup_metadata_description("MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:MERGED:rev-cold-start",
      provider: "codeup",
      change_request_id: "3",
      status: "MERGED",
      revision: "rev-cold-start",
      outcome: :merged,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:unchanged, observation})
    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      max_concurrent_agents: 0,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert_receive {:external_merge_watcher_check, ^issue, _opts}
    refute Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
    refute Map.has_key?(updated_state.running, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    assert updated_state.codex_totals.total_tokens == 0
    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "External Merge Evidence"
    assert body =~ "rev-cold-start"
    assert body =~ "token_policy: no_codex"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
  end

  test "external-waiting no-auto-Codex issue records unchanged Codeup CR observation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue_id = "issue-codeup-unchanged"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-567",
      state: "Merging",
      title: "Await unchanged Codeup merge",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:unchanged, %{observed_key: "codeup:org-123:6907286:3:TO_BE_MERGED:2026-05-30T10:00:00Z"}})
    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = external_waiting_state_for_issue(issue)

    updated_state = Orchestrator.reconcile_external_waiting_issue_states_for_test([issue], state)

    assert_receive {:external_merge_watcher_check, ^issue, opts}
    assert Keyword.get(opts, :observed_key) == nil
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute Map.has_key?(updated_state.blocked, issue_id)
    assert Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)

    assert updated_state.external_observations[issue_id] ==
             "codeup:org-123:6907286:3:TO_BE_MERGED:2026-05-30T10:00:00Z"

    assert %{
             cr_status: "TO_BE_MERGED",
             observed_key: "codeup:org-123:6907286:3:TO_BE_MERGED:2026-05-30T10:00:00Z",
             token_policy: :no_codex,
             next_action: :wait
           } = Map.fetch!(Map.get(updated_state, :external_waiting, %{}), issue_id)
  end

  test "operator-blocked no-auto-Codex issue remains blocked instead of becoming external waiting" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue_id = "issue-operator-blocked-merging"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-571",
      state: "Merging",
      title: "Human input still needed",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    state =
      blocked_state_for_issue(issue)
      |> put_in([Access.key!(:blocked), issue_id, :error], "codex turn requires operator input")
      |> Map.put(:external_waiting, %{})

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.blocked, issue_id)
    refute Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
  end

  test "external-waiting no-auto-Codex issue finalizes merged Codeup CR without retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      no_auto_codex_states: ["Merging"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-codeup-merged"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-568",
      state: "Merging",
      title: "Wake after Codeup merge",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:MERGED:8867ebd9c0ffee",
      status: "MERGED",
      revision: "8867ebd9c0ffee"
    }

    event_metadata = %{
      provider: "codeup",
      change_request_id: "3",
      from_state: "TO_BE_MERGED",
      to_state: "MERGED",
      status: "MERGED",
      revision: "8867ebd9c0ffee",
      observed_key: observation.observed_key,
      outcome: :merged,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:changed, observation, event_metadata})
    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = external_waiting_state_for_issue(issue)

    updated_state = Orchestrator.reconcile_external_waiting_issue_states_for_test([issue], state)

    assert_receive {:external_merge_watcher_check, ^issue, _opts}
    refute Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
    refute Map.has_key?(updated_state.blocked, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    assert updated_state.external_observations[issue_id] == observation.observed_key

    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "External Merge Evidence"
    assert body =~ "MERGED"
    assert body =~ "8867ebd9c0ffee"
    assert body =~ "token_policy: no_codex"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Done"}
  end

  test "external-waiting no-auto-Codex issue cleans workspace and remains visible after merged Codeup CR finalizes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-external-wait-cleanup-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-codeup-merged-cleanup"
    issue_identifier = "MT-568-CLEANUP"
    workspace = Path.join(test_root, issue_identifier)
    before_remove_marker = Path.join(test_root, "before-remove.log")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "artifact.txt"), "kept until external merge finalizes")

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      workspace_root: test_root,
      no_auto_codex_states: ["Merging"],
      hook_before_remove: "basename \"$PWD\" > \"#{before_remove_marker}\""
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "Merging",
      title: "Clean workspace after external merge",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:MERGED:8867ebd9c0ffee",
      status: "MERGED",
      revision: "8867ebd9c0ffee"
    }

    event_metadata = %{
      provider: "codeup",
      change_request_id: "3",
      from_state: "TO_BE_MERGED",
      to_state: "MERGED",
      status: "MERGED",
      revision: "8867ebd9c0ffee",
      observed_key: observation.observed_key,
      outcome: :merged,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:changed, observation, event_metadata})
    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = external_waiting_state_for_issue(issue)

    updated_state = Orchestrator.reconcile_external_waiting_issue_states_for_test([issue], state)

    assert_receive {:external_merge_watcher_check, ^issue, _opts}
    refute Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
    refute Map.has_key?(updated_state.running, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute File.exists?(workspace)
    assert String.trim(File.read!(before_remove_marker)) == issue_identifier

    assert %{
             identifier: ^issue_identifier,
             provider: "codeup",
             change_request_id: "3",
             cr_status: "MERGED",
             revision: "8867ebd9c0ffee",
             target_state: "Done",
             reason: :external_merged,
             workspace_cleanup: :ok
           } = Map.fetch!(updated_state.recent_external_finalizations, issue_id)
  end

  test "external-waiting finalization failure keeps workspace and wait entry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-external-wait-finalize-failure-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-codeup-finalize-failure"
    issue_identifier = "MT-568-FINALIZE-FAIL"
    workspace = Path.join(test_root, issue_identifier)
    before_remove_marker = Path.join(test_root, "before-remove.log")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "artifact.txt"), "must remain when tracker finalization fails")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      workspace_root: test_root,
      no_auto_codex_states: ["Merging"],
      hook_before_remove: "basename \"$PWD\" > \"#{before_remove_marker}\""
    )

    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.FailingLinearClient)

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      state: "Merging",
      title: "Keep workspace when finalization write fails",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:MERGED:8867ebd9c0ffee",
      status: "MERGED",
      revision: "8867ebd9c0ffee"
    }

    event_metadata = %{
      provider: "codeup",
      change_request_id: "3",
      from_state: "TO_BE_MERGED",
      to_state: "MERGED",
      status: "MERGED",
      revision: "8867ebd9c0ffee",
      observed_key: observation.observed_key,
      outcome: :merged,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:changed, observation, event_metadata})

    state = external_waiting_state_for_issue(issue)

    updated_state = Orchestrator.reconcile_external_waiting_issue_states_for_test([issue], state)

    assert Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
    assert updated_state.external_waiting[issue_id].next_action == :needs_human
    assert updated_state.external_waiting[issue_id].error =~ "tracker_comment_failed"
    assert File.exists?(workspace)
    refute File.exists?(before_remove_marker)
    refute Map.has_key?(updated_state.recent_external_finalizations, issue_id)
  end

  test "snapshot prunes stale recent external finalizations without releasing active waits" do
    old_issue_id = "issue-recent-old"
    fresh_issue_id = "issue-recent-fresh"
    waiting_issue_id = "issue-still-waiting"

    old_issue = %Issue{id: old_issue_id, identifier: "MT-OLD", state: "Merging", title: "Old recent", labels: []}
    fresh_issue = %Issue{id: fresh_issue_id, identifier: "MT-FRESH", state: "Merging", title: "Fresh recent", labels: []}
    waiting_issue = %Issue{id: waiting_issue_id, identifier: "MT-WAIT", state: "Merging", title: "Still waiting", labels: []}

    state = %Orchestrator.State{
      claimed: MapSet.new([waiting_issue_id]),
      external_waiting: %{
        waiting_issue_id => %{
          issue_id: waiting_issue_id,
          identifier: waiting_issue.identifier,
          issue: waiting_issue,
          token_policy: :no_codex,
          next_action: :wait
        }
      },
      recent_external_finalizations: %{
        old_issue_id =>
          recent_external_finalization_state_entry(
            old_issue_id,
            old_issue,
            DateTime.add(DateTime.utc_now(), -601, :second)
          ),
        fresh_issue_id => recent_external_finalization_state_entry(fresh_issue_id, fresh_issue, DateTime.utc_now())
      },
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, snapshot, pruned_state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)

    refute Map.has_key?(pruned_state.recent_external_finalizations, old_issue_id)
    assert Map.has_key?(pruned_state.recent_external_finalizations, fresh_issue_id)
    assert Map.has_key?(pruned_state.external_waiting, waiting_issue_id)
    assert MapSet.member?(pruned_state.claimed, waiting_issue_id)

    refute Enum.any?(snapshot.recent_external_finalizations, &(&1.issue_id == old_issue_id))
    assert Enum.any?(snapshot.recent_external_finalizations, &(&1.issue_id == fresh_issue_id))
    assert Enum.any?(snapshot.external_waiting, &(&1.issue_id == waiting_issue_id))
  end

  test "counts snapshot exposes lightweight observability fields without running message payloads" do
    issue_id = "issue-counts"
    issue = %Issue{id: issue_id, identifier: "MT-COUNTS", state: "In Progress", title: "Counts", labels: []}

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          identifier: issue.identifier,
          issue: issue,
          workspace_path: "/tmp/MT-COUNTS",
          last_codex_message: String.duplicate("large-message", 1_000),
          started_at: DateTime.utc_now()
        }
      },
      blocked: %{
        "issue-blocked" => %{
          identifier: "MT-BLOCKED",
          issue: %Issue{id: "issue-blocked", identifier: "MT-BLOCKED", state: "In Progress", title: "Blocked", labels: []}
        }
      },
      external_waiting: %{
        "issue-external" => %{
          identifier: "MT-EXTERNAL",
          issue: %Issue{id: "issue-external", identifier: "MT-EXTERNAL", state: "Merging", title: "External", labels: []}
        }
      },
      retry_attempts: %{
        "issue-retry" => %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 1_000}
      },
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, snapshot, _state} = Orchestrator.handle_call(:counts_snapshot, {self(), make_ref()}, state)

    assert snapshot == %{
             counts: %{running: 1, retrying: 1, blocked: 1, external_waiting: 1},
             running_preview_workspaces: ["/tmp/MT-COUNTS"]
           }
  end

  test "external-waiting no-auto-Codex issue moves terminal failed Codeup CR to Rework without retry" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging", "Rework"],
      tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
      no_auto_codex_states: ["Merging"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue_id = "issue-codeup-closed"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-573",
      state: "Merging",
      title: "Rework after Codeup close",
      description: codeup_metadata_description("TO_BE_MERGED"),
      labels: []
    }

    observation = %{
      observed_key: "codeup:org-123:6907286:3:CLOSED:2026-05-30T11:00:00Z",
      status: "CLOSED",
      revision: nil,
      outcome: :terminal_failure,
      provider: "codeup",
      change_request_id: "3"
    }

    event_metadata = %{
      provider: "codeup",
      change_request_id: "3",
      from_state: "TO_BE_MERGED",
      to_state: "CLOSED",
      status: "CLOSED",
      revision: nil,
      observed_key: observation.observed_key,
      outcome: :terminal_failure,
      url: "https://codeup.example/change/3"
    }

    Application.put_env(:symphony_elixir, :external_merge_watcher, __MODULE__.FakeExternalMergeWatcher)
    Application.put_env(:symphony_elixir, :external_merge_watcher_result, {:changed, observation, event_metadata})
    Application.put_env(:symphony_elixir, :external_merge_watcher_recipient, self())

    state = external_waiting_state_for_issue(issue)

    updated_state = Orchestrator.reconcile_external_waiting_issue_states_for_test([issue], state)

    assert_receive {:external_merge_watcher_check, ^issue, _opts}
    refute Map.has_key?(Map.get(updated_state, :external_waiting, %{}), issue_id)
    refute Map.has_key?(updated_state.blocked, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
    refute MapSet.member?(updated_state.completed, issue_id)

    assert_receive {:memory_tracker_comment, ^issue_id, body}
    assert body =~ "External Merge Evidence"
    assert body =~ "CLOSED"
    assert body =~ "target_linear_state: Rework"
    assert body =~ "reason: external_terminal_failure"
    assert body =~ "token_policy: no_codex"
    assert_receive {:memory_tracker_state_update, ^issue_id, "Rework"}
  end

  defmodule FakeExternalMergeWatcher do
    def check_issue(issue, opts) do
      case Application.get_env(:symphony_elixir, :external_merge_watcher_recipient) do
        pid when is_pid(pid) -> send(pid, {:external_merge_watcher_check, issue, opts})
        _ -> :ok
      end

      Application.fetch_env!(:symphony_elixir, :external_merge_watcher_result)
    end
  end

  defmodule FailingLinearClient do
    def graphql(query, _variables) when is_binary(query) do
      if String.contains?(query, "commentCreate") do
        {:error, :tracker_comment_failed}
      else
        {:error, :unexpected_graphql_call}
      end
    end
  end

  defmodule LargeAntigravityProvider do
    @behaviour SymphonyElixir.AgentProvider

    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)
      large_output = Application.fetch_env!(:symphony_elixir, :agent_runner_large_antigravity_output)

      on_message.(%{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          payload: %{
            "method" => "antigravity_cli/event/stdout",
            "params" => %{
              "text" => large_output,
              "stderr" => "",
              "conversation_id" => "agy-large",
              "log_file" => "/tmp/agy-large.log"
            }
          },
          raw: large_output
        }
      })

      on_message.(%{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          payload: %{
            "method" => "antigravity_cli/event/log",
            "params" => %{
              "text" => large_output,
              "conversation_id" => "agy-large",
              "turn_id" => "agy-turn-large",
              "log_file" => "/tmp/agy-large.log"
            }
          },
          raw: large_output
        }
      })

      {:ok, %{session_id: "agy-large-turn", thread_id: "agy-large", turn_id: "agy-turn-large"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule ChattyAntigravityProvider do
    @behaviour SymphonyElixir.AgentProvider

    def start_session(workspace, _opts), do: {:ok, %{workspace: workspace}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)
      log_count = Application.get_env(:symphony_elixir, :agent_runner_chatty_antigravity_log_count, 100)
      turn_count = Process.get(:chatty_antigravity_provider_turn_count, 0) + 1
      Process.put(:chatty_antigravity_provider_turn_count, turn_count)
      turn_id = "agy-turn-chatty-#{turn_count}"

      for index <- 1..log_count do
        on_message.(%{
          event: :notification,
          timestamp: DateTime.utc_now(),
          payload: %{
            payload: %{
              "method" => "antigravity_cli/event/log",
              "params" => %{
                "text" => "chatty turn #{turn_count} log #{index}",
                "conversation_id" => "agy-chatty",
                "turn_id" => turn_id,
                "log_file" => "/tmp/agy-chatty.log"
              }
            },
            raw: "chatty turn #{turn_count} log #{index}"
          }
        })
      end

      on_message.(%{
        event: :turn_completed,
        timestamp: DateTime.utc_now(),
        payload: %{"result" => "turn_completed", "turn_id" => turn_id},
        raw: ""
      })

      {:ok, %{session_id: "agy-chatty-turn-#{turn_count}", thread_id: "agy-chatty", turn_id: turn_id}}
    end

    def stop_session(_session), do: :ok
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms - 500
    assert remaining_ms <= max_remaining_ms
  end

  defp terminate_test_pids(pids) when is_list(pids) do
    Enum.each(pids, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)
  end

  defp receive_codex_worker_updates(issue_id, expected_count, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_codex_worker_updates(issue_id, expected_count, deadline_ms, [])
  end

  defp do_receive_codex_worker_updates(_issue_id, 0, _deadline_ms, updates), do: Enum.reverse(updates)

  defp do_receive_codex_worker_updates(issue_id, remaining, deadline_ms, updates) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:codex_worker_update, ^issue_id, update} ->
        do_receive_codex_worker_updates(issue_id, remaining - 1, deadline_ms, [update | updates])
    after
      timeout_ms ->
        Enum.reverse(updates)
    end
  end

  defp drain_codex_worker_updates(issue_id, updates) do
    receive do
      {:codex_worker_update, ^issue_id, update} ->
        drain_codex_worker_updates(issue_id, [update | updates])
    after
      50 ->
        Enum.reverse(updates)
    end
  end

  defp leaked_antigravity_log_throttle_agents(existing_pids) do
    Process.list()
    |> Enum.reject(&MapSet.member?(existing_pids, &1))
    |> Enum.filter(&antigravity_log_throttle_agent?/1)
  end

  defp antigravity_log_throttle_agent?(pid) when is_pid(pid) do
    case :sys.get_state(pid, 10) do
      %{last_antigravity_log_sent_at_ms: value} when is_integer(value) -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp continuation_state_fetcher(issue, states) when is_list(states) do
    {:ok, state_agent} = Agent.start_link(fn -> states end)

    fn [_issue_id] ->
      state =
        Agent.get_and_update(state_agent, fn
          [state | rest] -> {state, rest}
          [] -> {List.last(states), []}
        end)

      {:ok, [%{issue | state: state}]}
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp blocked_state_for_issue(%Issue{} = issue) do
    %Orchestrator.State{
      claimed: MapSet.new([issue.id]),
      blocked: %{
        issue.id => %{
          issue_id: issue.id,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: "/tmp/#{issue.identifier}",
          session_id: "thread-turn",
          error: "automatic Codex dispatch suppressed for state #{issue.state}",
          blocked_at: DateTime.utc_now(),
          last_codex_message: nil,
          last_codex_event: nil,
          last_codex_timestamp: nil
        }
      },
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }
    |> Map.put(:external_observations, %{})
  end

  defp external_waiting_state_for_issue(%Issue{} = issue) do
    %Orchestrator.State{
      running: %{},
      blocked: %{},
      claimed: MapSet.new([issue.id]),
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }
    |> Map.put(:external_observations, %{})
    |> Map.put(:external_waiting, %{
      issue.id => %{
        issue_id: issue.id,
        identifier: issue.identifier,
        issue: issue,
        provider: "codeup",
        change_request_id: "3",
        token_policy: :no_codex,
        cr_status: nil,
        observed_key: nil,
        next_action: :wait,
        error: nil,
        waiting_since: DateTime.utc_now(),
        last_checked_at: nil
      }
    })
  end

  defp codeup_metadata_description(last_observed_status) do
    metadata =
      %{
        provider: "codeup",
        domain: "openapi-rdc.aliyuncs.com",
        organization_id: "org-123",
        repo_id: "6907286",
        change_request_id: 3,
        source_branch: "fir-15-update-start-copy",
        target_branch: "master",
        delivery_commit: "fde329cfb8f523300f6066085f4c0a7ec0712c8c",
        last_observed_cr_state: last_observed_status
      }

    """
    ## Codex Workpad

    ### Delivery Metadata

    ```json
    #{Jason.encode!(metadata, pretty: true)}
    ```
    """
  end

  defp recent_external_finalization_state_entry(issue_id, %Issue{} = issue, finalized_at) do
    %{
      issue_id: issue_id,
      identifier: issue.identifier,
      issue: issue,
      state: issue.state,
      provider: "codeup",
      change_request_id: "3",
      cr_status: "MERGED",
      revision: "rev-#{issue_id}",
      observed_key: "codeup:org-123:6907286:3:MERGED:rev-#{issue_id}",
      target_state: "Done",
      reason: :external_merged,
      token_policy: :no_codex,
      workspace_cleanup: :ok,
      finalized_at: finalized_at,
      url: "https://codeup.example/change/3"
    }
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "external-event waiting state after human approval"
    assert prompt =~ "do not poll or retry from Codex"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner compacts Antigravity CLI updates before sending them to orchestrator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-compact-antigravity-#{System.unique_integer([:positive])}"
      )

    previous_large_output = Application.get_env(:symphony_elixir, :agent_runner_large_antigravity_output)

    on_exit(fn ->
      restore_app_env(:agent_runner_large_antigravity_output, previous_large_output)
    end)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      large_output = String.duplicate("antigravity-large-output", 100_000)
      Application.put_env(:symphony_elixir, :agent_runner_large_antigravity_output, large_output)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md"
      )

      issue = %Issue{
        id: "issue-agent-runner-compact-antigravity",
        identifier: "MT-AGY-COMPACT",
        title: "Compact Antigravity updates",
        description: "Avoid forwarding huge CLI payloads",
        state: "In Progress",
        labels: []
      }

      test_pid = self()
      issue_id = issue.id

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 agent_provider: __MODULE__.LargeAntigravityProvider
               )

      updates = receive_codex_worker_updates(issue_id, 3, 500)

      stdout_update =
        Enum.find(updates, fn update ->
          get_in(update, [:payload, :payload, "method"]) == "antigravity_cli/event/stdout"
        end)

      assert %{
               payload: %{
                 payload: %{
                   "method" => "antigravity_cli/event/stdout",
                   "params" => stdout_params
                 },
                 raw: stdout_raw
               }
             } = stdout_update

      assert stdout_params["text_bytes"] == byte_size(large_output)
      assert stdout_params["stderr_bytes"] == 0
      refute Map.has_key?(stdout_params, "text")
      refute Map.has_key?(stdout_params, "stderr")
      assert stdout_raw == ""
      refute inspect(stdout_params) =~ large_output

      log_update =
        Enum.find(updates, fn update ->
          get_in(update, [:payload, :payload, "method"]) == "antigravity_cli/event/log"
        end)

      assert %{
               payload: %{
                 payload: %{
                   "method" => "antigravity_cli/event/log",
                   "params" => log_params
                 },
                 raw: log_raw
               }
             } = log_update

      assert log_params["text_bytes"] == byte_size(large_output)
      assert byte_size(log_params["text_preview"]) <= 243
      refute Map.has_key?(log_params, "text")
      assert log_raw == ""
      refute inspect(log_params) =~ large_output
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner throttles chatty Antigravity CLI log updates before orchestrator mailboxes grow" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-throttle-antigravity-#{System.unique_integer([:positive])}"
      )

    previous_log_count = Application.get_env(:symphony_elixir, :agent_runner_chatty_antigravity_log_count)

    on_exit(fn ->
      restore_app_env(:agent_runner_chatty_antigravity_log_count, previous_log_count)
    end)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      Application.put_env(:symphony_elixir, :agent_runner_chatty_antigravity_log_count, 100)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md"
      )

      issue = %Issue{
        id: "issue-agent-runner-chatty-antigravity",
        identifier: "MT-AGY-CHATTY",
        title: "Throttle chatty Antigravity updates",
        description: "Avoid flooding orchestrator mailboxes with low-value log ticks",
        state: "In Progress",
        labels: []
      }

      test_pid = self()
      existing_pids = MapSet.new(Process.list())

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end,
                 agent_provider: __MODULE__.ChattyAntigravityProvider
               )

      updates = drain_codex_worker_updates(issue.id, [])

      log_updates =
        Enum.filter(updates, fn update ->
          get_in(update, [:payload, :payload, "method"]) == "antigravity_cli/event/log"
        end)

      assert length(log_updates) <= 5
      assert Enum.any?(updates, &(&1.event == :turn_completed))
      assert leaked_antigravity_log_throttle_agents(existing_pids) == []
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards first Antigravity CLI log update for each continuation turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-throttle-antigravity-turns-#{System.unique_integer([:positive])}"
      )

    previous_log_count = Application.get_env(:symphony_elixir, :agent_runner_chatty_antigravity_log_count)

    on_exit(fn ->
      restore_app_env(:agent_runner_chatty_antigravity_log_count, previous_log_count)
    end)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      Application.put_env(:symphony_elixir, :agent_runner_chatty_antigravity_log_count, 50)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-agent-runner-chatty-antigravity-turns",
        identifier: "MT-AGY-CHATTY-TURNS",
        title: "Throttle chatty Antigravity continuation updates",
        description: "Keep the first log for each turn visible",
        state: "In Progress",
        labels: []
      }

      test_pid = self()
      state_fetcher = continuation_state_fetcher(issue, ["In Progress", "Done"])

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: state_fetcher,
                 agent_provider: __MODULE__.ChattyAntigravityProvider
               )

      log_updates =
        issue.id
        |> drain_codex_worker_updates([])
        |> Enum.filter(fn update ->
          get_in(update, [:payload, :payload, "method"]) == "antigravity_cli/event/log"
        end)

      forwarded_texts =
        Enum.map(log_updates, fn update ->
          get_in(update, [:payload, :payload, "params", "text_preview"]) ||
            get_in(update, [:payload, :payload, "params", "text"])
        end)

      assert "chatty turn 1 log 1" in forwarded_texts
      assert "chatty turn 2 log 1" in forwarded_texts
      assert length(log_updates) <= 10
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner applies state-specific max turn limit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-state-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-state-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-state-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-state-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        max_turns: 3,
        max_turns_by_state: %{"Merging" => 1}
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-state-max-turns",
             identifier: "MT-249",
             title: "Stop at state max turns",
             description: "Still active",
             state: "Merging"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-state-max-turns",
        identifier: "MT-249",
        title: "Stop at state max turns",
        description: "Still active",
        state: "Merging",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops in-process continuation when refreshed issue enters no-auto-Codex state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-no-auto-state-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      turn_count=0

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-no-auto-state"}}}'
            ;;
          *'"method":"turn/start"'*)
            turn_count=$((turn_count + 1))
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-no-auto-state"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        tracker_active_states: ["Todo", "In Progress", "Merging"],
        max_turns: 3,
        no_auto_codex_states: ["Merging"]
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-enters-no-auto-state",
             identifier: "MT-563",
             title: "Stop after entering Merging",
             description: "Still active but externally waiting",
             state: "Merging"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-enters-no-auto-state",
        identifier: "MT-563",
        title: "Stop after entering Merging",
        description: "Start in progress",
        state: "In Progress",
        url: "https://example.org/issues/MT-563",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_for_file_line_count(path, expected_count, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_file_line_count_until(path, expected_count, deadline_ms)
  end

  defp wait_for_file_line_count_until(path, expected_count, deadline_ms) do
    line_count =
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> length()
      else
        0
      end

    cond do
      line_count >= expected_count ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(25)
        wait_for_file_line_count_until(path, expected_count, deadline_ms)
    end
  end

  defp drain_core_stress_messages(messages) do
    receive do
      {:codex_worker_update, _issue_id, message} ->
        case core_stress_message_summary(message) do
          nil -> drain_core_stress_messages(messages)
          summary -> drain_core_stress_messages([summary | messages])
        end

      {:worker_runtime_info, _issue_id, _metadata} ->
        drain_core_stress_messages(messages)
    after
      0 ->
        Enum.reverse(messages)
    end
  end

  defp core_stress_message_summary(%{
         payload: %{
           payload: %{"method" => method, "params" => params},
           raw: raw
         }
       })
       when method in ["antigravity_cli/event/stdout", "antigravity_cli/event/log"] and is_map(params) do
    text = Map.get(params, "text", "")

    %{
      method: method,
      text_bytes: Map.get(params, "text_bytes", 0),
      text_truncated: Map.get(params, "text_truncated", false),
      text_size: core_byte_size_or_zero(text),
      text_referenced: core_referenced_byte_size_or_zero(text),
      raw_size: core_byte_size_or_zero(raw),
      raw_referenced: core_referenced_byte_size_or_zero(raw)
    }
  end

  defp core_stress_message_summary(_message), do: nil

  defp core_memory_snapshot do
    :erlang.garbage_collect()

    %{
      total: :erlang.memory(:total),
      binary: :erlang.memory(:binary)
    }
  end

  defp core_byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp core_byte_size_or_zero(_value), do: 0

  defp core_referenced_byte_size_or_zero(value) when is_binary(value), do: :binary.referenced_byte_size(value)
  defp core_referenced_byte_size_or_zero(_value), do: 0
end
