defmodule SymphonyElixir.AgentProviderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentProvider
  alias SymphonyElixir.AgentProvider.AntigravityCli
  alias SymphonyElixir.AgentProvider.AntigravitySdk
  alias SymphonyElixir.AgentProvider.CodexAppServer

  test "configured provider defaults to Codex app-server" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_provider: nil)

    assert AgentProvider.configured_provider() == CodexAppServer
  end

  test "configured provider selects Antigravity SDK without changing Codex config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_provider: "antigravity_sdk",
      codex_command: "codex --config model=gpt-5.5 app-server"
    )

    assert AgentProvider.configured_provider() == AntigravitySdk
    assert Config.settings!().codex.command == "codex --config model=gpt-5.5 app-server"
  end

  test "configured provider selects Antigravity CLI without changing Codex config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_provider: "antigravity_cli",
      codex_command: "codex --config model=gpt-5.5 app-server"
    )

    assert AgentProvider.configured_provider() == AntigravityCli
    assert Config.settings!().codex.command == "codex --config model=gpt-5.5 app-server"
  end

  test "antigravity CLI provider runs print turns, tracks conversation id, and resumes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-provider-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY")
      fake_agy = Path.join(test_root, "fake-agy")
      trace_file = Path.join(test_root, "agy.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      trace_file="$SYMP_TEST_ANTIGRAVITY_CLI_TRACE"
      log_file=""
      prompt=""
      conversation=""
      args_json=""
      while [ "$#" -gt 0 ]; do
        encoded_arg=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]), end="")' "$1")
        if [ -z "$args_json" ]; then
          args_json="$encoded_arg"
        else
          args_json="$args_json,$encoded_arg"
        fi

        case "$1" in
          --log-file=*)
            log_file="${1#--log-file=}"
            ;;
          --print=*)
            prompt="${1#--print=}"
            ;;
          --conversation)
            shift
            conversation="$1"
            encoded_arg=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]), end="")' "$1")
            args_json="$args_json,$encoded_arg"
            ;;
        esac
        shift
      done

      printf '{"cwd":"%s","args":[%s],"conversation":"%s","prompt":' "$PWD" "$args_json" "$conversation" >> "$trace_file"
      python3 -c 'import json, sys; print(json.dumps(sys.argv[1]), end="")' "$prompt" >> "$trace_file"
      printf '}\\n' >> "$trace_file"

      if [ -n "$log_file" ]; then
        mkdir -p "$(dirname "$log_file")"
        if [ -n "$conversation" ]; then
          printf 'I0601 printmode.go:130] Print mode: conversation=%s, sending message\\n' "$conversation" >> "$log_file"
        else
          printf 'I0601 server.go:755] Created conversation agy-thread-1\\n' >> "$log_file"
        fi
      fi

      if [ -n "$conversation" ]; then
        printf 'second cli response\\n'
      else
        printf 'first cli response\\n'
      fi
      """)

      File.chmod!(fake_agy, 0o755)

      previous_trace = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_approval_policy: "never",
        antigravity_cli_print_timeout: "90s"
      )

      issue = %Issue{
        id: "issue-antigravity-cli-provider",
        identifier: "MT-AGY",
        title: "Run Antigravity CLI provider",
        description: "Use the CLI provider",
        state: "In Progress",
        labels: []
      }

      {:ok, messages} = Agent.start(fn -> collect_messages([]) end)

      assert {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:ok, first_turn} =
               AntigravityCli.run_turn(session, "First prompt", issue, on_message: fn message -> Agent.update(messages, &[message | &1]) end)

      assert {:ok, second_turn} =
               AntigravityCli.run_turn(session, "Second prompt", issue, on_message: fn message -> Agent.update(messages, &[message | &1]) end)

      assert :ok = AntigravityCli.stop_session(session)

      assert first_turn.thread_id == "agy-thread-1"
      assert first_turn.result == "first cli response\n"
      assert second_turn.thread_id == "agy-thread-1"
      assert second_turn.result == "second cli response\n"

      emitted =
        messages
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert Enum.any?(emitted, fn message ->
               message.event == :notification and
                 get_in(message, [:payload, :payload, "method"]) == "antigravity_cli/event/stdout" and
                 get_in(message, [:payload, :payload, "params", "text"]) == "first cli response\n"
             end)

      trace = trace_file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert [first_call, second_call] = trace
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert first_call["cwd"] == canonical_workspace
      assert "--add-dir" in first_call["args"]
      assert canonical_workspace in first_call["args"]
      assert "--dangerously-skip-permissions" in first_call["args"]
      assert "--print-timeout=90s" in first_call["args"]
      assert first_call["prompt"] == "/goal First prompt"
      assert second_call["conversation"] == "agy-thread-1"
      assert second_call["prompt"] == "/goal Second prompt"
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider does not double-wrap prompts that already use goal" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-existing-goal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-GOAL")
      fake_agy = Path.join(test_root, "fake-agy")
      trace_file = Path.join(test_root, "agy.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      prompt=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --print=*)
            prompt="${1#--print=}"
            ;;
        esac
        shift
      done

      python3 -c 'import json, os, sys; open(os.environ["SYMP_TEST_ANTIGRAVITY_CLI_TRACE"], "w").write(json.dumps(sys.argv[1]))' "$prompt"
      printf ok
      """)

      File.chmod!(fake_agy, 0o755)

      previous_trace = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy
      )

      issue = %Issue{id: "issue-antigravity-cli-existing-goal", identifier: "MT-AGY-GOAL", title: "Goal", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)
      assert {:ok, _turn} = AntigravityCli.run_turn(session, "/goal Already goal driven", issue)
      assert :ok = AntigravityCli.stop_session(session)

      assert Jason.decode!(File.read!(trace_file)) == "/goal Already goal driven"
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider reports non-zero exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-FAIL")
      fake_agy = Path.join(test_root, "fake-agy-fail")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      echo "agy failed loudly"
      exit 17
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy
      )

      issue = %Issue{id: "issue-antigravity-cli-failure", identifier: "MT-AGY-FAIL", title: "Fail", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:error, {:antigravity_cli_exit, 17, output}} = AntigravityCli.run_turn(session, "Prompt", issue)
      assert output =~ "agy failed loudly"
      assert :ok = AntigravityCli.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider omits auto approval flag for on-request policy" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-on-request-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-ASK")
      fake_agy = Path.join(test_root, "fake-agy")
      trace_file = Path.join(test_root, "agy.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      python3 -c 'import json, os, sys; open(os.environ["SYMP_TEST_ANTIGRAVITY_CLI_TRACE"], "w").write(json.dumps(sys.argv[1:]))' "$@"
      printf ok
      """)

      File.chmod!(fake_agy, 0o755)

      previous_trace = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_approval_policy: "on-request"
      )

      issue = %Issue{id: "issue-antigravity-cli-on-request", identifier: "MT-AGY-ASK", title: "Ask", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)
      assert {:ok, _turn} = AntigravityCli.run_turn(session, "Prompt", issue)
      assert :ok = AntigravityCli.stop_session(session)

      args = trace_file |> File.read!() |> Jason.decode!()
      refute "--dangerously-skip-permissions" in args
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider times out stuck print turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-TIMEOUT")
      fake_agy = Path.join(test_root, "fake-agy-timeout")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      sleep 5
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 25
      )

      issue = %Issue{id: "issue-antigravity-cli-timeout", identifier: "MT-AGY-TIMEOUT", title: "Timeout", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:error, :turn_timeout} = AntigravityCli.run_turn(session, "Prompt", issue)
      assert :ok = AntigravityCli.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider kills local child process trees when print turns time out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-timeout-process-tree-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-TIMEOUT-TREE")
      fake_agy = Path.join(test_root, "fake-agy-timeout-tree")
      child_pid_file = Path.join(test_root, "child.pid")

      File.mkdir_p!(workspace)

      File.write!(
        fake_agy,
        "#!/bin/sh\n" <>
          "(sleep 30) &\n" <>
          "echo \"$!\" > #{shell_quote(child_pid_file)}\n" <>
          "sleep 30\n"
      )

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 1_000
      )

      issue = %Issue{
        id: "issue-antigravity-cli-timeout-tree",
        identifier: "MT-AGY-TIMEOUT-TREE",
        title: "Timeout process tree",
        description: "",
        state: "In Progress",
        labels: []
      }

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:error, :turn_timeout} = AntigravityCli.run_turn(session, "Prompt", issue)
      assert :ok = AntigravityCli.stop_session(session)

      assert wait_for_file(child_pid_file, 1_000)
      child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()

      refute process_alive?(child_pid, 1_000)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider stop_session kills in-flight local child process trees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-stop-session-process-tree-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-STOP-TREE")
      fake_agy = Path.join(test_root, "fake-agy-stop-tree")
      child_pid_file = Path.join(test_root, "child.pid")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      (sleep 30) &
      echo "$!" > "#{child_pid_file}"
      sleep 30
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 60_000
      )

      issue = %Issue{
        id: "issue-antigravity-cli-stop-tree",
        identifier: "MT-AGY-STOP-TREE",
        title: "Stop process tree",
        description: "",
        state: "In Progress",
        labels: []
      }

      {:ok, session} = AntigravityCli.start_session(workspace)
      test_pid = self()

      task =
        Task.async(fn ->
          result =
            AntigravityCli.run_turn(session, "Prompt", issue,
              on_message: fn message ->
                send(test_pid, {:stop_tree_message, message})
              end
            )

          send(test_pid, {:stop_tree_result, result})
          result
        end)

      assert_receive {:stop_tree_message, %{event: :session_started}}, 1_000
      assert wait_for_file(child_pid_file, 2_000)
      child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()

      assert process_alive?(child_pid, 100)
      assert :ok = AntigravityCli.stop_session(session)

      refute process_alive?(child_pid, 1_000)

      Task.shutdown(task, :brutal_kill)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider streams log activity while print turn is still running" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-log-stream-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-LOG")
      fake_agy = Path.join(test_root, "fake-agy-log-stream")
      test_pid = self()

      File.mkdir_p!(workspace)

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
      printf 'I0601 printmode.go:71] Print mode: starting\\n' >> "$log_file"
      sleep 1
      printf 'done\\n'
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 5_000
      )

      issue = %Issue{id: "issue-antigravity-cli-log-stream", identifier: "MT-AGY-LOG", title: "Log stream", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)

      task =
        Task.async(fn ->
          AntigravityCli.run_turn(session, "Prompt", issue,
            on_message: fn message ->
              send(test_pid, {:antigravity_cli_message, message})
            end
          )
        end)

      assert_receive {:antigravity_cli_message,
                      %{
                        event: :notification,
                        payload: %{
                          payload: %{
                            "method" => "antigravity_cli/event/log",
                            "params" => %{"text" => log_text}
                          }
                        }
                      }},
                     3_000

      assert log_text =~ "Print mode: starting"
      refute Task.yield(task, 0)

      assert {:ok, _turn} = Task.await(task, 5_000)
      assert :ok = AntigravityCli.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider polls log activity at most once per second while print turns run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-log-poll-throttle-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-LOG-THROTTLE")
      fake_agy = Path.join(test_root, "fake-agy-log-poll-throttle")
      test_pid = self()

      File.mkdir_p!(workspace)

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
      for index in $(seq 1 12); do
        printf 'log tick %s\\n' "$index" >> "$log_file"
        sleep 0.1
      done
      printf 'done\\n'
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 5_000
      )

      issue = %Issue{id: "issue-antigravity-cli-log-poll-throttle", identifier: "MT-AGY-LOG-THROTTLE", title: "Log poll throttle", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:ok, _turn} =
               AntigravityCli.run_turn(session, "Prompt", issue,
                 on_message: fn message ->
                   send(test_pid, {:antigravity_cli_log_poll_message, message})
                 end
               )

      assert :ok = AntigravityCli.stop_session(session)

      log_messages =
        drain_antigravity_cli_log_poll_messages([])
        |> Enum.filter(fn message ->
          get_in(message, [:payload, :payload, "method"]) == "antigravity_cli/event/log"
        end)

      assert length(log_messages) <= 2

      assert Enum.any?(log_messages, fn message ->
               get_in(message, [:payload, :payload, "params", "text"]) =~ "log tick"
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider bounds large stdout captured from print turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-bounded-stdout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-STDOUT")
      fake_agy = Path.join(test_root, "fake-agy-bounded-stdout")

      File.mkdir_p!(workspace)

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
      printf 'I0601 server.go:755] Created conversation agy-large-stdout\\n' >> "$log_file"
      printf 'start-marker\\n'
      python3 -c 'import sys; sys.stdout.write("x" * 200000); sys.stdout.write("\\ntail-marker\\n")'
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy
      )

      issue = %Issue{id: "issue-antigravity-cli-bounded-stdout", identifier: "MT-AGY-STDOUT", title: "Bound stdout", description: "", state: "In Progress", labels: []}
      {:ok, messages} = Agent.start(fn -> collect_messages([]) end)

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:ok, turn} =
               AntigravityCli.run_turn(session, "Prompt", issue, on_message: fn message -> Agent.update(messages, &[message | &1]) end)

      assert :ok = AntigravityCli.stop_session(session)

      assert byte_size(turn.result) <= 65_536
      assert :binary.referenced_byte_size(turn.result) <= 65_536
      assert turn.result =~ "tail-marker"
      refute turn.result =~ "start-marker"

      stdout_message =
        messages
        |> Agent.get(& &1)
        |> Enum.find(fn message ->
          get_in(message, [:payload, :payload, "method"]) == "antigravity_cli/event/stdout"
        end)

      assert is_map(stdout_message)
      stdout_params = get_in(stdout_message, [:payload, :payload, "params"])
      assert stdout_params["text_bytes"] > 200_000
      assert stdout_params["text_truncated"] == true
      assert byte_size(stdout_params["text"]) <= 65_536
      assert :binary.referenced_byte_size(stdout_params["text"]) <= 65_536
      assert stdout_params["text"] =~ "tail-marker"
      refute stdout_params["text"] =~ "start-marker"
      assert byte_size(stdout_message.payload.raw) <= 65_536
      assert :binary.referenced_byte_size(stdout_message.payload.raw) <= 65_536
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI stdout tail handles oversized chunks without retaining prior tail" do
    existing = %{tail: "old-tail", bytes: 8, truncated?: false}
    large_chunk = String.duplicate("x", 200_000) <> "\nnew-tail\n"

    updated = AntigravityCli.append_stdout_tail_for_test(existing, large_chunk)

    assert updated.bytes == 8 + byte_size(large_chunk)
    assert updated.truncated? == true
    assert byte_size(updated.tail) <= 65_536
    assert :binary.referenced_byte_size(updated.tail) <= 65_536
    assert updated.tail =~ "new-tail"
    refute updated.tail =~ "old-tail"
  end

  test "antigravity CLI provider bounds large log chunks while print turns run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-bounded-log-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-BIGLOG")
      fake_agy = Path.join(test_root, "fake-agy-bounded-log")
      test_pid = self()

      File.mkdir_p!(workspace)

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
      {
        printf 'I0601 printmode.go:71] Print mode: starting\\n'
        python3 -c 'import sys; sys.stdout.write("log-line " * 250000); sys.stdout.write("\\nlog-tail\\n")'
      } >> "$log_file"
      sleep 1
      printf 'done\\n'
      """)

      File.chmod!(fake_agy, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 5_000
      )

      issue = %Issue{id: "issue-antigravity-cli-bounded-log", identifier: "MT-AGY-BIGLOG", title: "Bound log", description: "", state: "In Progress", labels: []}
      {:ok, messages} = Agent.start(fn -> collect_messages([]) end)

      {:ok, session} = AntigravityCli.start_session(workspace)

      assert {:ok, _turn} =
               AntigravityCli.run_turn(session, "Prompt", issue,
                 on_message: fn message ->
                   send(test_pid, {:antigravity_cli_message, message})
                   Agent.update(messages, &[message | &1])
                 end
               )

      log_messages =
        messages
        |> Agent.get(& &1)
        |> Enum.reverse()
        |> Enum.filter(fn message ->
          get_in(message, [:payload, :payload, "method"]) == "antigravity_cli/event/log"
        end)

      assert log_messages != []

      {log_params, raw_log} =
        Enum.max_by(log_messages, fn message ->
          get_in(message, [:payload, :payload, "params", "text_bytes"]) || 0
        end)
        |> then(fn message ->
          {get_in(message, [:payload, :payload, "params"]), get_in(message, [:payload, :raw])}
        end)

      assert log_params["text_bytes"] > 2_000_000
      assert log_params["text_truncated"] == true
      assert byte_size(log_params["text"]) <= 16_384
      assert :binary.referenced_byte_size(log_params["text"]) <= 16_384
      assert log_params["text"] =~ "log-line"
      assert byte_size(raw_log) <= 16_384
      assert :binary.referenced_byte_size(raw_log) <= 16_384

      assert :ok = AntigravityCli.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider does not resume with fallback thread id when CLI logs no conversation id" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-no-conversation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGY-NO-CONV")
      fake_agy = Path.join(test_root, "fake-agy-no-conversation")
      trace_file = Path.join(test_root, "agy.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_agy, """
      #!/bin/sh
      trace_file="$SYMP_TEST_ANTIGRAVITY_CLI_TRACE"
      conversation=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --conversation)
            shift
            conversation="$1"
            ;;
          --log-file=*)
            log_file="${1#--log-file=}"
            mkdir -p "$(dirname "$log_file")"
            printf 'print completed without conversation id\\n' >> "$log_file"
            ;;
        esac
        shift
      done

      printf '%s\\n' "$conversation" >> "$trace_file"
      printf 'ok\\n'
      """)

      File.chmod!(fake_agy, 0o755)

      previous_trace = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy
      )

      issue = %Issue{id: "issue-antigravity-cli-no-conversation", identifier: "MT-AGY-NO-CONV", title: "No conversation", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace)
      assert {:ok, first_turn} = AntigravityCli.run_turn(session, "First prompt", issue)
      assert {:ok, second_turn} = AntigravityCli.run_turn(session, "Second prompt", issue)
      assert :ok = AntigravityCli.stop_session(session)

      assert first_turn.thread_id == "antigravity-cli"
      assert second_turn.thread_id == "antigravity-cli"
      assert File.read!(trace_file) == "\n\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity CLI provider times out remote print turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-remote-timeout-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_ssh_bin = System.get_env("SYMPHONY_SSH_BIN")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_BIN", previous_ssh_bin)
    end)

    try do
      workspace_root = "/remote/workspaces"
      workspace = "/remote/workspaces/MT-AGY-REMOTE-TIMEOUT"
      fake_bin_dir = Path.join(test_root, "bin")
      fake_ssh = Path.join(fake_bin_dir, "ssh")
      trace_file = Path.join(test_root, "ssh.trace")

      File.mkdir_p!(fake_bin_dir)
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))
      System.put_env("SYMPHONY_SSH_BIN", fake_ssh)

      File.write!(fake_ssh, """
      #!/bin/sh
      mkdir -p "#{Path.dirname(trace_file)}"
      printf '%s\\n' "$*" >> "#{trace_file}"
      case "$*" in
        *"tail -c"*|*"wc -c"*) exit 0 ;;
      esac
      printf 'ssh-started\\n'
      sleep 5
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: "agy",
        antigravity_cli_turn_timeout_ms: 2_000
      )

      issue = %Issue{id: "issue-antigravity-cli-remote-timeout", identifier: "MT-AGY-REMOTE-TIMEOUT", title: "Remote timeout", description: "", state: "In Progress", labels: []}

      {:ok, session} = AntigravityCli.start_session(workspace, worker_host: "worker-01")
      assert {:error, :turn_timeout} = AntigravityCli.run_turn(session, "Prompt", issue)
      assert :ok = AntigravityCli.stop_session(session)

      assert wait_for_file(trace_file, 1_000)
      trace = File.read!(trace_file)
      assert trace =~ "trap"
      assert trace =~ "kill_tree"
      assert trace =~ "AGY_PID"
      assert trace =~ "wait \"$AGY_PID\""
    after
      File.rm_rf(test_root)
    end
  end

  @tag timeout: 30_000
  test "antigravity CLI provider keeps memory bounded for ten parallel large-output print turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-cli-parallel-memory-#{System.unique_integer([:positive])}"
      )

    previous_started = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_STARTED")
    previous_expected = System.get_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_EXPECTED")

    on_exit(fn ->
      restore_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_STARTED", previous_started)
      restore_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_EXPECTED", previous_expected)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      fake_agy = Path.join(test_root, "fake-agy-parallel-memory")
      started_file = Path.join(test_root, "started.txt")
      parent = self()

      File.mkdir_p!(workspace_root)
      File.write!(started_file, "")

      File.write!(fake_agy, """
      #!/bin/sh
      log_file=""
      started_file="$SYMP_TEST_ANTIGRAVITY_CLI_STRESS_STARTED"
      expected="${SYMP_TEST_ANTIGRAVITY_CLI_STRESS_EXPECTED:-10}"
      stdout_bytes=2000000
      log_bytes=2000000

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --log-file=*)
            log_file="${1#--log-file=}"
            ;;
        esac
        shift
      done

      printf 'started\\n' >> "$started_file"

      for _ in $(seq 1 100); do
        count=$(wc -l < "$started_file" 2>/dev/null | tr -d ' ')
        if [ "${count:-0}" -ge "$expected" ]; then
          break
        fi
        sleep 0.05
      done

      mkdir -p "$(dirname "$log_file")"
      python3 - "$log_file" "$log_bytes" <<'PY'
      import os
      import sys

      path = sys.argv[1]
      size = int(sys.argv[2])

      with open(path, "ab") as log:
          log.write(f"I0601 server.go:755] Created conversation agy-stress-{os.getpid()}\\n".encode())
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

      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_STARTED", started_file)
      System.put_env("SYMP_TEST_ANTIGRAVITY_CLI_STRESS_EXPECTED", "10")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_cli",
        antigravity_cli_command: fake_agy,
        antigravity_cli_turn_timeout_ms: 15_000
      )

      before_memory = memory_snapshot()

      tasks =
        for index <- 1..10 do
          Task.async(fn ->
            workspace = Path.join(workspace_root, "MT-AGY-MEM-#{index}")
            File.mkdir_p!(workspace)

            issue = %Issue{
              id: "issue-antigravity-cli-memory-#{index}",
              identifier: "MT-AGY-MEM-#{index}",
              title: "Parallel memory #{index}",
              description: "",
              state: "In Progress",
              labels: []
            }

            {:ok, session} = AntigravityCli.start_session(workspace)

            try do
              AntigravityCli.run_turn(session, "Prompt #{index}", issue,
                on_message: fn message ->
                  case stress_message_summary(message) do
                    nil -> :ok
                    summary -> send(parent, {:stress_message, index, summary})
                  end
                end
              )
            after
              AntigravityCli.stop_session(session)
            end
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 30_000))
      stress_messages = drain_stress_messages([])

      assert File.read!(started_file) |> String.split("\n", trim: true) |> length() == 10

      assert Enum.all?(results, fn
               {:ok, turn} ->
                 byte_size(turn.result) <= 65_536 and
                   :binary.referenced_byte_size(turn.result) <= 65_536 and
                   String.contains?(turn.result, "tail-marker") and
                   not String.contains?(turn.result, "start-marker")

               _ ->
                 false
             end)

      stdout_messages = Enum.filter(stress_messages, &(&1.method == "antigravity_cli/event/stdout"))
      log_messages = Enum.filter(stress_messages, &(&1.method == "antigravity_cli/event/log"))

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

      after_memory = memory_snapshot()

      assert after_memory.total < 5 * 1024 * 1024 * 1024
      assert after_memory.binary < 256 * 1024 * 1024
      assert after_memory.total - before_memory.total < 512 * 1024 * 1024
    after
      File.rm_rf(test_root)
    end
  end

  test "antigravity SDK provider starts runner, streams events, tracks usage, and completes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-antigravity-provider-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AG")
      fake_python = Path.join(test_root, "fake-python")
      fake_runner = Path.join(test_root, "fake-antigravity-runner.py")
      trace_file = Path.join(test_root, "runner.trace")

      File.mkdir_p!(workspace)

      File.write!(fake_python, """
      #!/bin/sh
      exec "$@"
      """)

      File.write!(fake_runner, """
      #!/usr/bin/env python3
      import json
      import os
      import sys

      trace_file = os.environ["SYMP_TEST_ANTIGRAVITY_TRACE"]

      for line in sys.stdin:
          payload = json.loads(line)
          with open(trace_file, "a", encoding="utf-8") as trace:
              trace.write(json.dumps(payload, sort_keys=True) + "\\n")

          if payload["op"] == "start":
              print(json.dumps({
                  "event": "session_started",
                  "session_id": "ag-thread",
                  "thread_id": "ag-thread",
                  "metadata": {"runner": "fake"}
              }), flush=True)
          elif payload["op"] == "turn":
              print(json.dumps({
                  "event": "notification",
                  "method": "antigravity/event/agent_message_delta",
                  "params": {"delta": "hello from antigravity"}
              }), flush=True)
              print(json.dumps({
                  "event": "token_count",
                  "input_tokens": 12,
                  "output_tokens": 5,
                  "total_tokens": 17
              }), flush=True)
              print(json.dumps({
                  "event": "turn_completed",
                  "turn_id": "ag-turn",
                  "result": "turn completed"
              }), flush=True)
      """)

      File.chmod!(fake_python, 0o755)
      File.chmod!(fake_runner, 0o755)

      previous_trace = System.get_env("SYMP_TEST_ANTIGRAVITY_TRACE")

      on_exit(fn ->
        restore_env("SYMP_TEST_ANTIGRAVITY_TRACE", previous_trace)
      end)

      System.put_env("SYMP_TEST_ANTIGRAVITY_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "antigravity_sdk",
        antigravity_python: fake_python,
        antigravity_runner: fake_runner,
        antigravity_model: "gemini-test",
        antigravity_api_key: "test-api-key",
        antigravity_app_data_dir: Path.join(test_root, "app-data"),
        antigravity_save_dir: Path.join(test_root, "save"),
        antigravity_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-antigravity-provider",
        identifier: "MT-AG",
        title: "Run Antigravity provider",
        description: "Use the SDK provider",
        state: "In Progress",
        labels: []
      }

      {:ok, messages} = Agent.start(fn -> collect_messages([]) end)

      assert {:ok, session} = AntigravitySdk.start_session(workspace)

      assert {:ok, turn} =
               AntigravitySdk.run_turn(session, "Please make the change", issue, on_message: fn message -> Agent.update(messages, &[message | &1]) end)

      assert :ok = AntigravitySdk.stop_session(session)

      assert turn.session_id == "ag-thread-ag-turn"
      assert turn.thread_id == "ag-thread"
      assert turn.turn_id == "ag-turn"

      emitted =
        messages
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert Enum.any?(emitted, &(&1.event == :session_started))

      assert Enum.any?(emitted, fn message ->
               message.event == :notification and
                 get_in(message, [:payload, :payload, "method"]) == "antigravity/event/agent_message_delta"
             end)

      assert Enum.any?(emitted, fn message ->
               get_in(message, [:payload, :payload, "method"]) == "codex/event/token_count" and
                 get_in(message, [:payload, :payload, "msg", "input_tokens"]) == 12 and
                 get_in(message, [:payload, :payload, "msg", "output_tokens"]) == 5 and
                 get_in(message, [:payload, :payload, "msg", "total_tokens"]) == 17
             end)

      trace = trace_file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert [%{"op" => "start"} = start_payload, %{"op" => "turn"} = turn_payload | _] = trace
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert start_payload["cwd"] == canonical_workspace
      assert start_payload["model"] == "gemini-test"
      assert start_payload["api_key"] == "test-api-key"
      assert start_payload["approval_policy"] == "never"
      assert turn_payload["prompt"] == "Please make the change"
      assert turn_payload["issue"]["identifier"] == "MT-AG"
    after
      File.rm_rf(test_root)
    end
  end

  defp collect_messages(messages), do: messages

  defp stress_message_summary(%{
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
      text_size: byte_size_or_zero(text),
      text_referenced: referenced_byte_size_or_zero(text),
      raw_size: byte_size_or_zero(raw),
      raw_referenced: referenced_byte_size_or_zero(raw)
    }
  end

  defp stress_message_summary(_message), do: nil

  defp drain_stress_messages(messages) do
    receive do
      {:stress_message, _index, message} -> drain_stress_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp drain_antigravity_cli_log_poll_messages(messages) do
    receive do
      {:antigravity_cli_log_poll_message, message} -> drain_antigravity_cli_log_poll_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp wait_for_file(path, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_file_until(path, deadline_ms)
  end

  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp wait_for_file_until(path, deadline_ms) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(25)
        wait_for_file_until(path, deadline_ms)
    end
  end

  defp process_alive?(pid, timeout_ms) when is_integer(pid) and pid > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    process_alive_until?(pid, deadline_ms)
  end

  defp process_alive?(_pid, _timeout_ms), do: false

  defp process_alive_until?(pid, deadline_ms) do
    alive? =
      case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
        {_output, 0} -> true
        _ -> false
      end

    cond do
      not alive? ->
        false

      System.monotonic_time(:millisecond) >= deadline_ms ->
        true

      true ->
        Process.sleep(25)
        process_alive_until?(pid, deadline_ms)
    end
  end

  defp memory_snapshot do
    :erlang.garbage_collect()

    %{
      total: :erlang.memory(:total),
      binary: :erlang.memory(:binary)
    }
  end

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp referenced_byte_size_or_zero(value) when is_binary(value), do: :binary.referenced_byte_size(value)
  defp referenced_byte_size_or_zero(_value), do: 0
end
