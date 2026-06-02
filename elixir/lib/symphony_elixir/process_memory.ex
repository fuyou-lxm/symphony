defmodule SymphonyElixir.ProcessMemory do
  @moduledoc """
  Lightweight process-tree RSS helpers for observability diagnostics.
  """

  @preview_pid_file Path.join([".symphony", "powerchat.pid"])
  @default_process_rows_cache_ttl_ms 1_000

  @type memory_snapshot :: %{
          root_pid: pos_integer(),
          process_count: non_neg_integer(),
          rss_kb: non_neg_integer(),
          rss_bytes: non_neg_integer(),
          command: String.t() | nil
        }

  @spec current_process_tree_memory() :: memory_snapshot() | nil
  def current_process_tree_memory do
    with {root_pid, ""} when root_pid > 0 <- System.pid() |> String.trim() |> Integer.parse(),
         rows when is_list(rows) <- process_rows() do
      process_tree_memory(rows, root_pid)
    else
      _ -> nil
    end
  end

  @spec current_process_tree_memory([map()]) :: memory_snapshot() | nil
  def current_process_tree_memory(rows) when is_list(rows) do
    with {root_pid, ""} when root_pid > 0 <- System.pid() |> String.trim() |> Integer.parse() do
      rows
      |> normalize_rows()
      |> process_tree_memory(root_pid)
    else
      _ -> nil
    end
  end

  @spec workspace_preview_memory(Path.t() | nil) :: memory_snapshot() | nil
  def workspace_preview_memory(workspace) when is_binary(workspace) do
    with {:ok, root_pid} <- read_preview_pid(workspace),
         rows when is_list(rows) <- process_rows(),
         %{} = memory <- process_tree_memory(rows, root_pid) do
      memory
    else
      _ -> nil
    end
  end

  def workspace_preview_memory(_workspace), do: nil

  @spec workspace_preview_memory(Path.t() | nil, [map()]) :: memory_snapshot() | nil
  def workspace_preview_memory(workspace, rows) when is_binary(workspace) and is_list(rows) do
    with {:ok, root_pid} <- read_preview_pid(workspace),
         %{} = memory <- rows |> normalize_rows() |> process_tree_memory(root_pid) do
      memory
    else
      _ -> nil
    end
  end

  def workspace_preview_memory(_workspace, _rows), do: nil

  @spec process_rows() :: [map()]
  def process_rows do
    if process_rows_override_configured?() do
      read_process_rows()
    else
      process_rows(cache_ttl_ms: @default_process_rows_cache_ttl_ms)
    end
  end

  @spec process_rows(keyword()) :: [map()]
  def process_rows(opts) when is_list(opts) do
    cache_ttl_ms = Keyword.get(opts, :cache_ttl_ms, 0)

    if is_integer(cache_ttl_ms) and cache_ttl_ms > 0 do
      cached_process_rows(cache_ttl_ms)
    else
      read_process_rows()
    end
  rescue
    _ -> []
  end

  defp cached_process_rows(cache_ttl_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case Application.get_env(:symphony_elixir, :process_memory_ps_rows_cache) do
      %{cached_at_ms: cached_at_ms, rows: rows}
      when is_integer(cached_at_ms) and is_list(rows) and now_ms - cached_at_ms < cache_ttl_ms ->
        rows

      _ ->
        rows = read_process_rows()
        Application.put_env(:symphony_elixir, :process_memory_ps_rows_cache, %{cached_at_ms: now_ms, rows: rows})
        rows
    end
  end

  defp read_process_rows do
    cond do
      provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider) ->
        if is_function(provider, 0) do
          provider.() |> normalize_rows()
        else
          []
        end

      rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows) ->
        normalize_rows(rows)

      true ->
        system_process_rows()
    end
  rescue
    _ -> []
  end

  defp process_rows_override_configured? do
    Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider) ||
      Application.get_env(:symphony_elixir, :process_memory_ps_rows)
  end

  defp read_preview_pid(workspace) do
    pid_file = Path.join(workspace, @preview_pid_file)

    with {:ok, text} <- File.read(pid_file),
         {pid, rest} when pid > 0 <- text |> String.trim() |> Integer.parse(),
         true <- String.trim(rest) == "" do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  defp normalize_rows(rows) do
    rows
    |> Enum.map(&normalize_row/1)
    |> Enum.filter(&match?(%{pid: pid, ppid: ppid, rss_kb: rss} when is_integer(pid) and is_integer(ppid) and is_integer(rss), &1))
  end

  defp normalize_row(%{pid: pid, ppid: ppid, rss_kb: rss_kb} = row) do
    %{
      pid: pid,
      ppid: ppid,
      rss_kb: max(rss_kb, 0),
      command: Map.get(row, :command) || Map.get(row, "command")
    }
  end

  defp normalize_row(%{"pid" => pid, "ppid" => ppid, "rss_kb" => rss_kb} = row) do
    %{
      pid: pid,
      ppid: ppid,
      rss_kb: max(rss_kb, 0),
      command: Map.get(row, "command") || Map.get(row, :command)
    }
  end

  defp normalize_row(_row), do: nil

  defp system_process_rows do
    case System.cmd("ps", ["-axo", "pid=,ppid=,rss=,comm="], stderr_to_stdout: true) do
      {output, 0} -> parse_ps_output(output)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp parse_ps_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_ps_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_ps_line(line) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s*(.*)$/, line) do
      [_, pid, ppid, rss_kb, command] ->
        %{
          pid: String.to_integer(pid),
          ppid: String.to_integer(ppid),
          rss_kb: String.to_integer(rss_kb),
          command: String.trim(command)
        }

      _ ->
        nil
    end
  end

  defp process_tree_memory(rows, root_pid) do
    with %{} = root <- Enum.find(rows, &(Map.get(&1, :pid) == root_pid)) do
      descendants = process_tree_rows(rows, root_pid)
      rss_kb = descendants |> Enum.map(&Map.get(&1, :rss_kb, 0)) |> Enum.sum()

      %{
        root_pid: root_pid,
        process_count: length(descendants),
        rss_kb: rss_kb,
        rss_bytes: rss_kb * 1024,
        command: Map.get(root, :command)
      }
    end
  end

  defp process_tree_rows(rows, root_pid) do
    rows_by_pid = Map.new(rows, &{Map.get(&1, :pid), &1})
    children_by_parent = Enum.group_by(rows, &Map.get(&1, :ppid))

    collect_process_tree([root_pid], rows_by_pid, children_by_parent, MapSet.new(), [])
  end

  defp collect_process_tree([], _rows_by_pid, _children_by_parent, _seen, acc), do: Enum.reverse(acc)

  defp collect_process_tree([pid | rest], rows_by_pid, children_by_parent, seen, acc) do
    cond do
      MapSet.member?(seen, pid) ->
        collect_process_tree(rest, rows_by_pid, children_by_parent, seen, acc)

      row = Map.get(rows_by_pid, pid) ->
        child_pids =
          children_by_parent
          |> Map.get(pid, [])
          |> Enum.map(&Map.get(&1, :pid))
          |> Enum.reject(&is_nil/1)

        collect_process_tree(rest ++ child_pids, rows_by_pid, children_by_parent, MapSet.put(seen, pid), [row | acc])

      true ->
        collect_process_tree(rest, rows_by_pid, children_by_parent, MapSet.put(seen, pid), acc)
    end
  end
end
