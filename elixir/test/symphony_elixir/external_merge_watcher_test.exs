defmodule SymphonyElixir.ExternalMergeWatcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ExternalMergeWatcher

  test "extracts Codeup delivery metadata from a fenced JSON block" do
    issue = %Issue{
      id: "issue-codeup-metadata",
      identifier: "FIR-15",
      state: "Merging",
      description: """
      ## Codex Workpad

      ### Delivery Metadata

      ```json
      {
        "provider": "codeup",
        "domain": "openapi-rdc.aliyuncs.com",
        "organization_id": "org-123",
        "repo_id": "6907286",
        "change_request_id": 3,
        "source_branch": "fir-15-update-start-copy",
        "target_branch": "master",
        "delivery_commit": "fde329cfb8f523300f6066085f4c0a7ec0712c8c",
        "last_observed_cr_state": "TO_BE_MERGED"
      }
      ```
      """
    }

    assert {:ok, metadata} = ExternalMergeWatcher.delivery_metadata(issue)
    assert metadata.provider == "codeup"
    assert metadata.domain == "openapi-rdc.aliyuncs.com"
    assert metadata.organization_id == "org-123"
    assert metadata.repository_id == "6907286"
    assert metadata.change_request_id == "3"
    assert metadata.source_branch == "fir-15-update-start-copy"
    assert metadata.target_branch == "master"
    assert metadata.delivery_commit == "fde329cfb8f523300f6066085f4c0a7ec0712c8c"
    assert metadata.last_observed_status == "TO_BE_MERGED"
  end

  test "normalizes legacy Yunxiao Codeup provider metadata aliases" do
    issue = codeup_issue(provider: "yunxiao_codeup")

    assert {:ok, metadata} = ExternalMergeWatcher.delivery_metadata(issue)
    assert metadata.provider == "codeup"
    assert metadata.organization_id == "org-123"
    assert metadata.repository_id == "6907286"
    assert metadata.change_request_id == "3"
  end

  test "unchanged Codeup CR state keeps waiting without reporting a terminal change" do
    issue = codeup_issue(last_observed_cr_state: "TO_BE_MERGED")

    client = fn metadata ->
      send(self(), {:codeup_fetch, metadata})

      {:ok,
       %{
         "status" => "TO_BE_MERGED",
         "updateTime" => "2026-05-30T10:00:00Z",
         "webUrl" => "https://codeup.example/change/3"
       }}
    end

    assert {:unchanged, observation} = ExternalMergeWatcher.check_issue(issue, client: client)
    assert_receive {:codeup_fetch, %{provider: "codeup", change_request_id: "3"}}
    assert observation.status == "TO_BE_MERGED"
    assert observation.observed_key =~ "TO_BE_MERGED"
  end

  test "merged Codeup CR state reports a terminal change once for a new observed revision" do
    issue = codeup_issue(last_observed_cr_state: "TO_BE_MERGED")

    client = fn _metadata ->
      {:ok,
       %{
         "status" => "MERGED",
         "mergedRevision" => "8867ebd9c0ffee",
         "updateTime" => "2026-05-30T10:05:00Z",
         "webUrl" => "https://codeup.example/change/3"
       }}
    end

    assert {:changed, observation, event_metadata} =
             ExternalMergeWatcher.check_issue(issue, client: client)

    assert observation.status == "MERGED"
    assert observation.revision == "8867ebd9c0ffee"
    assert observation.outcome == :merged
    assert event_metadata.provider == "codeup"
    assert event_metadata.from_state == "TO_BE_MERGED"
    assert event_metadata.to_state == "MERGED"
    assert event_metadata.revision == "8867ebd9c0ffee"
    assert event_metadata.observed_key == observation.observed_key

    assert {:unchanged, repeated_observation} =
             ExternalMergeWatcher.check_issue(issue,
               client: client,
               observed_key: observation.observed_key
             )

    assert repeated_observation.observed_key == observation.observed_key
  end

  test "non-success terminal Codeup CR state reports terminal failure once" do
    issue = codeup_issue(last_observed_cr_state: "TO_BE_MERGED")

    client = fn _metadata ->
      {:ok,
       %{
         "status" => "CLOSED",
         "updateTime" => "2026-05-30T10:07:00Z",
         "webUrl" => "https://codeup.example/change/3"
       }}
    end

    assert {:changed, observation, event_metadata} =
             ExternalMergeWatcher.check_issue(issue, client: client)

    assert observation.status == "CLOSED"
    assert observation.outcome == :terminal_failure
    assert event_metadata.to_state == "CLOSED"
  end

  test "missing Codeup metadata is ignored without calling the client" do
    issue = %Issue{
      id: "issue-no-codeup-metadata",
      identifier: "FIR-16",
      state: "Merging",
      description: "No delivery metadata yet"
    }

    client = fn _metadata -> flunk("client should not be called without metadata") end

    assert {:ignored, :metadata_missing} = ExternalMergeWatcher.check_issue(issue, client: client)
  end

  test "Codeup delivery metadata requires organization id" do
    issue = codeup_issue(organization_id: nil)

    client = fn _metadata -> flunk("client should not be called without organization_id") end

    assert {:ignored, :metadata_missing} = ExternalMergeWatcher.check_issue(issue, client: client)
    assert {:error, :metadata_missing} = ExternalMergeWatcher.delivery_metadata(issue)
  end

  test "poller checks configured no-auto-Codex states and reports only changed Codeup CRs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    unchanged_issue =
      codeup_issue(
        last_observed_cr_state: "TO_BE_MERGED",
        issue_id: "issue-unchanged",
        identifier: "FIR-15"
      )

    changed_issue =
      codeup_issue(
        last_observed_cr_state: "TO_BE_MERGED",
        issue_id: "issue-merged",
        identifier: "FIR-16",
        change_request_id: 4
      )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [unchanged_issue, changed_issue])

    client = fn metadata ->
      case metadata.change_request_id do
        "3" ->
          {:ok, %{"status" => "TO_BE_MERGED", "updateTime" => "2026-05-30T10:00:00Z"}}

        "4" ->
          {:ok, %{"status" => "MERGED", "mergedRevision" => "rev-4"}}
      end
    end

    orchestrator = fn issue_id, event_metadata ->
      send(self(), {:external_finalization, issue_id, event_metadata})
      %{queued: false, finalized: true, reason: :external_merged}
    end

    assert %{checked: 2, changed: 1, unchanged: 1, ignored: 0, errors: 0} =
             ExternalMergeWatcher.check_blocked_issues(
               client: client,
               orchestrator: orchestrator
             )

    assert_receive {:external_finalization, "issue-merged", %{to_state: "MERGED", revision: "rev-4"}}
    refute_receive {:external_finalization, "issue-unchanged", _metadata}, 100
  end

  test "poller reads delivery metadata from tracker comments by default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Merging"],
      no_auto_codex_states: ["Merging"]
    )

    issue = %Issue{
      id: "issue-comment-metadata",
      identifier: "FIR-17",
      state: "Merging",
      title: "Comment metadata",
      description: "metadata only lives in the workpad comment"
    }

    metadata_comment = codeup_issue(change_request_id: 17).description

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [metadata_comment]})

    client = fn metadata ->
      send(self(), {:codeup_fetch_from_comment, metadata})
      {:ok, %{"status" => "MERGED", "mergedRevision" => "rev-17"}}
    end

    orchestrator = fn issue_id, event_metadata ->
      send(self(), {:external_finalization, issue_id, event_metadata})
      %{queued: false, finalized: true, reason: :external_merged}
    end

    assert %{checked: 1, changed: 1, unchanged: 0, ignored: 0, errors: 0} =
             ExternalMergeWatcher.check_blocked_issues(client: client, orchestrator: orchestrator)

    assert_receive {:codeup_fetch_from_comment, %{change_request_id: "17"}}
    assert_receive {:external_finalization, "issue-comment-metadata", %{to_state: "MERGED", revision: "rev-17"}}
  end

  test "poller process runs external merge checks on ticks without starting Codex" do
    test_pid = self()

    checker = fn ->
      send(test_pid, :external_merge_check)
      %{checked: 1, changed: 0, unchanged: 1, ignored: 0, errors: 0}
    end

    {:ok, pid} =
      ExternalMergeWatcher.start_link(
        name: Module.concat(__MODULE__, :PollerProcess),
        interval_ms: 30,
        checker: checker
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive :external_merge_check, 200
  end

  defp codeup_issue(overrides) do
    metadata =
      Keyword.merge(
        [
          provider: "codeup",
          domain: "openapi-rdc.aliyuncs.com",
          organization_id: "org-123",
          repo_id: "6907286",
          change_request_id: Keyword.get(overrides, :change_request_id, 3),
          source_branch: "fir-15-update-start-copy",
          target_branch: "master",
          delivery_commit: "fde329cfb8f523300f6066085f4c0a7ec0712c8c",
          last_observed_cr_state: "TO_BE_MERGED"
        ],
        overrides
      )
      |> Enum.into(%{})

    %Issue{
      id: Keyword.get(overrides, :issue_id, "issue-codeup-watch"),
      identifier: Keyword.get(overrides, :identifier, "FIR-15"),
      state: "Merging",
      description: """
      ## Codex Workpad

      ### Delivery Metadata

      ```json
      #{Jason.encode!(metadata, pretty: true)}
      ```
      """
    }
  end
end
