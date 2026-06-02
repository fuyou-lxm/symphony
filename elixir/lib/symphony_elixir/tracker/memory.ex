defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    issue_entries()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- issue_entries() do
      {:ok,
       Enum.filter(issues, fn %Issue{state: state} ->
         MapSet.member?(normalized_states, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    with {:ok, issues} <- issue_entries() do
      {:ok,
       Enum.filter(issues, fn %Issue{id: id} ->
         MapSet.member?(wanted_ids, id)
       end)}
    end
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    comments =
      :symphony_elixir
      |> Application.get_env(:memory_tracker_comments, %{})
      |> Map.get(issue_id, [])
      |> Enum.filter(&is_binary/1)

    {:ok, comments}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    case configured_issues_file() do
      nil ->
        {:ok, Enum.filter(configured_issues(), &match?(%Issue{}, &1))}

      path ->
        read_issue_entries_file(path)
    end
  end

  defp configured_issues_file do
    case Application.get_env(:symphony_elixir, :memory_tracker_issues_file) || System.get_env("SYMPHONY_MEMORY_TRACKER_ISSUES_FILE") do
      path when is_binary(path) ->
        trimmed = String.trim(path)
        if trimmed == "", do: nil, else: Path.expand(trimmed)

      _ ->
        nil
    end
  end

  defp read_issue_entries_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, issues} <- issues_from_decoded_json(decoded, path) do
      {:ok, issues}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_memory_tracker_issues_file, path, {:json_decode_error, Exception.message(error)}}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:invalid_memory_tracker_issues_file, path, {:read_error, reason}}}

      {:error, {:invalid_memory_tracker_issues_file, _path, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:invalid_memory_tracker_issues_file, path, reason}}
    end
  end

  defp issues_from_decoded_json(entries, _path) when is_list(entries) do
    {:ok,
     entries
     |> Enum.map(&issue_from_json_entry/1)
     |> Enum.filter(&match?(%Issue{}, &1))}
  end

  defp issues_from_decoded_json(_decoded, path) do
    {:error, {:invalid_memory_tracker_issues_file, path, :expected_json_array}}
  end

  defp issue_from_json_entry(entry) when is_map(entry) do
    %Issue{
      id: string_value(entry, "id"),
      identifier: string_value(entry, "identifier"),
      title: string_value(entry, "title"),
      description: string_value(entry, "description"),
      priority: integer_value(entry, "priority"),
      state: string_value(entry, "state"),
      branch_name: string_value(entry, "branch_name"),
      url: string_value(entry, "url"),
      assignee_id: string_value(entry, "assignee_id"),
      blocked_by: string_list_value(entry, "blocked_by"),
      labels: string_list_value(entry, "labels"),
      assigned_to_worker: boolean_value(entry, "assigned_to_worker", true),
      created_at: datetime_value(entry, "created_at"),
      updated_at: datetime_value(entry, "updated_at")
    }
  end

  defp issue_from_json_entry(_entry), do: nil

  defp string_value(entry, key) do
    case map_value(entry, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp integer_value(entry, key) do
    case map_value(entry, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> integer_parse_value()
      _ -> nil
    end
  end

  defp integer_parse_value({value, ""}), do: value
  defp integer_parse_value(_value), do: nil

  defp string_list_value(entry, key) do
    case map_value(entry, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp boolean_value(entry, key, default) do
    case map_value(entry, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp datetime_value(entry, key) do
    case string_value(entry, key) do
      nil ->
        nil

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end
    end
  end

  defp map_value(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          nil -> nil
          atom_key -> Map.get(entry, atom_key)
        end
    end
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
