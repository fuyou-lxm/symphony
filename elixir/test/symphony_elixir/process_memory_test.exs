defmodule SymphonyElixir.ProcessMemoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProcessMemory

  test "current_process_tree_memory sums the Symphony BEAM process tree rss" do
    root_pid = System.pid() |> String.to_integer()
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: root_pid, ppid: 1, rss_kb: 1_000, command: "beam.smp"},
      %{pid: root_pid + 1, ppid: root_pid, rss_kb: 2_000, command: "agy"},
      %{pid: root_pid + 2, ppid: root_pid + 1, rss_kb: 3_000, command: "node"},
      %{pid: root_pid + 100, ppid: 1, rss_kb: 999_000, command: "unrelated"}
    ])

    assert ProcessMemory.current_process_tree_memory() == %{
             root_pid: root_pid,
             process_count: 3,
             rss_kb: 6_000,
             rss_bytes: 6_000 * 1024,
             command: "beam.smp"
           }
  end

  test "workspace_preview_memory sums the preview process tree rss" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-process-memory-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      File.rm_rf(workspace)
    end)

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join([workspace, ".symphony", "powerchat.pid"]), "100\n")

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: 100, ppid: 1, rss_kb: 10, command: "sh"},
      %{pid: 101, ppid: 100, rss_kb: 20, command: "node"},
      %{pid: 102, ppid: 101, rss_kb: 30, command: "tail"},
      %{pid: 200, ppid: 1, rss_kb: 999, command: "unrelated"}
    ])

    assert ProcessMemory.workspace_preview_memory(workspace) == %{
             root_pid: 100,
             process_count: 3,
             rss_kb: 60,
             rss_bytes: 60 * 1024,
             command: "sh"
           }
  end

  test "workspace_preview_memory returns nil without a valid local pid file" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-process-memory-missing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    assert ProcessMemory.workspace_preview_memory(workspace) == nil

    File.write!(Path.join([workspace, ".symphony", "powerchat.pid"]), "not-a-pid")
    assert ProcessMemory.workspace_preview_memory(workspace) == nil
  end

  test "process_rows can reuse recent provider rows during a short cache window" do
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      Application.delete_env(:symphony_elixir, :process_memory_ps_rows_cache)
    end)

    parent = self()

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_rows_read)

      [
        %{pid: 100, ppid: 1, rss_kb: 10, command: "beam.smp"}
      ]
    end)

    assert ProcessMemory.process_rows(cache_ttl_ms: 1_000) == [
             %{pid: 100, ppid: 1, rss_kb: 10, command: "beam.smp"}
           ]

    assert ProcessMemory.process_rows(cache_ttl_ms: 1_000) == [
             %{pid: 100, ppid: 1, rss_kb: 10, command: "beam.smp"}
           ]

    assert_receive :process_rows_read
    refute_receive :process_rows_read
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
