defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:counts_snapshot, _from, state) do
      snapshot = Keyword.fetch!(state, :snapshot)

      {:reply,
       %{
         counts: %{
           running: length(Map.get(snapshot, :running, [])),
           retrying: length(Map.get(snapshot, :retrying, [])),
           blocked: length(Map.get(snapshot, :blocked, [])),
           external_waiting: length(Map.get(snapshot, :external_waiting, []))
         },
         running_preview_workspaces:
           snapshot
           |> Map.get(:running, [])
           |> Enum.map(&Map.get(&1, :workspace_path))
           |> Enum.filter(&(is_binary(&1) and &1 != ""))
           |> Enum.uniq()
       }, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  defmodule CountsOnlyOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      if recipient = Keyword.get(state, :recipient) do
        send(recipient, :full_snapshot_called)
      end

      raise "full snapshot should not be used by /api/v1/memory"
    end

    def handle_call(:counts_snapshot, _from, state) do
      if recipient = Keyword.get(state, :recipient) do
        send(recipient, :counts_snapshot_called)
      end

      {:reply, Keyword.fetch!(state, :counts_snapshot), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  setup do
    reset_observability_pubsub()
    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")
    poll_receive_timeout_ms = 2_500

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)
    on_exit(fn -> if Process.alive?(manual_pid), do: Process.exit(manual_pid, :normal) end)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, poll_receive_timeout_ms

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, poll_receive_timeout_ms

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, poll_receive_timeout_ms

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)
    symphony_pid = System.pid() |> String.to_integer()
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [
      %{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}
    ])

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{
               "running" => 1,
               "retrying" => 1,
               "blocked" => 1,
               "external_waiting" => 1,
               "recent_external_finalizations" => 1
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "external_waiting" => [
               %{
                 "issue_id" => "issue-external",
                 "issue_identifier" => "MT-EXTERNAL",
                 "linear_state" => "Merging",
                 "provider" => "codeup",
                 "change_request" => "4",
                 "cr_status" => "TO_BE_MERGED",
                 "revision" => nil,
                 "observed_key" => "codeup:org-123:6907286:4:TO_BE_MERGED:no-revision",
                 "token_policy" => "no_codex",
                 "next_action" => "needs_human",
                 "error" => "metadata_missing",
                 "waiting_since" => state_payload["external_waiting"] |> List.first() |> Map.fetch!("waiting_since"),
                 "last_checked_at" => state_payload["external_waiting"] |> List.first() |> Map.fetch!("last_checked_at"),
                 "url" => "https://codeup.example/change/4"
               }
             ],
             "recent_external_finalizations" => [
               %{
                 "issue_id" => "issue-recent-external",
                 "issue_identifier" => "MT-RECENT-EXT",
                 "linear_state" => "Merging",
                 "provider" => "codeup",
                 "change_request" => "5",
                 "cr_status" => "MERGED",
                 "revision" => "rev-recent",
                 "observed_key" => "codeup:org-123:6907286:5:MERGED:rev-recent",
                 "target_state" => "Done",
                 "reason" => "external_merged",
                 "token_policy" => "no_codex",
                 "workspace_cleanup" => "ok",
                 "finalized_at" => state_payload["recent_external_finalizations"] |> List.first() |> Map.fetch!("finalized_at"),
                 "url" => "https://codeup.example/change/5"
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "process_memory" => %{
               "symphony_process_tree" => %{
                 "root_pid" => symphony_pid,
                 "process_count" => 1,
                 "rss_kb" => 123,
                 "rss_bytes" => 123 * 1024,
                 "command" => "beam.smp"
               },
               "symphony_process_tree_rss_bytes" => 123 * 1024,
               "symphony_process_tree_rss_kb" => 123,
               "symphony_process_tree_process_count" => 1,
               "running_preview_process_count" => 0,
               "running_preview_rss_bytes" => 0,
               "running_preview_rss_kb" => 0
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/memory")
    memory_payload = json_response(conn, 200)

    assert memory_payload == %{
             "generated_at" => memory_payload["generated_at"],
             "counts" => %{
               "running" => 1,
               "retrying" => 1,
               "blocked" => 1,
               "external_waiting" => 1
             },
             "process_memory" => %{
               "symphony_process_tree" => %{
                 "root_pid" => symphony_pid,
                 "process_count" => 1,
                 "rss_kb" => 123,
                 "rss_bytes" => 123 * 1024,
                 "command" => "beam.smp"
               },
               "symphony_process_tree_rss_bytes" => 123 * 1024,
               "symphony_process_tree_rss_kb" => 123,
               "symphony_process_tree_process_count" => 1,
               "running_preview_process_count" => 0,
               "running_preview_rss_bytes" => 0,
               "running_preview_rss_kb" => 0
             }
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "external_waiting" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-EXTERNAL")

    assert %{
             "status" => "external_waiting",
             "last_error" => "metadata_missing",
             "external_waiting" => %{
               "linear_state" => "Merging",
               "provider" => "codeup",
               "change_request" => "4",
               "cr_status" => "TO_BE_MERGED",
               "observed_key" => "codeup:org-123:6907286:4:TO_BE_MERGED:no-revision",
               "token_policy" => "no_codex",
               "next_action" => "needs_human",
               "error" => "metadata_missing"
             },
             "running" => nil,
             "retry" => nil,
             "blocked" => nil
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api reports running workspace preview process memory" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-observability-memory-#{System.unique_integer([:positive])}"
      )

    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      File.rm_rf(workspace)
    end)

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Path.join([workspace, ".symphony", "powerchat.pid"]), "300\n")

    symphony_pid = System.pid() |> String.to_integer()

    rows = [
      %{pid: symphony_pid, ppid: 1, rss_kb: 1_000, command: "beam.smp"},
      %{pid: symphony_pid + 1, ppid: symphony_pid, rss_kb: 2_000, command: "agy"},
      %{pid: 300, ppid: 1, rss_kb: 100, command: "sh"},
      %{pid: 301, ppid: 300, rss_kb: 200, command: "node"}
    ]

    parent = self()

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      rows
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    snapshot =
      update_in(static_snapshot().running, fn [entry] ->
        [Map.put(entry, :workspace_path, workspace)]
      end)

    orchestrator_name = Module.concat(__MODULE__, :ObservabilityMemoryOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload["process_memory"] == %{
             "symphony_process_tree" => %{
               "root_pid" => symphony_pid,
               "process_count" => 2,
               "rss_kb" => 3_000,
               "rss_bytes" => 3_000 * 1024,
               "command" => "beam.smp"
             },
             "symphony_process_tree_rss_bytes" => 3_000 * 1024,
             "symphony_process_tree_rss_kb" => 3_000,
             "symphony_process_tree_process_count" => 2,
             "running_preview_process_count" => 2,
             "running_preview_rss_bytes" => 300 * 1024,
             "running_preview_rss_kb" => 300
           }

    assert [running] = state_payload["running"]

    assert running["process_memory"]["preview"] == %{
             "root_pid" => 300,
             "process_count" => 2,
             "rss_kb" => 300,
             "rss_bytes" => 300 * 1024,
             "command" => "sh"
           }

    assert_receive :process_memory_rows_read
    refute_receive :process_memory_rows_read
  end

  test "phoenix observability memory API avoids full state snapshots" do
    orchestrator_name = Module.concat(__MODULE__, :CountsOnlyMemoryOrchestrator)
    symphony_pid = System.pid() |> String.to_integer()
    parent = self()
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      [%{pid: symphony_pid, ppid: 1, rss_kb: 456, command: "beam.smp"}]
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    {:ok, _pid} =
      CountsOnlyOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        counts_snapshot: %{
          counts: %{running: 10, retrying: 0, blocked: 0, external_waiting: 0},
          running_preview_workspaces: []
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = get(build_conn(), "/api/v1/memory") |> json_response(200)

    assert payload["counts"] == %{"running" => 10, "retrying" => 0, "blocked" => 0, "external_waiting" => 0}
    assert payload["process_memory"]["symphony_process_tree_rss_bytes"] == 456 * 1024

    assert_receive :counts_snapshot_called
    assert_receive :process_memory_rows_read
    refute_receive :full_snapshot_called, 50
  end

  test "phoenix observability state API reuses one payload within the refresh window" do
    orchestrator_name = Module.concat(__MODULE__, :CachedObservabilityApiOrchestrator)
    symphony_pid = System.pid() |> String.to_integer()
    parent = self()
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}]
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    assert %{"counts" => %{"running" => 1}} =
             get(build_conn(), "/api/v1/state") |> json_response(200)

    assert %{"counts" => %{"running" => 1}} =
             get(build_conn(), "/api/v1/state") |> json_response(200)

    assert_receive :process_memory_rows_read
    refute_receive :process_memory_rows_read, 50
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ "MT-EXTERNAL"
    assert html =~ "External waiting"
    assert html =~ "TO_BE_MERGED"
    assert html =~ "no_codex"
    assert html =~ "metadata_missing"
    assert html =~ "Recent external finalizations"
    assert html =~ "MT-RECENT-EXT"
    assert html =~ "rev-recent"
    assert html =~ "workspace cleanup"
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "data-runtime-clock="
    assert html =~ "setInterval(refreshRuntimeClocks"
    Process.sleep(1_100)
    assert {:messages, messages} = Process.info(view.pid, :messages)
    refute :runtime_tick in messages
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(
      fn ->
        render(view) =~ "agent message content streaming: structured update"
      end,
      80
    )
  end

  test "dashboard liveview renders Chinese interface text when requested" do
    orchestrator_name = Module.concat(__MODULE__, :ChineseDashboardOrchestrator)
    snapshot = %{static_snapshot() | rate_limits: nil}

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?lang=zh-CN")
    assert html =~ ~s(<html lang="zh-CN">)
    assert html =~ "运维仪表盘"
    assert html =~ "运行会话"
    assert html =~ "外部等待"
    assert html =~ "最近外部完成"
    assert html =~ "复制 ID"
    assert html =~ "Codex 更新"
    assert html =~ "0分"
    assert html =~ ~s(<pre class="code-panel">无</pre>)
    assert html =~ "MT-HTTP"
    assert html =~ "TO_BE_MERGED"
    assert html =~ "no_codex"
    refute html =~ "Operations Dashboard"
    refute html =~ "Running sessions"
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "running" => 1,
             "retrying" => 1,
             "blocked" => 1,
             "external_waiting" => 1,
             "recent_external_finalizations" => 1
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      external_waiting: [
        %{
          issue_id: "issue-external",
          identifier: "MT-EXTERNAL",
          state: "Merging",
          provider: "codeup",
          change_request_id: "4",
          cr_status: "TO_BE_MERGED",
          revision: nil,
          observed_key: "codeup:org-123:6907286:4:TO_BE_MERGED:no-revision",
          token_policy: :no_codex,
          next_action: :needs_human,
          error: "metadata_missing",
          waiting_since: DateTime.utc_now(),
          last_checked_at: DateTime.utc_now(),
          url: "https://codeup.example/change/4"
        }
      ],
      recent_external_finalizations: [
        %{
          issue_id: "issue-recent-external",
          identifier: "MT-RECENT-EXT",
          state: "Merging",
          provider: "codeup",
          change_request_id: "5",
          cr_status: "MERGED",
          revision: "rev-recent",
          observed_key: "codeup:org-123:6907286:5:MERGED:rev-recent",
          target_state: "Done",
          reason: :external_merged,
          token_policy: :no_codex,
          workspace_cleanup: :ok,
          finalized_at: DateTime.utc_now(),
          url: "https://codeup.example/change/5"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp reset_observability_pubsub do
    if Process.whereis(SymphonyElixirWeb.ObservabilityPubSub) do
      :sys.replace_state(SymphonyElixirWeb.ObservabilityPubSub, fn state ->
        %{
          state
          | last_broadcast_at_ms: nil,
            pending?: false,
            timer_ref: nil
        }
      end)
    end

    :ets.delete(:symphony_observability_pubsub_pending, :dashboard_update)
  rescue
    ArgumentError -> :ok
  end

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
