defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  use GenServer

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @default_broadcast_interval_ms 1_000
  @pending_table :symphony_observability_pubsub_pending
  @pending_key :dashboard_update

  defstruct broadcast_interval_ms: @default_broadcast_interval_ms,
            last_broadcast_at_ms: nil,
            pending?: false,
            timer_ref: nil

  @type t :: %__MODULE__{
          broadcast_interval_ms: pos_integer(),
          last_broadcast_at_ms: integer() | nil,
          pending?: boolean(),
          timer_ref: reference() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    init_pending_table()

    {:ok, %__MODULE__{broadcast_interval_ms: Keyword.get(opts, :broadcast_interval_ms, @default_broadcast_interval_ms)}}
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    cond do
      not pubsub_available?() ->
        :ok

      pid = Process.whereis(__MODULE__) ->
        queue_update(pid)

      true ->
        broadcast_now()
        :ok
    end
  end

  @impl true
  def handle_cast(:broadcast_update, state) do
    {:noreply, handle_update_request(state)}
  end

  @impl true
  def handle_info(:broadcast_update, state) do
    {:noreply, handle_update_request(state)}
  end

  @impl true
  def handle_info({:flush_update, timer_ref}, %{timer_ref: timer_ref} = state) do
    state =
      if state.pending? and pubsub_available?() do
        clear_pending_update()
        broadcast_now()

        %{
          state
          | last_broadcast_at_ms: System.monotonic_time(:millisecond),
            pending?: false,
            timer_ref: nil
        }
      else
        clear_pending_update()
        %{state | pending?: false, timer_ref: nil}
      end

    {:noreply, state}
  end

  def handle_info({:flush_update, _timer_ref}, state), do: {:noreply, state}

  defp handle_update_request(state) do
    maybe_broadcast_or_schedule(state, System.monotonic_time(:millisecond))
  end

  defp maybe_broadcast_or_schedule(%{last_broadcast_at_ms: nil} = state, now_ms) do
    clear_pending_update()
    broadcast_now()
    %{state | last_broadcast_at_ms: now_ms, pending?: false, timer_ref: nil}
  end

  defp maybe_broadcast_or_schedule(%{last_broadcast_at_ms: last_broadcast_at_ms} = state, now_ms) do
    elapsed_ms = now_ms - last_broadcast_at_ms

    if elapsed_ms >= state.broadcast_interval_ms do
      clear_pending_update()
      broadcast_now()
      %{state | last_broadcast_at_ms: now_ms, pending?: false, timer_ref: nil}
    else
      schedule_pending_broadcast(state, state.broadcast_interval_ms - elapsed_ms)
    end
  end

  defp schedule_pending_broadcast(%{timer_ref: timer_ref} = state, _delay_ms) when is_reference(timer_ref) do
    %{state | pending?: true}
  end

  defp schedule_pending_broadcast(state, delay_ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:flush_update, timer_ref}, max(delay_ms, 0))
    %{state | pending?: true, timer_ref: timer_ref}
  end

  defp pubsub_available?, do: is_pid(Process.whereis(@pubsub))

  defp broadcast_now do
    SymphonyElixirWeb.ObservabilityStateCache.invalidate()
    Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)
  end

  defp init_pending_table do
    case :ets.whereis(@pending_table) do
      :undefined ->
        :ets.new(@pending_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

      _table ->
        :ets.delete_all_objects(@pending_table)
    end
  end

  defp queue_update(pid) when is_pid(pid) do
    if insert_pending_update() do
      send(pid, :broadcast_update)
    end

    :ok
  end

  defp insert_pending_update do
    :ets.insert_new(@pending_table, {@pending_key, true})
  rescue
    ArgumentError -> true
  end

  defp clear_pending_update do
    :ets.delete(@pending_table, @pending_key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
