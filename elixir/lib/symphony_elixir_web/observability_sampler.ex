defmodule SymphonyElixirWeb.ObservabilitySampler do
  @moduledoc """
  Single-producer sampler for observability state payloads.

  Dashboard and API readers use the most recent sampled payload instead of each
  forcing an orchestrator snapshot and process-tree scan.
  """

  use GenServer

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{ObservabilityPubSub, ObservabilityStateCache, Presenter}

  @table :symphony_observability_sampler
  @default_refresh_ms 1_000
  @default_state_sample_interval_ms 5_000
  @default_snapshot_timeout_ms 15_000
  @minimum_payload_ttl_ms 60_000

  defstruct enabled?: true,
            refresh_ms: @default_refresh_ms,
            state_sample_interval_ms: @default_state_sample_interval_ms,
            orchestrator: SymphonyElixir.Orchestrator,
            snapshot_timeout_ms: @default_snapshot_timeout_ms,
            timer_ref: nil,
            sample_ref: nil

  @type t :: %__MODULE__{
          enabled?: boolean(),
          refresh_ms: pos_integer(),
          state_sample_interval_ms: pos_integer(),
          orchestrator: GenServer.server(),
          snapshot_timeout_ms: timeout(),
          timer_ref: reference() | nil,
          sample_ref: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(server \\ __MODULE__, opts) when is_list(opts) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(pid, {:configure, opts})
      _ -> :ok
    end
  end

  @spec latest_payload(GenServer.server(), timeout()) :: {:ok, map()} | :unavailable
  def latest_payload(orchestrator, snapshot_timeout_ms) do
    now_ms = System.monotonic_time(:millisecond)
    key = payload_key(orchestrator, snapshot_timeout_ms)

    with table when table != :undefined <- :ets.whereis(@table),
         [{_key, %{expires_at_ms: expires_at_ms, payload: payload}}] <-
           :ets.lookup(table, key),
         true <- expires_at_ms > now_ms do
      {:ok, payload}
    else
      false ->
        delete_payload(orchestrator, snapshot_timeout_ms)
        :unavailable

      _ ->
        :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec sample_now(GenServer.server(), timeout()) :: map()
  def sample_now(orchestrator, snapshot_timeout_ms) do
    payload = Presenter.build_state_payload(orchestrator, snapshot_timeout_ms)
    maybe_store_payload(orchestrator, snapshot_timeout_ms, payload, payload_ttl_ms())
    payload
  end

  @impl true
  def init(opts) do
    ensure_table(reset?: true)

    state =
      %__MODULE__{
        orchestrator: Keyword.get(opts, :orchestrator, SymphonyElixir.Orchestrator),
        snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, @default_snapshot_timeout_ms)
      }
      |> refresh_runtime_config()
      |> schedule_sample(0)

    {:ok, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, %__MODULE__{} = state) do
    clear_payload(state.orchestrator, state.snapshot_timeout_ms)

    state =
      state
      |> apply_configure_opts(opts)
      |> refresh_runtime_config()
      |> Map.put(:sample_ref, nil)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sample, %__MODULE__{} = state) do
    state =
      state
      |> refresh_runtime_config()
      |> maybe_clear_disabled_payload()
      |> maybe_start_sample()
      |> schedule_sample()

    {:noreply, state}
  end

  @impl true
  def handle_info({:sample_complete, sample_ref, orchestrator, snapshot_timeout_ms, payload}, %{sample_ref: sample_ref} = state) do
    if maybe_store_payload(orchestrator, snapshot_timeout_ms, payload, payload_ttl_ms(state.state_sample_interval_ms)) do
      ObservabilityStateCache.invalidate()
      ObservabilityPubSub.broadcast_update()
    end

    {:noreply, %{state | sample_ref: nil}}
  end

  def handle_info({:sample_complete, _sample_ref, _orchestrator, _snapshot_timeout_ms, _payload}, state),
    do: {:noreply, state}

  @impl true
  def handle_info({:sample_failed, sample_ref, _kind, _reason, _stacktrace}, %{sample_ref: sample_ref} = state) do
    {:noreply, %{state | sample_ref: nil}}
  end

  def handle_info({:sample_failed, _sample_ref, _kind, _reason, _stacktrace}, state), do: {:noreply, state}

  defp maybe_start_sample(%{enabled?: false} = state), do: state
  defp maybe_start_sample(%{sample_ref: sample_ref} = state) when is_reference(sample_ref), do: state

  defp maybe_start_sample(%{orchestrator: orchestrator, snapshot_timeout_ms: snapshot_timeout_ms} = state) do
    sample_ref = make_ref()
    start_sample(self(), sample_ref, orchestrator, snapshot_timeout_ms)
    %{state | sample_ref: sample_ref}
  end

  defp maybe_clear_disabled_payload(%{enabled?: false, orchestrator: orchestrator, snapshot_timeout_ms: snapshot_timeout_ms} = state) do
    clear_payload(orchestrator, snapshot_timeout_ms)
    state
  end

  defp maybe_clear_disabled_payload(state), do: state

  defp start_sample(parent, sample_ref, orchestrator, snapshot_timeout_ms) do
    spawn(fn ->
      try do
        payload = Presenter.build_state_payload(orchestrator, snapshot_timeout_ms)
        send(parent, {:sample_complete, sample_ref, orchestrator, snapshot_timeout_ms, payload})
      catch
        kind, reason ->
          send(parent, {:sample_failed, sample_ref, kind, reason, __STACKTRACE__})
      end
    end)

    :ok
  end

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = Config.settings!().observability

    %{
      state
      | enabled?: observability.dashboard_enabled and observability_server_configured?(),
        refresh_ms: normalize_refresh_ms(observability.refresh_ms),
        state_sample_interval_ms: normalize_refresh_ms(observability.state_sample_interval_ms)
    }
  rescue
    _error ->
      %{state | enabled?: false, refresh_ms: @default_refresh_ms, state_sample_interval_ms: @default_state_sample_interval_ms}
  end

  defp apply_configure_opts(%__MODULE__{} = state, opts) when is_list(opts) do
    %{
      state
      | orchestrator: Keyword.get(opts, :orchestrator, state.orchestrator),
        snapshot_timeout_ms: Keyword.get(opts, :snapshot_timeout_ms, state.snapshot_timeout_ms)
    }
  end

  defp schedule_sample(state), do: schedule_sample(state, state.state_sample_interval_ms)

  defp schedule_sample(%{timer_ref: timer_ref} = state, delay_ms) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    schedule_sample(%{state | timer_ref: nil}, delay_ms)
  end

  defp schedule_sample(state, delay_ms) do
    timer_ref = Process.send_after(self(), :sample, max(delay_ms, 0))
    %{state | timer_ref: timer_ref}
  end

  defp maybe_store_payload(orchestrator, snapshot_timeout_ms, payload, ttl_ms) when is_map(payload) do
    cond do
      successful_payload?(payload) ->
        store_payload(orchestrator, snapshot_timeout_ms, payload, ttl_ms)

      latest_payload(orchestrator, snapshot_timeout_ms) == :unavailable ->
        store_payload(orchestrator, snapshot_timeout_ms, payload, ttl_ms)

      true ->
        false
    end
  end

  defp store_payload(orchestrator, snapshot_timeout_ms, payload, ttl_ms) when is_map(payload) do
    ensure_table()

    value = %{
      payload: payload,
      sampled_at_ms: System.monotonic_time(:millisecond),
      expires_at_ms: System.monotonic_time(:millisecond) + ttl_ms
    }

    :ets.insert(@table, {payload_key(orchestrator, snapshot_timeout_ms), value})
    true
  end

  defp clear_payload(orchestrator, snapshot_timeout_ms) do
    delete_payload(orchestrator, snapshot_timeout_ms)
  end

  defp delete_payload(orchestrator, snapshot_timeout_ms) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete(table, payload_key(orchestrator, snapshot_timeout_ms))
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp successful_payload?(payload) when is_map(payload), do: not Map.has_key?(payload, :error)

  defp payload_key(orchestrator, snapshot_timeout_ms), do: {:state_payload, orchestrator, snapshot_timeout_ms}

  defp payload_ttl_ms do
    Config.settings!().observability.state_sample_interval_ms
    |> payload_ttl_ms()
  rescue
    _error -> payload_ttl_ms(@default_state_sample_interval_ms)
  end

  defp payload_ttl_ms(refresh_ms), do: max(normalize_refresh_ms(refresh_ms) * 30, @minimum_payload_ttl_ms)

  defp normalize_refresh_ms(refresh_ms) when is_integer(refresh_ms) and refresh_ms > 0, do: refresh_ms
  defp normalize_refresh_ms(_refresh_ms), do: @default_refresh_ms

  defp observability_server_configured? do
    case Config.server_port() do
      port when is_integer(port) and port >= 0 -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp ensure_table(opts \\ []) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      table ->
        if Keyword.get(opts, :reset?, false), do: :ets.delete_all_objects(table)
        table
    end
  rescue
    ArgumentError -> @table
  end
end
