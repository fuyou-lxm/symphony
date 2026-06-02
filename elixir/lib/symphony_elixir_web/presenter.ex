defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProcessMemory, StatusDashboard}
  alias SymphonyElixirWeb.{ObservabilitySampler, ObservabilityStateCache}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    case ObservabilitySampler.latest_payload(orchestrator, snapshot_timeout_ms) do
      {:ok, payload} ->
        payload

      :unavailable ->
        cached_state_payload(orchestrator, snapshot_timeout_ms)
    end
  end

  defp cached_state_payload(orchestrator, snapshot_timeout_ms) do
    cache_key = {:state_payload, orchestrator, snapshot_timeout_ms}

    ObservabilityStateCache.fetch_or_store(cache_key, state_cache_ttl_ms(), state_cache_call_timeout(snapshot_timeout_ms), fn ->
      build_state_payload(orchestrator, snapshot_timeout_ms)
    end)
  end

  @doc false
  @spec build_state_payload(GenServer.name(), timeout()) :: map()
  def build_state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        process_rows = ProcessMemory.process_rows()
        running = Enum.map(snapshot.running, &running_entry_payload(&1, process_rows))

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            external_waiting: length(Map.get(snapshot, :external_waiting, [])),
            recent_external_finalizations: length(Map.get(snapshot, :recent_external_finalizations, []))
          },
          running: running,
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          external_waiting: Enum.map(Map.get(snapshot, :external_waiting, []), &external_waiting_entry_payload/1),
          recent_external_finalizations: Enum.map(Map.get(snapshot, :recent_external_finalizations, []), &recent_external_finalization_payload/1),
          codex_totals: snapshot.codex_totals,
          process_memory: process_memory_summary(running, process_rows),
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp state_cache_ttl_ms do
    Config.settings!().observability.refresh_ms
    |> min(1_000)
  rescue
    _ -> 1_000
  end

  defp state_cache_call_timeout(:infinity), do: :infinity
  defp state_cache_call_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: timeout_ms + 5_000
  defp state_cache_call_timeout(_timeout_ms), do: 16_000

  @spec memory_payload(GenServer.name(), timeout()) :: map()
  def memory_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.counts_snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        process_rows = ProcessMemory.process_rows()
        preview_workspaces = Map.get(snapshot, :running_preview_workspaces, [])
        previews = Enum.map(preview_workspaces, &ProcessMemory.workspace_preview_memory(&1, process_rows)) |> Enum.reject(&is_nil/1)

        %{
          generated_at: generated_at,
          counts: Map.get(snapshot, :counts, %{}),
          process_memory: process_memory_summary_from_previews(previews, process_rows)
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case issue_payload_from_latest_state(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, payload} -> {:ok, payload}
      :unavailable -> issue_payload_from_snapshot(issue_identifier, orchestrator, snapshot_timeout_ms)
    end
  end

  defp issue_payload_from_latest_state(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case ObservabilitySampler.latest_payload(orchestrator, snapshot_timeout_ms) do
      {:ok, %{error: _error}} ->
        :unavailable

      {:ok, %{} = state_payload} ->
        issue_payload_from_state(issue_identifier, state_payload)

      :unavailable ->
        :unavailable
    end
  end

  defp issue_payload_from_snapshot(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))
        external_waiting = Enum.find(Map.get(snapshot, :external_waiting, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) and is_nil(external_waiting) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked, external_waiting)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp issue_payload_from_state(issue_identifier, state_payload) do
    running = find_state_issue(state_payload, :running, issue_identifier)
    retry = find_state_issue(state_payload, :retrying, issue_identifier)
    blocked = find_state_issue(state_payload, :blocked, issue_identifier)
    external_waiting = find_state_issue(state_payload, :external_waiting, issue_identifier)

    if is_nil(running) and is_nil(retry) and is_nil(blocked) and is_nil(external_waiting),
      do: :unavailable,
      else: {:ok, issue_payload_body_from_state(issue_identifier, running, retry, blocked, external_waiting)}
  end

  defp find_state_issue(state_payload, key, issue_identifier) do
    state_payload
    |> Map.get(key, [])
    |> Enum.find(&(Map.get(&1, :issue_identifier) == issue_identifier))
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, external_waiting) do
    entries = %{
      running: running,
      retry: retry,
      blocked: blocked,
      external_waiting: external_waiting
    }

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(entries),
      status: issue_status(entries),
      workspace: workspace_payload(issue_identifier, entries),
      attempts: attempts_payload(retry),
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      external_waiting: external_waiting && external_waiting_issue_payload(external_waiting),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: last_error(entries),
      tracked: %{}
    }
  end

  defp issue_payload_body_from_state(issue_identifier, running, retry, blocked, external_waiting) do
    entries = %{
      running: running,
      retry: retry,
      blocked: blocked,
      external_waiting: external_waiting
    }

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(entries),
      status: issue_status(entries),
      workspace: workspace_payload(issue_identifier, entries),
      attempts: attempts_payload(retry),
      running: running && running_issue_payload_from_state(running),
      retry: retry && retry_issue_payload_from_state(retry),
      blocked: blocked && blocked_issue_payload_from_state(blocked),
      external_waiting: external_waiting && external_waiting_issue_payload_from_state(external_waiting),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload_from_state(running || blocked),
      last_error: last_error(entries),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(entries) do
    entry_value(entries, :issue_id, [:running, :retry, :blocked, :external_waiting])
  end

  defp workspace_payload(issue_identifier, entries) do
    %{
      path: workspace_path(issue_identifier, entries),
      host: workspace_host(entries)
    }
  end

  defp attempts_payload(retry) do
    %{
      restart_count: restart_count(retry),
      current_retry_attempt: retry_attempt(retry)
    }
  end

  defp last_error(entries) do
    entry_value(entries, :error, [:blocked, :external_waiting, :retry])
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(%{running: running}) when not is_nil(running), do: "running"
  defp issue_status(%{retry: retry}) when not is_nil(retry), do: "retrying"
  defp issue_status(%{blocked: blocked}) when not is_nil(blocked), do: "blocked"
  defp issue_status(%{external_waiting: _external_waiting}), do: "external_waiting"

  defp running_entry_payload(entry, process_rows) do
    payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }

    maybe_put_running_process_memory(payload, entry, process_rows)
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp external_waiting_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      linear_state: entry.state,
      provider: entry.provider,
      change_request: entry.change_request_id,
      cr_status: entry.cr_status,
      revision: entry.revision,
      observed_key: entry.observed_key,
      token_policy: token_policy(entry.token_policy),
      next_action: next_action(entry.next_action),
      error: entry.error,
      waiting_since: iso8601(entry.waiting_since),
      last_checked_at: iso8601(entry.last_checked_at),
      url: entry.url
    }
  end

  defp recent_external_finalization_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      linear_state: entry.state,
      provider: entry.provider,
      change_request: entry.change_request_id,
      cr_status: entry.cr_status,
      revision: entry.revision,
      observed_key: entry.observed_key,
      target_state: entry.target_state,
      reason: external_reason(entry.reason),
      token_policy: token_policy(entry.token_policy),
      workspace_cleanup: external_reason(entry.workspace_cleanup),
      finalized_at: iso8601(entry.finalized_at),
      url: entry.url
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp external_waiting_issue_payload(external_waiting) do
    %{
      linear_state: external_waiting.state,
      provider: external_waiting.provider,
      change_request: external_waiting.change_request_id,
      cr_status: external_waiting.cr_status,
      revision: external_waiting.revision,
      observed_key: external_waiting.observed_key,
      token_policy: token_policy(external_waiting.token_policy),
      next_action: next_action(external_waiting.next_action),
      error: external_waiting.error,
      waiting_since: iso8601(external_waiting.waiting_since),
      last_checked_at: iso8601(external_waiting.last_checked_at),
      url: external_waiting.url
    }
  end

  defp running_issue_payload_from_state(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: Map.get(running, :session_id),
      turn_count: Map.get(running, :turn_count, 0),
      state: Map.get(running, :state),
      started_at: Map.get(running, :started_at),
      last_event: Map.get(running, :last_event),
      last_message: Map.get(running, :last_message),
      last_event_at: Map.get(running, :last_event_at),
      tokens: Map.get(running, :tokens, %{input_tokens: 0, output_tokens: 0, total_tokens: 0})
    }
  end

  defp retry_issue_payload_from_state(retry) do
    %{
      attempt: Map.get(retry, :attempt),
      due_at: Map.get(retry, :due_at),
      error: Map.get(retry, :error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload_from_state(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: Map.get(blocked, :session_id),
      state: Map.get(blocked, :state),
      error: Map.get(blocked, :error),
      blocked_at: Map.get(blocked, :blocked_at),
      last_event: Map.get(blocked, :last_event),
      last_message: Map.get(blocked, :last_message),
      last_event_at: Map.get(blocked, :last_event_at)
    }
  end

  defp external_waiting_issue_payload_from_state(external_waiting) do
    %{
      linear_state: Map.get(external_waiting, :linear_state),
      provider: Map.get(external_waiting, :provider),
      change_request: Map.get(external_waiting, :change_request),
      cr_status: Map.get(external_waiting, :cr_status),
      revision: Map.get(external_waiting, :revision),
      observed_key: Map.get(external_waiting, :observed_key),
      token_policy: Map.get(external_waiting, :token_policy),
      next_action: Map.get(external_waiting, :next_action),
      error: Map.get(external_waiting, :error),
      waiting_since: Map.get(external_waiting, :waiting_since),
      last_checked_at: Map.get(external_waiting, :last_checked_at),
      url: Map.get(external_waiting, :url)
    }
  end

  defp maybe_put_running_process_memory(payload, entry, process_rows) do
    case ProcessMemory.workspace_preview_memory(Map.get(entry, :workspace_path), process_rows) do
      nil -> payload
      preview -> Map.put(payload, :process_memory, %{preview: preview})
    end
  end

  defp process_memory_summary(running_payloads, process_rows) when is_list(running_payloads) do
    previews =
      running_payloads
      |> Enum.map(&get_in(&1, [:process_memory, :preview]))
      |> Enum.reject(&is_nil/1)

    process_memory_summary_from_previews(previews, process_rows)
  end

  defp process_memory_summary_from_previews(previews, process_rows) when is_list(previews) do
    %{
      running_preview_rss_kb: previews |> Enum.map(&Map.get(&1, :rss_kb, 0)) |> Enum.sum(),
      running_preview_rss_bytes: previews |> Enum.map(&Map.get(&1, :rss_bytes, 0)) |> Enum.sum(),
      running_preview_process_count: previews |> Enum.map(&Map.get(&1, :process_count, 0)) |> Enum.sum()
    }
    |> maybe_put_symphony_process_tree_memory(process_rows)
  end

  defp maybe_put_symphony_process_tree_memory(payload, process_rows) do
    case ProcessMemory.current_process_tree_memory(process_rows) do
      nil ->
        payload

      memory ->
        payload
        |> Map.put(:symphony_process_tree, memory)
        |> Map.put(:symphony_process_tree_rss_kb, Map.get(memory, :rss_kb, 0))
        |> Map.put(:symphony_process_tree_rss_bytes, Map.get(memory, :rss_bytes, 0))
        |> Map.put(:symphony_process_tree_process_count, Map.get(memory, :process_count, 0))
    end
  end

  defp workspace_path(issue_identifier, entries) do
    entry_value(entries, :workspace_path, [:running, :retry, :blocked]) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(entries) do
    entry_value(entries, :worker_host, [:running, :retry, :blocked])
  end

  defp entry_value(entries, key, priorities) do
    priorities
    |> Enum.map(&Map.get(entries, &1))
    |> Enum.find_value(fn
      nil -> nil
      entry -> Map.get(entry, key)
    end)
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp recent_events_payload_from_state(nil), do: []

  defp recent_events_payload_from_state(entry) do
    [
      %{
        at: Map.get(entry, :last_event_at),
        event: Map.get(entry, :last_event),
        message: Map.get(entry, :last_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp token_policy(:no_codex), do: "no_codex"
  defp token_policy(policy) when is_binary(policy), do: policy
  defp token_policy(policy) when is_atom(policy), do: Atom.to_string(policy)
  defp token_policy(_policy), do: nil

  defp next_action(action) when is_atom(action), do: Atom.to_string(action)
  defp next_action(action) when is_binary(action), do: action
  defp next_action(_action), do: nil

  defp external_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp external_reason(reason) when is_binary(reason), do: reason
  defp external_reason(reason) when is_nil(reason), do: nil
  defp external_reason(reason), do: to_string(reason)
end
