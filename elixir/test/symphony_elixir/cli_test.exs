defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    capture_io(fn ->
      assert :ok = CLI.evaluate([@ack_flag], deps)
    end)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    capture_io(fn ->
      assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    end)

    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    capture_io(fn ->
      assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    end)

    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    output =
      capture_io(fn ->
        assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
        assert message =~ "Workflow file not found:"
      end)

    assert output == ""
  end

  test "returns startup error when app cannot start" do
    workflow_path = "WORKFLOW.en.powerchat-agy.md"
    expanded_workflow_path = Path.expand(workflow_path)
    logs_root = "tmp/failing-real-agy-run"
    expanded_logs_root = Path.expand(logs_root)

    deps = %{
      file_regular?: fn path -> path == expanded_workflow_path end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    output =
      capture_io(fn ->
        assert {:error, message} =
                 CLI.evaluate(
                   [@ack_flag, "--logs-root", logs_root, "--port", "4011", workflow_path],
                   deps
                 )

        assert message =~ "Failed to start Symphony with workflow"
        assert message =~ ":boom"
      end)

    assert output =~ "Starting Symphony..."
    assert output =~ "Workflow: #{expanded_workflow_path}"
    assert output =~ "Logs: #{Path.join(expanded_logs_root, "log/symphony.log")}"
    assert output =~ "Dashboard/API: http://127.0.0.1:4011/"
    refute output =~ "Symphony started"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    capture_io(fn ->
      assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    end)
  end

  test "prints a startup summary when the app starts" do
    workflow_path = "WORKFLOW.en.powerchat-agy.md"
    expanded_workflow_path = Path.expand(workflow_path)
    logs_root = "tmp/real-agy-run-20260604-120000"
    expanded_logs_root = Path.expand(logs_root)
    port = 4011

    deps = %{
      file_regular?: fn path -> path == expanded_workflow_path end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.evaluate(
                   [@ack_flag, "--logs-root", logs_root, "--port", Integer.to_string(port), workflow_path],
                   deps
                 )
      end)

    assert output =~ "Starting Symphony..."
    assert output =~ "Symphony started"
    assert output =~ "Workflow: #{expanded_workflow_path}"
    assert output =~ "Logs: #{Path.join(expanded_logs_root, "log/symphony.log")}"
    assert output =~ "Dashboard/API: http://127.0.0.1:4011/"
    assert output =~ "Press Ctrl-C to stop."
  end
end
