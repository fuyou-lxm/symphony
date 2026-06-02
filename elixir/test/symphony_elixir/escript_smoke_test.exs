defmodule SymphonyElixir.EscriptSmokeTest do
  use ExUnit.Case, async: false

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @max_rss_bytes 5 * 1024 * 1024 * 1024

  test "bin/symphony dispatches 10 fake Antigravity CLI issues and stays below the RSS budget" do
    tmp_root = Path.join(System.tmp_dir!(), "symphony-escript-smoke-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_root)

    port_number = (42_000 + System.unique_integer([:positive])) |> rem(10_000)
    port = 30_000 + port_number
    workflow_path = Path.join(tmp_root, "WORKFLOW.md")
    issues_path = Path.join(tmp_root, "issues.json")
    fake_agy_path = Path.join(tmp_root, "fake-agy")
    trace_path = Path.join(tmp_root, "agy-trace.ndjson")
    memory_output_path = Path.join(tmp_root, "memory-monitor.ndjson")
    workspace_root = Path.join(tmp_root, "workspaces")

    on_exit(fn ->
      File.rm_rf(tmp_root)
    end)

    write_fake_agy!(fake_agy_path)
    write_issues!(issues_path, 10)

    write_workflow!(workflow_path, %{
      fake_agy_path: fake_agy_path,
      workspace_root: workspace_root,
      poll_interval_ms: 500
    })

    env = [
      {"SYMPHONY_MEMORY_TRACKER_ISSUES_FILE", issues_path},
      {"SYMPHONY_FAKE_AGY_TRACE", trace_path},
      {"SYMPHONY_FAKE_AGY_SLEEP_SECONDS", "4"}
    ]

    port_ref =
      Port.open({:spawn_executable, Path.expand("bin/symphony")}, [
        :binary,
        :exit_status,
        args: [@ack_flag, "--port", Integer.to_string(port), workflow_path],
        cd: String.to_charlist(File.cwd!()),
        env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
      ])

    symphony_os_pid = port_os_pid(port_ref)
    rss_sampler = start_peak_rss_sampler(port)
    memory_monitor = start_memory_monitor(port, memory_output_path)

    try do
      payload = wait_for_running_count(port, 10, 12_000)
      assert get_in(payload, ["counts", "running"]) == 10

      rss_bytes = get_in(payload, ["process_memory", "symphony_process_tree_rss_bytes"])
      assert is_integer(rss_bytes)
      assert rss_bytes < @max_rss_bytes

      assert wait_for_trace_count(trace_path, 10, 8_000) == 10

      peak = stop_peak_rss_sampler(rss_sampler)
      assert peak.sample_count > 0
      assert peak.max_running == 10
      assert peak.rss_bytes < @max_rss_bytes

      monitor_summary = await_memory_monitor(memory_monitor)
      assert monitor_summary["max_running"] == 10
      assert monitor_summary["min_running"] == 10
      assert monitor_summary["min_running_met"] == true
      assert monitor_summary["threshold_exceeded"] == false
      assert monitor_summary["peak_symphony_process_tree_rss_bytes"] < @max_rss_bytes
      assert memory_monitor_sample_count(memory_output_path) > 0
    after
      stop_peak_rss_sampler(rss_sampler)
      stop_memory_monitor(memory_monitor)
      stop_symphony(port_ref, symphony_os_pid)
    end
  end

  defp write_fake_agy!(path) do
    File.write!(path, """
    #!/bin/sh
    set -eu

    trace_file="${SYMPHONY_FAKE_AGY_TRACE:-}"
    sleep_seconds="${SYMPHONY_FAKE_AGY_SLEEP_SECONDS:-2}"
    log_file=""

    for arg in "$@"; do
      case "$arg" in
        --log-file=*) log_file="${arg#--log-file=}" ;;
      esac
    done

    if [ -n "$trace_file" ]; then
      printf '{"pid":%s,"argc":%s}\\n' "$$" "$#" >> "$trace_file"
    fi

    if [ -n "$log_file" ]; then
      mkdir -p "$(dirname "$log_file")"
      printf 'I0601 printmode.go:71] Print mode: conversation=fake-%s\\n' "$$" > "$log_file"
    python3 - "$log_file" <<'PY'
    import sys
    with open(sys.argv[1], "a", encoding="utf-8") as fh:
        fh.write("L" * (2 * 1024 * 1024))
        fh.write("\\n")
    PY
    fi

    python3 - <<'PY'
    import sys
    sys.stdout.write("S" * (2 * 1024 * 1024))
    sys.stdout.write("\\n")
    sys.stdout.flush()
    PY
    sleep "$sleep_seconds"
    """)

    File.chmod!(path, 0o755)
  end

  defp write_issues!(path, count) do
    issues =
      1..count
      |> Enum.map(fn index ->
        %{
          id: "issue-smoke-#{index}",
          identifier: "SMOKE-#{index}",
          title: "Smoke issue #{index}",
          description: "Standalone escript smoke issue #{index}",
          state: "Todo",
          labels: ["smoke"],
          created_at: DateTime.utc_now() |> DateTime.add(index, :second) |> DateTime.to_iso8601()
        }
      end)

    File.write!(path, Jason.encode!(issues))
  end

  defp write_workflow!(path, attrs) do
    File.write!(path, """
    ---
    tracker:
      kind: memory
      active_states:
        - Todo
      terminal_states:
        - Done
    polling:
      interval_ms: #{attrs.poll_interval_ms}
    workspace:
      root: #{attrs.workspace_root}
    agent:
      provider: antigravity_cli
      max_concurrent_agents: 10
      max_process_tree_rss_bytes: #{@max_rss_bytes}
      dispatch_rss_reservation_bytes: 1
      max_turns: 1
      max_retry_backoff_ms: 60000
      max_turns_by_state: {}
      max_concurrent_agents_by_state: {}
      no_continuation_retry_states: []
      no_auto_codex_states: []
    antigravity_cli:
      command: #{attrs.fake_agy_path}
      approval_policy: never
      print_timeout: 5m
      turn_timeout_ms: 30000
    observability:
      dashboard_enabled: true
      terminal_dashboard_enabled: false
      refresh_ms: 1000
      render_interval_ms: 1000
    server:
      host: 127.0.0.1
    ---

    Smoke prompt for {{ issue.identifier }}.
    """)
  end

  defp wait_for_running_count(port, expected_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_running_count(port, expected_count, deadline, nil)
  end

  defp do_wait_for_running_count(port, expected_count, deadline, last_payload) do
    case fetch_state(port) do
      {:ok, payload} ->
        if get_in(payload, ["counts", "running"]) == expected_count do
          payload
        else
          continue_waiting(port, expected_count, deadline, payload)
        end

      :error ->
        continue_waiting(port, expected_count, deadline, last_payload)
    end
  end

  defp continue_waiting(port, expected_count, deadline, last_payload) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("expected #{expected_count} running issues before timeout; last_payload=#{inspect(last_payload)}")
    else
      Process.sleep(100)
      do_wait_for_running_count(port, expected_count, deadline, last_payload)
    end
  end

  defp fetch_state(port) do
    case Req.get("http://127.0.0.1:#{port}/api/v1/memory", retry: false, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _ -> :error
    end
  end

  defp start_peak_rss_sampler(port) do
    Task.async(fn ->
      sample_peak_rss(port, %{
        rss_bytes: 0,
        sample_count: 0,
        max_running: 0,
        last_payload: nil
      })
    end)
  end

  defp stop_peak_rss_sampler(%Task{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    Task.await(task, 2_000)
  catch
    :exit, _reason ->
      %{rss_bytes: 0, sample_count: 0, max_running: 0, last_payload: nil}
  end

  defp start_memory_monitor(port, output_path) do
    Task.async(fn ->
      args = [
        "observability.memory_monitor",
        "--port",
        Integer.to_string(port),
        "--samples",
        "60",
        "--interval-ms",
        "100",
        "--min-running",
        "10",
        "--max-rss-bytes",
        Integer.to_string(@max_rss_bytes),
        "--output",
        output_path,
        "--summary"
      ]

      {output, status} = System.cmd("mise", ["exec", "--", "mix" | args], stderr_to_stdout: true)

      if status != 0 do
        raise "memory monitor failed status=#{status} output=#{output}"
      end

      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> Jason.decode!()
    end)
  end

  defp await_memory_monitor(%Task{} = task) do
    Task.await(task, 10_000)
  catch
    :exit, _reason -> %{}
  end

  defp stop_memory_monitor(%Task{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp memory_monitor_sample_count(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> length()
      {:error, _reason} -> 0
    end
  end

  defp sample_peak_rss(port, peak) do
    peak =
      case fetch_state(port) do
        {:ok, payload} -> update_peak_rss(peak, payload)
        :error -> peak
      end

    receive do
      :stop -> peak
    after
      100 -> sample_peak_rss(port, peak)
    end
  end

  defp update_peak_rss(peak, payload) do
    rss_bytes = get_in(payload, ["process_memory", "symphony_process_tree_rss_bytes"])
    running_count = get_in(payload, ["counts", "running"])

    peak
    |> Map.put(:sample_count, peak.sample_count + 1)
    |> Map.put(:last_payload, payload)
    |> Map.put(:rss_bytes, max_integer(peak.rss_bytes, rss_bytes))
    |> Map.put(:max_running, max_integer(peak.max_running, running_count))
  end

  defp max_integer(left, right) when is_integer(right), do: max(left, right)
  defp max_integer(left, _right), do: left

  defp wait_for_trace_count(path, expected_count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_trace_count(path, expected_count, deadline)
  end

  defp do_wait_for_trace_count(path, expected_count, deadline) do
    count =
      case File.read(path) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> length()
        {:error, _reason} -> 0
      end

    cond do
      count >= expected_count ->
        count

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected_count} fake agy invocations before timeout, got #{count}")

      true ->
        Process.sleep(100)
        do_wait_for_trace_count(path, expected_count, deadline)
    end
  end

  defp port_os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
      _ -> nil
    end
  end

  defp stop_symphony(port, nil) when is_port(port) do
    close_port(port)
  end

  defp stop_symphony(port, pid) when is_port(port) and is_integer(pid) and pid > 0 do
    kill_pid(pid, "-TERM")

    case receive_port_exit(port, 5_000) do
      :ok ->
        :ok

      :timeout ->
        stop_process_tree(pid)
        close_port(port)
    end
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
    receive_port_exit(port, 2_000)
  rescue
    ArgumentError -> :ok
  end

  defp stop_process_tree(nil), do: :ok

  defp stop_process_tree(pid) when is_integer(pid) and pid > 0 do
    child_pids(pid)
    |> Enum.each(&stop_process_tree/1)

    kill_pid(pid, "-KILL")
  end

  defp child_pids(pid) when is_integer(pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn value ->
          case Integer.parse(String.trim(value)) do
            {child_pid, ""} when child_pid > 0 -> [child_pid]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp kill_pid(pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp receive_port_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> receive_port_exit(port, timeout_ms)
    after
      timeout_ms -> :timeout
    end
  end
end
