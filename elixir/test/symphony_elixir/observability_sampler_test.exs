defmodule SymphonyElixir.ObservabilitySamplerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.{ObservabilitySampler, ObservabilityStateCache, Presenter}

  defmodule CountingOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      if recipient = Keyword.get(state, :recipient) do
        send(recipient, :orchestrator_snapshot_called)
      end

      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  defmodule SequenceOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      if recipient = Keyword.get(state, :recipient) do
        send(recipient, :orchestrator_snapshot_called)
      end

      case Keyword.fetch!(state, :snapshots) do
        [snapshot | rest] ->
          {:reply, snapshot, Keyword.put(state, :snapshots, rest)}

        [] ->
          {:reply, :unavailable, state}
      end
    end
  end

  test "state payload reads the latest sampled payload instead of rebuilding per request" do
    parent = self()
    symphony_pid = System.pid() |> String.to_integer()
    orchestrator_name = Module.concat(__MODULE__, :"CountingOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilityStateCache.invalidate()
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}]
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called
    assert_receive :process_memory_rows_read

    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)
    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)

    refute_receive :orchestrator_snapshot_called, 50
    refute_receive :process_memory_rows_read, 50
  end

  test "issue payload reads the latest sampled state instead of snapshotting per request" do
    parent = self()
    symphony_pid = System.pid() |> String.to_integer()
    orchestrator_name = Module.concat(__MODULE__, :"IssuePayloadOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilityStateCache.invalidate()
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}]
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called
    assert_receive :process_memory_rows_read

    assert {:ok, %{status: "running", running: %{session_id: "thread-http"}}} =
             Presenter.issue_payload("MT-HTTP", orchestrator_name, 50)

    assert {:ok, %{status: "running", running: %{session_id: "thread-http"}}} =
             Presenter.issue_payload("MT-HTTP", orchestrator_name, 50)

    refute_receive :orchestrator_snapshot_called, 50
    refute_receive :process_memory_rows_read, 50
  end

  test "issue payload falls back to a snapshot when the sampled state misses the issue" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"IssuePayloadFallbackOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilityStateCache.invalidate()
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [])
    Application.delete_env(:symphony_elixir, :process_memory_ps_rows_provider)

    {:ok, _pid} =
      SequenceOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshots: [static_snapshot("MT-OLD"), static_snapshot("MT-NEW")]
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called

    assert {:ok, %{issue_identifier: "MT-NEW", status: "running"}} =
             Presenter.issue_payload("MT-NEW", orchestrator_name, 50)

    assert_receive :orchestrator_snapshot_called
  end

  test "sampled payload remains reusable when the next sampler refresh is delayed" do
    parent = self()
    symphony_pid = System.pid() |> String.to_integer()
    orchestrator_name = Module.concat(__MODULE__, :"StalePayloadOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilityStateCache.invalidate()
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows_provider, fn ->
      send(parent, :process_memory_rows_read)
      [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}]
    end)

    Application.delete_env(:symphony_elixir, :process_memory_ps_rows)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called
    assert_receive :process_memory_rows_read

    Process.sleep(2_100)

    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)
    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)

    refute_receive :orchestrator_snapshot_called, 50
    refute_receive :process_memory_rows_read, 50
  end

  test "transient sampler errors do not replace the last successful payload" do
    parent = self()
    symphony_pid = System.pid() |> String.to_integer()
    orchestrator_name = Module.concat(__MODULE__, :"TransientErrorOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilityStateCache.invalidate()
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}])
    Application.delete_env(:symphony_elixir, :process_memory_ps_rows_provider)

    {:ok, _pid} =
      SequenceOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshots: [static_snapshot(), :timeout]
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called
    assert {:ok, %{counts: %{running: 1}}} = ObservabilitySampler.latest_payload(orchestrator_name, 50)

    assert %{error: %{code: "snapshot_timeout"}} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called

    assert {:ok, %{counts: %{running: 1}}} = ObservabilitySampler.latest_payload(orchestrator_name, 50)
    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)
  end

  test "background sampler stays idle when no observability server is configured" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"IdleOrchestrator#{System.unique_integer([:positive])}")
    sampler_name = Module.concat(__MODULE__, :"IdleSampler#{System.unique_integer([:positive])}")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      restore_app_env(:server_port_override, previous_port_override)
      ObservabilitySampler.clear()
    end)

    Application.delete_env(:symphony_elixir, :server_port_override)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    start_sampler!(sampler_name, orchestrator_name)

    refute_receive :orchestrator_snapshot_called, 100
    assert ObservabilitySampler.latest_payload(orchestrator_name, 50) == :unavailable
  end

  test "expired sampled payloads are deleted when read" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"ExpiredPayloadOrchestrator#{System.unique_integer([:positive])}")
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:process_memory_ps_rows, previous_rows)
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [])

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    assert %{} = ObservabilitySampler.sample_now(orchestrator_name, 50)
    assert_receive :orchestrator_snapshot_called

    assert {:ok, %{counts: %{running: 1}}} = ObservabilitySampler.latest_payload(orchestrator_name, 50)
    expire_sampler_payload!(orchestrator_name, 50)

    assert ObservabilitySampler.latest_payload(orchestrator_name, 50) == :unavailable
    assert sampler_payload_count() == 0
  end

  test "disabled background sampler clears stale payloads" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"DisabledClearsOrchestrator#{System.unique_integer([:positive])}")
    sampler_name = Module.concat(__MODULE__, :"DisabledClearsSampler#{System.unique_integer([:positive])}")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)

    on_exit(fn ->
      restore_app_env(:server_port_override, previous_port_override)
      restore_app_env(:process_memory_ps_rows, previous_rows)
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 0)
    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [])

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    start_sampler!(sampler_name, orchestrator_name)

    assert_receive :orchestrator_snapshot_called, 200

    assert_eventually(fn ->
      match?({:ok, %{counts: %{running: 1}}}, ObservabilitySampler.latest_payload(orchestrator_name, 50))
    end)

    Application.delete_env(:symphony_elixir, :server_port_override)
    send(sampler_name, :sample)

    assert_eventually(fn ->
      ObservabilitySampler.latest_payload(orchestrator_name, 50) == :unavailable and sampler_payload_count() == 0
    end)
  end

  test "background sampler publishes a reusable payload when observability server is configured" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"ActiveOrchestrator#{System.unique_integer([:positive])}")
    sampler_name = Module.concat(__MODULE__, :"ActiveSampler#{System.unique_integer([:positive])}")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)
    symphony_pid = System.pid() |> String.to_integer()

    on_exit(fn ->
      restore_app_env(:server_port_override, previous_port_override)
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 0)
    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}])
    Application.delete_env(:symphony_elixir, :process_memory_ps_rows_provider)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    start_sampler!(sampler_name, orchestrator_name)

    assert_receive :orchestrator_snapshot_called, 200

    assert_eventually(fn ->
      match?({:ok, %{counts: %{running: 1}}}, ObservabilitySampler.latest_payload(orchestrator_name, 50))
    end)

    assert %{counts: %{running: 1}} = Presenter.state_payload(orchestrator_name, 50)
    refute_receive :orchestrator_snapshot_called, 50
  end

  test "background sampler uses the state sample interval instead of high-frequency dashboard refresh" do
    parent = self()
    orchestrator_name = Module.concat(__MODULE__, :"SampleIntervalOrchestrator#{System.unique_integer([:positive])}")
    sampler_name = Module.concat(__MODULE__, :"SampleIntervalSampler#{System.unique_integer([:positive])}")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)

    on_exit(fn ->
      restore_app_env(:server_port_override, previous_port_override)
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 0)
    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [])
    Application.delete_env(:symphony_elixir, :process_memory_ps_rows_provider)

    write_workflow_file!(Workflow.workflow_file_path(),
      observability_refresh_ms: 1,
      observability_state_sample_interval_ms: 200
    )

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: orchestrator_name,
        recipient: parent,
        snapshot: static_snapshot()
      )

    start_sampler!(sampler_name, orchestrator_name)

    assert_receive :orchestrator_snapshot_called, 200
    refute_receive :orchestrator_snapshot_called, 80
  end

  test "background sampler can be reconfigured to match endpoint orchestrator and timeout" do
    parent = self()
    original_orchestrator = Module.concat(__MODULE__, :"OriginalOrchestrator#{System.unique_integer([:positive])}")
    endpoint_orchestrator = Module.concat(__MODULE__, :"EndpointOrchestrator#{System.unique_integer([:positive])}")
    sampler_name = Module.concat(__MODULE__, :"ReconfiguredSampler#{System.unique_integer([:positive])}")
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)
    previous_rows = Application.get_env(:symphony_elixir, :process_memory_ps_rows)
    previous_rows_provider = Application.get_env(:symphony_elixir, :process_memory_ps_rows_provider)
    symphony_pid = System.pid() |> String.to_integer()

    on_exit(fn ->
      restore_app_env(:server_port_override, previous_port_override)
      restore_app_env(:process_memory_ps_rows, previous_rows)
      restore_app_env(:process_memory_ps_rows_provider, previous_rows_provider)
      ObservabilitySampler.clear()
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 0)
    Application.put_env(:symphony_elixir, :process_memory_ps_rows, [%{pid: symphony_pid, ppid: 1, rss_kb: 123, command: "beam.smp"}])
    Application.delete_env(:symphony_elixir, :process_memory_ps_rows_provider)

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: original_orchestrator,
        recipient: parent,
        snapshot: static_snapshot("MT-ORIGINAL")
      )

    {:ok, _pid} =
      CountingOrchestrator.start_link(
        name: endpoint_orchestrator,
        recipient: parent,
        snapshot: static_snapshot("MT-ENDPOINT")
      )

    start_sampler!(sampler_name, original_orchestrator)
    assert_receive :orchestrator_snapshot_called, 200
    drain_messages(:orchestrator_snapshot_called)

    assert :ok = ObservabilitySampler.configure(sampler_name, orchestrator: endpoint_orchestrator, snapshot_timeout_ms: 75)
    send(sampler_name, :sample)

    assert_receive :orchestrator_snapshot_called, 200

    assert_eventually(fn ->
      match?({:ok, %{running: [%{issue_identifier: "MT-ENDPOINT"}]}}, ObservabilitySampler.latest_payload(endpoint_orchestrator, 75))
    end)

    assert %{running: [%{issue_identifier: "MT-ENDPOINT"}]} = Presenter.state_payload(endpoint_orchestrator, 75)
    assert ObservabilitySampler.latest_payload(original_orchestrator, 50) == :unavailable
  end

  defp static_snapshot(identifier \\ "MT-HTTP") do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: identifier,
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
      retrying: [],
      blocked: [],
      external_waiting: [],
      recent_external_finalizations: [],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{}
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp start_sampler!(sampler_name, orchestrator_name) do
    start_supervised!(
      %{
        id: sampler_name,
        start: {ObservabilitySampler, :start_link, [[name: sampler_name, orchestrator: orchestrator_name, snapshot_timeout_ms: 50]]}
      },
      restart: :temporary
    )
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

  defp drain_messages(message) do
    receive do
      ^message -> drain_messages(message)
    after
      0 -> :ok
    end
  end

  defp expire_sampler_payload!(orchestrator, snapshot_timeout_ms) do
    table = :ets.whereis(:symphony_observability_sampler)
    key = {:state_payload, orchestrator, snapshot_timeout_ms}

    [{^key, value}] = :ets.lookup(table, key)
    :ets.insert(table, {key, %{value | expires_at_ms: System.monotonic_time(:millisecond) - 1}})
  end

  defp sampler_payload_count do
    case :ets.whereis(:symphony_observability_sampler) do
      :undefined -> 0
      table -> :ets.info(table, :size)
    end
  end
end
