defmodule SymphonyElixir.AgentProvider.AntigravityCli do
  @moduledoc """
  Runs Google Antigravity through the `agy` CLI print mode.
  """

  @behaviour SymphonyElixir.AgentProvider

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @conversation_patterns [
    ~r/Created conversation ([0-9A-Za-z_-]+(?:-[0-9A-Za-z_-]+)*)/,
    ~r/Print mode: conversation=([0-9A-Za-z_-]+(?:-[0-9A-Za-z_-]+)*)/
  ]
  # Keep provider-side log probes aligned with AgentRunner's one-second forwarding
  # throttle so remote workers do not spend memory/CPU on throwaway log events.
  @log_poll_interval_ms 1_000
  @stdout_tail_limit_bytes 64 * 1024
  @log_emit_limit_bytes 16 * 1024
  @log_read_limit_bytes @log_emit_limit_bytes
  @local_process_tree_stop_grace_ms 250
  @python_process_group_wrapper """
  import os
  import signal
  import sys
  import time

  child_pid = None

  def kill_child_group(signum=None, _frame=None):
      if child_pid:
          try:
              os.killpg(child_pid, signal.SIGTERM)
          except ProcessLookupError:
              pass
          except PermissionError:
              pass

          time.sleep(0.2)

          try:
              os.killpg(child_pid, signal.SIGKILL)
          except ProcessLookupError:
              pass
          except PermissionError:
              pass

      if signum is None:
          sys.exit(1)

      sys.exit(128 + signum)

  child_pid = os.fork()

  if child_pid == 0:
      os.setsid()
      os.execv(sys.argv[1], sys.argv[1:])

  for signal_number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
      signal.signal(signal_number, kill_child_group)

  try:
      _, status = os.waitpid(child_pid, 0)
  except KeyboardInterrupt:
      kill_child_group(signal.SIGINT, None)

  if os.WIFEXITED(status):
      sys.exit(os.WEXITSTATUS(status))

  if os.WIFSIGNALED(status):
      sys.exit(128 + os.WTERMSIG(status))

  sys.exit(1)
  """

  @type session :: %{
          state: pid(),
          metadata: map(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, _settings} <- Config.antigravity_cli_runtime_settings(),
         {:ok, state} <- Agent.start_link(fn -> %{conversation_id: nil, turn_count: 0, current_port: nil} end) do
      {:ok,
       %{
         state: state,
         metadata: metadata(worker_host),
         workspace: expanded_workspace,
         worker_host: worker_host
       }}
    end
  end

  @impl true
  def run_turn(%{state: state, metadata: metadata, workspace: workspace, worker_host: worker_host}, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    settings = Config.settings!().antigravity_cli
    turn_id = next_turn_id(state)
    conversation_id = conversation_id(state)
    log_file = log_file_path(workspace, turn_id, worker_host)

    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id(conversation_id, turn_id), thread_id: conversation_id || "antigravity-cli", turn_id: turn_id},
      metadata
    )

    case run_agy(settings, workspace, log_file, prompt, conversation_id, worker_host, on_message, metadata, turn_id, state) do
      {:ok, stdout_buffer, log_stream} ->
        stdout = stdout_buffer.tail
        parsed_conversation_id = log_stream.detected_conversation_id

        resolved_conversation_id = parsed_conversation_id || conversation_id
        reported_thread_id = resolved_conversation_id || "antigravity-cli"

        if is_binary(resolved_conversation_id) and resolved_conversation_id != "" do
          Agent.update(state, &%{&1 | conversation_id: resolved_conversation_id})
        end

        payload = %{
          "method" => "antigravity_cli/event/stdout",
          "params" => %{
            "text" => stdout,
            "stderr" => "",
            "text_bytes" => stdout_buffer.bytes,
            "stderr_bytes" => 0,
            "text_truncated" => stdout_buffer.truncated?,
            "log_file" => log_file,
            "conversation_id" => reported_thread_id
          }
        }

        emit_message(on_message, :notification, %{payload: payload, raw: stdout}, metadata)
        emit_message(on_message, :turn_completed, %{payload: %{"result" => "turn_completed", "turn_id" => turn_id}, raw: ""}, metadata)

        {:ok,
         %{
           result: stdout,
           session_id: "#{reported_thread_id}-#{turn_id}",
           thread_id: reported_thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        emit_message(on_message, :turn_failed, %{payload: %{"error" => inspect(reason)}, raw: ""}, metadata)
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{state: state}) when is_pid(state) do
    stop_current_port(state)
    Agent.stop(state, :normal)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  @spec append_stdout_tail_for_test(map(), binary()) :: map()
  def append_stdout_tail_for_test(output, chunk) do
    append_tail(output, chunk, @stdout_tail_limit_bytes)
  end

  defp run_agy(settings, workspace, log_file, prompt, conversation_id, nil, on_message, metadata, turn_id, state) do
    executable = System.find_executable(settings.command) || settings.command

    port = start_local_port(executable, args(settings, workspace, log_file, prompt, conversation_id), workspace)
    put_current_port(state, port)

    try do
      await_port(port, settings.turn_timeout_ms, output_buffer(), log_stream(log_file, nil, on_message, metadata, turn_id, conversation_id))
    after
      clear_current_port(state, port)
    end
  rescue
    error -> {:error, {:antigravity_cli_failed, error}}
  end

  defp run_agy(settings, workspace, log_file, prompt, conversation_id, worker_host, on_message, metadata, turn_id, state)
       when is_binary(worker_host) do
    command = remote_agy_command(settings, workspace, log_file, prompt, conversation_id)

    with {:ok, port} <- SSH.start_port(worker_host, command) do
      put_current_port(state, port)

      try do
        await_port(port, settings.turn_timeout_ms, output_buffer(), log_stream(log_file, worker_host, on_message, metadata, turn_id, conversation_id))
      after
        clear_current_port(state, port)
      end
    end
  end

  defp remote_agy_command(settings, workspace, log_file, prompt, conversation_id) do
    agy_command =
      Enum.map_join([settings.command | args(settings, workspace, log_file, prompt, conversation_id)], " ", &shell_escape/1)

    [
      "mkdir -p #{shell_escape(Path.dirname(log_file))}",
      "cd #{shell_escape(workspace)}",
      remote_process_tree_wrapper(agy_command)
    ]
    |> Enum.join(" && ")
  end

  defp remote_process_tree_wrapper(command) do
    [
      "kill_tree() {",
      "pid=\"$1\";",
      "[ -n \"$pid\" ] || return 0;",
      "for child in $(pgrep -P \"$pid\" 2>/dev/null); do kill_tree \"$child\"; done;",
      "kill -TERM -- \"-$pid\" 2>/dev/null || true;",
      "kill -TERM \"$pid\" 2>/dev/null || true;",
      "sleep 0.2;",
      "for child in $(pgrep -P \"$pid\" 2>/dev/null); do kill_tree \"$child\"; done;",
      "kill -KILL -- \"-$pid\" 2>/dev/null || true;",
      "kill -KILL \"$pid\" 2>/dev/null || true;",
      "};",
      "trap 'kill_tree \"$AGY_PID\"; exit 143' TERM INT HUP;",
      "if command -v setsid >/dev/null 2>&1; then setsid #{command} & else #{command} & fi;",
      "AGY_PID=$!;",
      "wait \"$AGY_PID\";",
      "AGY_STATUS=$?;",
      "trap - TERM INT HUP;",
      "exit \"$AGY_STATUS\""
    ]
    |> Enum.join(" ")
  end

  defp start_local_port(executable, args, workspace) do
    python = System.find_executable("python3") || "python3"

    Port.open(
      {:spawn_executable, String.to_charlist(python)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["-c", @python_process_group_wrapper, executable | args], &String.to_charlist/1),
        cd: String.to_charlist(workspace)
      ]
    )
  end

  defp await_port(port, timeout_ms, output, log_stream) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_port_until(port, deadline_ms, output, log_stream)
  end

  defp await_port_until(port, deadline_ms, output, log_stream) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        await_port_until(port, deadline_ms, append_tail(output, to_string(chunk), @stdout_tail_limit_bytes), log_stream)

      {^port, {:exit_status, 0}} ->
        log_stream = emit_new_log_activity(log_stream)
        {:ok, output, log_stream}

      {^port, {:exit_status, status}} ->
        _log_stream = emit_new_log_activity(log_stream)
        {:error, {:antigravity_cli_exit, status, output.tail}}
    after
      min(remaining_ms, @log_poll_interval_ms) ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          stop_local_process_tree(port)
          {:error, :turn_timeout}
        else
          await_port_until(port, deadline_ms, output, emit_new_log_activity(log_stream))
        end
    end
  end

  defp stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stop_local_process_tree(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        signal_process(os_pid, "TERM")
        Process.sleep(@local_process_tree_stop_grace_ms)
        signal_process(os_pid, "KILL")

      _ ->
        :ok
    end

    stop_port(port)
  end

  defp put_current_port(state, port) when is_pid(state) and is_port(port) do
    Agent.update(state, &Map.put(&1, :current_port, port))
  rescue
    _ -> :ok
  end

  defp clear_current_port(state, port) when is_pid(state) and is_port(port) do
    Agent.update(state, fn data ->
      if Map.get(data, :current_port) == port do
        Map.put(data, :current_port, nil)
      else
        data
      end
    end)
  rescue
    _ -> :ok
  end

  defp stop_current_port(state) when is_pid(state) do
    port = Agent.get(state, &Map.get(&1, :current_port))

    if is_port(port) do
      stop_local_process_tree(port)
    end
  rescue
    _ -> :ok
  end

  defp signal_process(os_pid, signal) when is_integer(os_pid) and is_binary(signal) do
    System.cmd("kill", ["-" <> signal, Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp args(settings, workspace, log_file, prompt, conversation_id) do
    []
    |> Kernel.++(["--log-file=#{log_file}"])
    |> Kernel.++(["--print-timeout=#{settings.print_timeout}"])
    |> Kernel.++(["--add-dir", workspace])
    |> maybe_add_auto_approval(settings.approval_policy)
    |> maybe_add_conversation(conversation_id)
    |> Kernel.++(["--print=#{goal_prompt(prompt)}"])
  end

  defp goal_prompt(prompt) when is_binary(prompt) do
    if String.starts_with?(String.trim_leading(prompt), "/goal") do
      prompt
    else
      "/goal " <> prompt
    end
  end

  defp maybe_add_auto_approval(args, "never"), do: args ++ ["--dangerously-skip-permissions"]
  defp maybe_add_auto_approval(args, _policy), do: args

  defp maybe_add_conversation(args, conversation_id) when is_binary(conversation_id) and conversation_id != "" do
    args ++ ["--conversation", conversation_id]
  end

  defp maybe_add_conversation(args, _conversation_id), do: args

  defp next_turn_id(state) do
    turn_count = Agent.get_and_update(state, fn data -> {data.turn_count + 1, %{data | turn_count: data.turn_count + 1}} end)
    "agy-turn-#{turn_count}"
  end

  defp conversation_id(state), do: Agent.get(state, & &1.conversation_id)

  defp session_id(nil, turn_id), do: "antigravity-cli-#{turn_id}"
  defp session_id(conversation_id, turn_id), do: "#{conversation_id}-#{turn_id}"

  defp log_file_path(workspace, turn_id, nil) do
    log_dir = Path.join(workspace, ".symphony")
    File.mkdir_p!(log_dir)
    Path.join(log_dir, "antigravity-cli-#{turn_id}.log")
  end

  defp log_file_path(workspace, turn_id, worker_host) when is_binary(worker_host) do
    Path.join([workspace, ".symphony", "antigravity-cli-#{turn_id}.log"])
  end

  defp output_buffer do
    %{tail: "", bytes: 0, truncated?: false}
  end

  defp append_tail(%{bytes: bytes} = output, "", _limit) do
    %{output | bytes: bytes}
  end

  defp append_tail(%{bytes: bytes}, chunk, limit) when is_binary(chunk) and byte_size(chunk) >= limit do
    %{
      tail: binary_tail(chunk, limit),
      bytes: bytes + byte_size(chunk),
      truncated?: true
    }
  end

  defp append_tail(%{tail: tail, bytes: bytes, truncated?: truncated?}, chunk, limit) when is_binary(chunk) do
    combined_bytes = byte_size(tail) + byte_size(chunk)

    if combined_bytes > limit do
      keep_from_tail = max(limit - byte_size(chunk), 0)
      combined = binary_tail(tail, keep_from_tail) <> chunk

      %{
        tail: binary_tail(combined, limit),
        bytes: bytes + byte_size(chunk),
        truncated?: true
      }
    else
      %{
        tail: tail <> chunk,
        bytes: bytes + byte_size(chunk),
        truncated?: truncated?
      }
    end
  end

  defp binary_tail(value, limit) when byte_size(value) > limit do
    value
    |> binary_part(byte_size(value) - limit, limit)
    |> :binary.copy()
  end

  defp binary_tail(_value, 0), do: ""
  defp binary_tail(value, limit) when byte_size(value) == limit, do: :binary.copy(value)
  defp binary_tail(value, _limit), do: value

  defp read_log_chunk(log_file, nil, offset) do
    case File.open(log_file, [:read, :binary]) do
      {:ok, file} ->
        try do
          size = file_size(file)
          offset = if offset <= size, do: offset, else: 0
          read_size = min(size - offset, @log_read_limit_bytes)

          if read_size > 0 do
            {:ok, _position} = :file.position(file, offset)
            chunk = IO.binread(file, read_size)
            text = if(is_binary(chunk), do: chunk, else: "")
            %{text: text, bytes: size - offset, offset: size}
          else
            %{text: "", bytes: 0, offset: offset}
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        %{text: "", bytes: 0, offset: offset}
    end
  end

  defp read_log_chunk(log_file, worker_host, offset) when is_binary(worker_host) do
    offset = max(offset, 0)

    command =
      [
        "if [ -f #{shell_escape(log_file)} ]; then",
        "size=$(wc -c < #{shell_escape(log_file)} 2>/dev/null | tr -d ' ');",
        "case \"$size\" in ''|*[!0-9]*) size=0 ;; esac;",
        "if [ \"$size\" -lt #{offset} ]; then offset=0; else offset=#{offset}; fi;",
        "printf '%s\\n' \"$size\";",
        "tail -c +$((offset + 1)) #{shell_escape(log_file)} 2>/dev/null | head -c #{@log_read_limit_bytes};",
        "fi"
      ]
      |> Enum.join(" ")

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {data, 0}} when is_binary(data) -> parse_remote_log_read(data, offset)
      _ -> %{text: "", bytes: 0, offset: offset}
    end
  end

  defp parse_remote_log_read(data, previous_offset) when is_binary(data) do
    case :binary.split(data, "\n") do
      [size_line, text] ->
        size = parse_non_negative_integer(size_line, previous_offset)
        offset = if previous_offset <= size, do: previous_offset, else: 0
        %{text: text, bytes: max(size - offset, 0), offset: size}

      [size_line] ->
        size = parse_non_negative_integer(size_line, previous_offset)
        offset = if previous_offset <= size, do: previous_offset, else: 0
        %{text: "", bytes: max(size - offset, 0), offset: size}
    end
  end

  defp parse_non_negative_integer(value, fallback) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {integer, ""} when integer >= 0 -> integer
      _ -> fallback
    end
  end

  defp file_size(file) do
    {:ok, position} = :file.position(file, :cur)
    {:ok, size} = :file.position(file, :eof)
    {:ok, ^position} = :file.position(file, position)
    size
  end

  defp log_stream(log_file, worker_host, on_message, metadata, turn_id, conversation_id) do
    %{
      log_file: log_file,
      worker_host: worker_host,
      on_message: on_message,
      metadata: metadata,
      turn_id: turn_id,
      thread_id: conversation_id || "antigravity-cli",
      offset: 0,
      detected_conversation_id: nil
    }
  end

  defp emit_new_log_activity(%{log_file: log_file, worker_host: worker_host, offset: offset} = stream) do
    %{text: chunk, bytes: bytes, offset: new_offset} = read_log_chunk(log_file, worker_host, offset)

    if chunk != "" or bytes > 0 do
      normalized_chunk = normalize_log_chunk(chunk)
      detected_conversation_id = extract_conversation_id(normalized_chunk) || stream.detected_conversation_id
      emit_log_chunk(stream, normalized_chunk, bytes)
      %{stream | offset: new_offset, detected_conversation_id: detected_conversation_id}
    else
      stream
    end
  end

  defp emit_log_chunk(_stream, "", 0), do: :ok

  defp emit_log_chunk(%{on_message: on_message, metadata: metadata, log_file: log_file, turn_id: turn_id, thread_id: thread_id}, text, bytes) do
    {bounded_text, truncated?} = bounded_head(text, @log_emit_limit_bytes)
    text_bytes = max(bytes, byte_size(text))

    payload = %{
      "method" => "antigravity_cli/event/log",
      "params" => %{
        "text" => bounded_text,
        "text_bytes" => text_bytes,
        "text_truncated" => truncated? or text_bytes > byte_size(bounded_text),
        "log_file" => log_file,
        "turn_id" => turn_id,
        "conversation_id" => thread_id
      }
    }

    emit_message(on_message, :notification, %{payload: payload, raw: bounded_text}, metadata)
    :ok
  end

  defp bounded_head(value, limit) when is_binary(value) and byte_size(value) > limit do
    {value |> binary_part(0, limit) |> :binary.copy(), true}
  end

  defp bounded_head(value, _limit), do: {value, false}

  defp normalize_log_chunk(chunk) when is_binary(chunk) do
    :binary.replace(chunk, <<0>>, "", [:global])
  end

  defp extract_conversation_id(log_text) when is_binary(log_text) do
    Enum.find_value(@conversation_patterns, fn pattern ->
      case Regex.run(pattern, log_text, capture: :all_but_first) do
        [conversation_id | _] -> :binary.copy(conversation_id)
        _ -> nil
      end
    end)
  end

  defp emit_message(on_message, event, payload, metadata) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: metadata
    })
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp metadata(worker_host) do
    base = %{provider: "antigravity_cli"}

    case worker_host do
      host when is_binary(host) -> Map.put(base, :worker_host, host)
      _ -> base
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(message), do: Logger.debug("Antigravity CLI event: #{inspect(message)}")
end
