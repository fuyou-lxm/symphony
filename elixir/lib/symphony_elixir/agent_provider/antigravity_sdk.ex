defmodule SymphonyElixir.AgentProvider.AntigravitySdk do
  @moduledoc """
  Runs Antigravity SDK through a small JSONL Python bridge.
  """

  @behaviour SymphonyElixir.AgentProvider

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @impl true
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, settings} <- Config.antigravity_runtime_settings(),
         {:ok, port} <- start_port(expanded_workspace, worker_host, settings) do
      metadata = port_metadata(port, worker_host)

      start_payload =
        settings
        |> Map.take([:model, :api_key, :app_data_dir, :save_dir, :approval_policy])
        |> Map.put(:op, "start")
        |> Map.put(:cwd, expanded_workspace)

      send_message(port, start_payload)

      case await_bridge_event(port, settings.read_timeout_ms, "") do
        {:ok, %{"event" => "session_started"} = payload} ->
          thread_id = payload["thread_id"] || payload["session_id"] || "antigravity-session"

          {:ok,
           %{
             port: port,
             metadata: Map.merge(metadata, normalize_metadata(payload["metadata"])),
             thread_id: thread_id,
             workspace: expanded_workspace,
             worker_host: worker_host
           }}

        {:ok, payload} ->
          stop_port(port)
          {:error, {:invalid_antigravity_startup_event, payload}}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @impl true
  def run_turn(%{port: port, metadata: metadata, thread_id: thread_id}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    settings = Config.settings!().antigravity
    turn_id = "turn-#{System.unique_integer([:positive])}"

    emit_message(
      on_message,
      :session_started,
      %{session_id: "#{thread_id}-#{turn_id}", thread_id: thread_id, turn_id: turn_id},
      metadata
    )

    send_message(port, %{
      op: "turn",
      prompt: prompt,
      issue: issue_payload(issue),
      title: issue_title(issue)
    })

    case await_turn_completion(port, on_message, metadata, settings.turn_timeout_ms, "", thread_id, turn_id) do
      {:ok, result} ->
        final_turn_id = Map.get(result, :turn_id, turn_id)

        {:ok,
         %{
           result: Map.get(result, :result, :turn_completed),
           session_id: "#{thread_id}-#{final_turn_id}",
           thread_id: thread_id,
           turn_id: final_turn_id
         }}

      {:error, reason} ->
        emit_message(on_message, :turn_ended_with_error, %{session_id: "#{thread_id}-#{turn_id}", reason: reason}, metadata)
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{port: port}) when is_port(port) do
    send_message(port, %{op: "stop"})
    stop_port(port)
  end

  defp start_port(workspace, nil, %{python: python, runner: runner}) do
    executable = System.find_executable(python) || python

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [String.to_charlist(runner)],
          cd: String.to_charlist(workspace),
          line: @port_line_bytes
        ]
      )

    {:ok, port}
  end

  defp start_port(workspace, worker_host, %{python: python, runner: runner}) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        "exec #{shell_escape(python)} #{shell_escape(runner)}"
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp await_turn_completion(port, on_message, metadata, timeout_ms, pending_line, thread_id, fallback_turn_id) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        case decode_bridge_line(complete_line) do
          {:ok, %{"event" => "turn_completed"} = payload} ->
            emit_message(on_message, :turn_completed, event_payload(payload), metadata)

            {:ok,
             %{
               turn_id: payload["turn_id"] || fallback_turn_id,
               result: payload["result"] || :turn_completed
             }}

          {:ok, %{"event" => "turn_failed"} = payload} ->
            emit_message(on_message, :turn_failed, event_payload(payload), metadata)
            {:error, {:turn_failed, payload}}

          {:ok, %{"event" => "turn_input_required"} = payload} ->
            emit_message(on_message, :turn_input_required, event_payload(payload), metadata)
            {:error, {:turn_input_required, payload}}

          {:ok, %{"event" => "approval_required"} = payload} ->
            emit_message(on_message, :approval_required, event_payload(payload), metadata)
            {:error, {:approval_required, payload}}

          {:ok, %{"event" => "token_count"} = payload} ->
            emit_message(on_message, :notification, token_count_payload(payload, thread_id), metadata)
            await_turn_completion(port, on_message, metadata, timeout_ms, "", thread_id, fallback_turn_id)

          {:ok, %{"event" => "notification"} = payload} ->
            emit_message(on_message, :notification, notification_payload(payload), metadata)
            await_turn_completion(port, on_message, metadata, timeout_ms, "", thread_id, fallback_turn_id)

          {:ok, payload} ->
            emit_message(on_message, :notification, notification_payload(payload), metadata)
            await_turn_completion(port, on_message, metadata, timeout_ms, "", thread_id, fallback_turn_id)

          {:error, :non_json} ->
            log_non_json_stream_line(complete_line)
            await_turn_completion(port, on_message, metadata, timeout_ms, "", thread_id, fallback_turn_id)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_turn_completion(port, on_message, metadata, timeout_ms, pending_line <> to_string(chunk), thread_id, fallback_turn_id)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp await_bridge_event(port, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        chunk
        |> then(&(pending_line <> to_string(&1)))
        |> decode_bridge_line()
        |> case do
          {:ok, payload} ->
            {:ok, payload}

          {:error, :non_json} ->
            await_bridge_event(port, timeout_ms, "")
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_bridge_event(port, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp send_message(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp decode_bridge_line(line) do
    case Jason.decode(to_string(line)) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :non_json}
    end
  end

  defp token_count_payload(payload, thread_id) do
    %{
      payload: %{
        "method" => "codex/event/token_count",
        "msg" => %{
          "thread_id" => thread_id,
          "input_tokens" => payload["input_tokens"] || 0,
          "output_tokens" => payload["output_tokens"] || 0,
          "total_tokens" => payload["total_tokens"] || 0,
          "seconds_running" => payload["seconds_running"] || 0
        }
      },
      raw: Jason.encode!(payload)
    }
  end

  defp notification_payload(%{"method" => method, "params" => params} = payload) do
    %{payload: %{"method" => method, "params" => params}, raw: Jason.encode!(payload)}
  end

  defp notification_payload(%{"method" => method} = payload) do
    %{payload: %{"method" => method, "params" => Map.get(payload, "params", %{})}, raw: Jason.encode!(payload)}
  end

  defp notification_payload(payload) do
    %{payload: %{"method" => "antigravity/event/message", "params" => payload}, raw: Jason.encode!(payload)}
  end

  defp event_payload(payload), do: %{payload: payload, raw: Jason.encode!(payload), details: payload}

  defp emit_message(on_message, event, payload, metadata) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: metadata
    })
  end

  defp issue_payload(issue) when is_map(issue) do
    %{
      id: Map.get(issue, :id) || Map.get(issue, "id"),
      identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      title: Map.get(issue, :title) || Map.get(issue, "title"),
      state: Map.get(issue, :state) || Map.get(issue, "state"),
      url: Map.get(issue, :url) || Map.get(issue, "url"),
      labels: Map.get(issue, :labels) || Map.get(issue, "labels") || []
    }
  end

  defp issue_payload(_issue), do: %{}

  defp issue_title(issue) do
    payload = issue_payload(issue)
    Enum.join(Enum.reject([payload.identifier, payload.title], &is_nil/1), ": ")
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

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc -> Map.put(acc, normalize_metadata_key(key), value) end)
  end

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_metadata_key(key) when is_atom(key), do: key

  defp normalize_metadata_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      Logger.debug("Antigravity SDK stream output: #{text}")
    end
  end

  defp stop_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(message), do: Logger.debug("Antigravity SDK event: #{inspect(message)}")
end
