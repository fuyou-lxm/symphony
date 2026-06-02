defmodule SymphonyElixir.ExternalMergeWatcher do
  @moduledoc """
  Lightweight external merge watcher for no-auto-Codex states.

  The watcher reads machine-readable delivery metadata, checks the external
  Codeup change request without starting Codex, and reports terminal external
  state to the orchestrator for deterministic no-token finalization.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Codeup.Client, as: CodeupClient
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @merged_statuses MapSet.new(["merged"])
  @terminal_failure_statuses MapSet.new(["closed", "close", "canceled", "cancelled", "merge_failed", "failed", "rejected"])
  @default_interval_ms 30_000

  defmodule State do
    @moduledoc false
    defstruct [:timer_ref, interval_ms: 30_000, checker: nil]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %State{
      interval_ms: Keyword.get(opts, :interval_ms, configured_interval_ms()),
      checker: Keyword.get(opts, :checker, &check_blocked_issues/0)
    }

    {:ok, schedule_check(state, 0)}
  end

  @impl true
  def handle_info(:check_external_merge_state, %State{} = state) do
    _summary = safe_run_checker(state.checker)
    {:noreply, schedule_check(state, state.interval_ms)}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  @spec delivery_metadata(Issue.t()) :: {:ok, map()} | {:error, term()}
  def delivery_metadata(%Issue{} = issue) do
    issue
    |> metadata_sources()
    |> parse_delivery_metadata_sources()
  end

  @spec check_issue(Issue.t(), keyword()) ::
          {:changed, map(), map()} | {:unchanged, map()} | {:ignored, term()} | {:error, term()}
  def check_issue(%Issue{} = issue, opts \\ []) do
    with {:ok, metadata} <- delivery_metadata_for_check(issue, opts),
         {:ok, raw_change_request} <- fetch_change_request(metadata, opts),
         {:ok, observation} <- observation(metadata, raw_change_request) do
      classify_observation(metadata, observation, Keyword.get(opts, :observed_key))
    else
      {:error, :metadata_missing} -> {:ignored, :metadata_missing}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_external_merge_watch_result, other}}
    end
  end

  @spec check_blocked_issues(keyword()) :: map()
  def check_blocked_issues(opts \\ []) do
    with {:ok, states} <- no_auto_codex_states_for_watch(),
         false <- states == [],
         {:ok, issues} <- safe_fetch_issues_by_states(states) do
      Enum.reduce(issues, empty_check_summary(), fn issue, summary ->
        check_blocked_issue(issue, summary, opts)
      end)
    else
      true ->
        empty_check_summary()

      {:error, reason} ->
        Logger.warning("External merge watcher skipped check: #{inspect(reason)}")
        %{empty_check_summary() | errors: 1}
    end
  end

  defp check_blocked_issue(%Issue{} = issue, summary, opts) do
    result = check_issue(issue, Keyword.put_new(opts, :fetch_tracker_comments, true))

    case result do
      {:changed, _observation, event_metadata} ->
        orchestrator = Keyword.get(opts, :orchestrator, &SymphonyElixir.Orchestrator.external_state_changed/2)
        _reply = orchestrator.(issue.id, event_metadata)
        %{summary | checked: summary.checked + 1, changed: summary.changed + 1}

      {:unchanged, _observation} ->
        %{summary | checked: summary.checked + 1, unchanged: summary.unchanged + 1}

      {:ignored, _reason} ->
        %{summary | checked: summary.checked + 1, ignored: summary.ignored + 1}

      {:error, reason} ->
        Logger.warning("External merge watcher issue check failed for #{issue.identifier || issue.id}: #{inspect(reason)}")
        %{summary | checked: summary.checked + 1, errors: summary.errors + 1}
    end
  end

  defp check_blocked_issue(_issue, summary, _opts), do: summary

  defp empty_check_summary do
    %{checked: 0, changed: 0, unchanged: 0, ignored: 0, errors: 0}
  end

  defp safe_run_checker(checker) when is_function(checker, 0) do
    checker.()
  rescue
    exception ->
      Logger.warning("External merge watcher check crashed: #{Exception.message(exception)}")
      %{empty_check_summary() | errors: 1}
  catch
    kind, reason ->
      Logger.warning("External merge watcher check exited: #{inspect({kind, reason})}")
      %{empty_check_summary() | errors: 1}
  end

  defp no_auto_codex_states_for_watch do
    case Config.settings() do
      {:ok, settings} ->
        states =
          (settings.agent.no_auto_codex_states ++ settings.agent.no_continuation_retry_states)
          |> Enum.uniq()

        {:ok, states}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_fetch_issues_by_states(states) do
    Tracker.fetch_issues_by_states(states)
  rescue
    exception -> {:error, {:tracker_fetch_crashed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:tracker_fetch_exited, kind, reason}}
  end

  defp schedule_check(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.timer_ref) do
      Process.cancel_timer(state.timer_ref)
    end

    %{state | timer_ref: Process.send_after(self(), :check_external_merge_state, delay_ms)}
  end

  defp configured_interval_ms do
    case Application.get_env(:symphony_elixir, :external_merge_watcher_interval_ms, @default_interval_ms) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 -> interval_ms
      _ -> @default_interval_ms
    end
  end

  defp delivery_metadata_for_check(%Issue{} = issue, opts) do
    case delivery_metadata(issue) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, :metadata_missing} ->
        if Keyword.get(opts, :fetch_tracker_comments, false) do
          delivery_metadata_from_tracker_comments(issue)
        else
          {:error, :metadata_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delivery_metadata_from_tracker_comments(%Issue{id: issue_id}) when is_binary(issue_id) do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} -> delivery_metadata_from_comments(comments)
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_metadata_from_tracker_comments(_issue), do: {:error, :metadata_missing}

  defp delivery_metadata_from_comments(comments) do
    Enum.find_value(comments, {:error, :metadata_missing}, fn body ->
      body
      |> delivery_metadata_from_comment_body()
      |> metadata_result()
    end)
  end

  defp delivery_metadata_from_comment_body(body) do
    delivery_metadata(%Issue{description: body})
  end

  defp metadata_result({:ok, metadata}), do: {:ok, metadata}
  defp metadata_result({:error, _reason}), do: nil

  defp metadata_sources(%Issue{description: description}) when is_binary(description) do
    [description]
  end

  defp metadata_sources(_issue), do: []

  defp parse_delivery_metadata_sources(sources) do
    sources
    |> Enum.flat_map(&json_blocks/1)
    |> Enum.find_value({:error, :metadata_missing}, fn json ->
      with {:ok, decoded} <- Jason.decode(json),
           {:ok, metadata} <- normalize_delivery_metadata(decoded) do
        {:ok, metadata}
      else
        _ -> nil
      end
    end)
  end

  defp json_blocks(text) when is_binary(text) do
    ~r/```(?:json|JSON)\s*(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp normalize_delivery_metadata(raw_metadata) when is_map(raw_metadata) do
    provider = raw_metadata |> pick_string(["provider", :provider]) |> normalize_provider()

    if provider == "codeup" do
      with {:ok, organization_id} <-
             required_string(raw_metadata, ["organization_id", "organizationId", :organization_id, :organizationId]),
           {:ok, repository_id} <- required_string(raw_metadata, ["repository_id", "repo_id", :repository_id, :repo_id]),
           {:ok, change_request_id} <-
             required_string(raw_metadata, [
               "change_request_id",
               "local_id",
               "localId",
               :change_request_id,
               :local_id,
               :localId
             ]) do
        {:ok,
         %{
           provider: "codeup",
           domain: pick_string(raw_metadata, ["domain", :domain]),
           organization_id: organization_id,
           repository_id: repository_id,
           change_request_id: change_request_id,
           source_branch: pick_string(raw_metadata, ["source_branch", "sourceBranch", :source_branch, :sourceBranch]),
           target_branch: pick_string(raw_metadata, ["target_branch", "targetBranch", :target_branch, :targetBranch]),
           delivery_commit: pick_string(raw_metadata, ["delivery_commit", "deliveryCommit", :delivery_commit, :deliveryCommit]),
           last_observed_status:
             pick_string(raw_metadata, [
               "last_observed_cr_state",
               "last_observed_status",
               "lastObservedCrState",
               :last_observed_cr_state,
               :last_observed_status,
               :lastObservedCrState
             ]),
           last_observed_revision:
             pick_string(raw_metadata, [
               "last_observed_revision",
               "lastObservedRevision",
               :last_observed_revision,
               :lastObservedRevision
             ])
         }}
      end
    else
      {:error, :metadata_missing}
    end
  end

  defp normalize_delivery_metadata(_raw_metadata), do: {:error, :metadata_missing}

  defp required_string(metadata, keys) do
    case pick_string(metadata, keys) do
      nil -> {:error, :metadata_missing}
      value -> {:ok, value}
    end
  end

  defp pick_string(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      metadata
      |> Map.get(key)
      |> normalize_optional_string()
    end)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(_value), do: nil

  defp normalize_downcase(nil), do: nil

  defp normalize_downcase(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_provider(value) do
    case normalize_downcase(value) do
      provider when provider in ["codeup", "yunxiao_codeup", "yunxiao-codeup", "yunxiao codeup"] -> "codeup"
      provider -> provider
    end
  end

  defp fetch_change_request(metadata, opts) do
    client = Keyword.get(opts, :client, &CodeupClient.fetch_change_request/1)
    client.(metadata)
  end

  defp observation(metadata, raw_change_request) when is_map(raw_change_request) do
    status = change_request_status(raw_change_request)

    case status do
      nil ->
        {:error, :codeup_status_missing}

      status ->
        revision = change_request_revision(raw_change_request)
        updated_at = change_request_updated_at(raw_change_request)

        {:ok,
         %{
           provider: metadata.provider,
           organization_id: metadata.organization_id,
           repository_id: metadata.repository_id,
           change_request_id: metadata.change_request_id,
           status: status,
           revision: revision,
           updated_at: updated_at,
           url: change_request_url(raw_change_request),
           observed_key: observed_key(metadata, status, revision),
           outcome: observation_outcome(status)
         }}
    end
  end

  defp observation(_metadata, _raw_change_request), do: {:error, :codeup_unexpected_body}

  defp change_request_status(change_request) do
    pick_nested_string(change_request, [
      ["status"],
      ["state"],
      ["mergeStatus"],
      ["merge_status"],
      ["changeRequestStatus"],
      ["change_request_status"],
      ["result", "status"],
      ["result", "state"]
    ])
  end

  defp change_request_revision(change_request) do
    pick_nested_string(change_request, [
      ["mergedRevision"],
      ["mergeRevision"],
      ["mergeCommitSha"],
      ["merge_commit_sha"],
      ["targetRevision"],
      ["sourceRevision"],
      ["sourceCommit"],
      ["latestCommit"],
      ["latestPatchSet", "revision"],
      ["patchSet", "revision"],
      ["result", "mergedRevision"],
      ["result", "mergeCommitSha"]
    ])
  end

  defp change_request_updated_at(change_request) do
    pick_nested_string(change_request, [
      ["updatedAt"],
      ["updateTime"],
      ["gmtModified"],
      ["gmtModifiedTime"],
      ["result", "updatedAt"],
      ["result", "updateTime"]
    ])
  end

  defp change_request_url(change_request) do
    pick_nested_string(change_request, [
      ["webUrl"],
      ["web_url"],
      ["url"],
      ["detailUrl"],
      ["result", "webUrl"],
      ["result", "url"]
    ])
  end

  defp pick_nested_string(map, paths) when is_map(map) do
    Enum.find_value(paths, fn path ->
      map
      |> get_in(path)
      |> normalize_optional_string()
    end)
  end

  defp observed_key(metadata, status, revision) do
    [
      metadata.provider,
      metadata.organization_id || "no-org",
      metadata.repository_id,
      metadata.change_request_id,
      status,
      revision || "no-revision"
    ]
    |> Enum.join(":")
  end

  defp observation_outcome(status) when is_binary(status) do
    normalized = normalize_downcase(status)

    cond do
      MapSet.member?(@merged_statuses, normalized) -> :merged
      MapSet.member?(@terminal_failure_statuses, normalized) -> :terminal_failure
      true -> :active
    end
  end

  defp classify_observation(metadata, observation, observed_key) do
    if unchanged_observation?(metadata, observation, observed_key) do
      {:unchanged, observation}
    else
      {:changed, observation, event_metadata(metadata, observation)}
    end
  end

  defp unchanged_observation?(_metadata, %{observed_key: observed_key}, observed_key)
       when is_binary(observed_key),
       do: true

  defp unchanged_observation?(metadata, observation, _observed_key) do
    current_status = normalize_downcase(observation.status)
    last_status = normalize_downcase(metadata.last_observed_status)
    current_revision = normalize_optional_string(observation.revision)
    last_revision = normalize_optional_string(metadata.last_observed_revision)

    cond do
      is_nil(last_status) and is_nil(last_revision) ->
        true

      last_status != current_status ->
        false

      is_binary(last_revision) ->
        last_revision == current_revision

      true ->
        true
    end
  end

  defp event_metadata(metadata, observation) do
    %{
      provider: metadata.provider,
      organization_id: metadata.organization_id,
      repository_id: metadata.repository_id,
      change_request_id: metadata.change_request_id,
      from_state: metadata.last_observed_status || "unknown",
      to_state: observation.status,
      revision: observation.revision,
      observed_key: observation.observed_key,
      outcome: observation.outcome,
      url: observation.url
    }
  end
end
