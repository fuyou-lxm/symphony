defmodule SymphonyElixir.MemoryTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  test "fetch_candidate_issues reads issue fixtures from a JSON file for standalone smoke runs" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-memory-tracker-issues-#{System.unique_integer([:positive])}.json"
      )

    previous_file = Application.get_env(:symphony_elixir, :memory_tracker_issues_file)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues_file, previous_file)
      File.rm(fixture_path)
    end)

    File.write!(fixture_path, Jason.encode!([%{"id" => "issue-1", "identifier" => "MT-1", "title" => "Smoke", "state" => "Todo", "labels" => ["smoke"]}]))
    Application.put_env(:symphony_elixir, :memory_tracker_issues_file, fixture_path)

    assert {:ok, [issue]} = Memory.fetch_candidate_issues()
    assert issue.id == "issue-1"
    assert issue.identifier == "MT-1"
    assert issue.title == "Smoke"
    assert issue.state == "Todo"
    assert issue.labels == ["smoke"]
  end

  test "fetch_candidate_issues preserves false assigned_to_worker values from issue fixtures" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-memory-tracker-routed-issues-#{System.unique_integer([:positive])}.json"
      )

    previous_file = Application.get_env(:symphony_elixir, :memory_tracker_issues_file)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues_file, previous_file)
      File.rm(fixture_path)
    end)

    File.write!(
      fixture_path,
      Jason.encode!([
        %{"id" => "issue-routed-1", "identifier" => "MT-ROUTED-1", "title" => "Routed", "state" => "Todo", "assigned_to_worker" => false}
      ])
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues_file, fixture_path)

    assert {:ok, [issue]} = Memory.fetch_candidate_issues()
    assert issue.assigned_to_worker == false
  end

  test "fetch_candidate_issues returns an error for malformed issue fixture files" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-memory-tracker-bad-issues-#{System.unique_integer([:positive])}.json"
      )

    previous_file = Application.get_env(:symphony_elixir, :memory_tracker_issues_file)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues_file, previous_file)
      File.rm(fixture_path)
    end)

    File.write!(fixture_path, Jason.encode!(%{"not" => "a list"}))
    Application.put_env(:symphony_elixir, :memory_tracker_issues_file, fixture_path)

    assert {:error, {:invalid_memory_tracker_issues_file, ^fixture_path, :expected_json_array}} =
             Memory.fetch_candidate_issues()
  end

  test "fetch_candidate_issues reads issue fixtures from the standalone smoke env var" do
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-memory-tracker-env-issues-#{System.unique_integer([:positive])}.json"
      )

    previous_file = Application.get_env(:symphony_elixir, :memory_tracker_issues_file)
    previous_env = System.get_env("SYMPHONY_MEMORY_TRACKER_ISSUES_FILE")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues_file, previous_file)
      restore_env("SYMPHONY_MEMORY_TRACKER_ISSUES_FILE", previous_env)
      File.rm(fixture_path)
    end)

    Application.delete_env(:symphony_elixir, :memory_tracker_issues_file)
    File.write!(fixture_path, Jason.encode!([%{"id" => "issue-env-1", "identifier" => "MT-ENV-1", "title" => "Env smoke", "state" => "Todo"}]))
    System.put_env("SYMPHONY_MEMORY_TRACKER_ISSUES_FILE", fixture_path)

    assert {:ok, [issue]} = Memory.fetch_candidate_issues()
    assert issue.id == "issue-env-1"
    assert issue.identifier == "MT-ENV-1"
    assert issue.title == "Env smoke"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
