defmodule SymphonyElixirWeb.ObservabilityStateCache do
  @moduledoc """
  Short-lived cache for expensive observability state projections.

  The dashboard can have several observers open at once. Sharing one compact
  payload per refresh window keeps those observers from each forcing a snapshot
  and process-tree scan.
  """

  use GenServer

  @default_ttl_ms 1_000

  defstruct generation: 0,
            payloads: %{},
            in_flight: %{}

  @type t :: %__MODULE__{generation: non_neg_integer(), payloads: map(), in_flight: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec fetch_or_store(term(), pos_integer(), (-> term())) :: term()
  def fetch_or_store(key, ttl_ms, fun) when is_function(fun, 0) do
    fetch_or_store(key, ttl_ms, ttl_ms + 16_000, fun)
  end

  @spec fetch_or_store(term(), pos_integer(), timeout(), (-> term())) :: term()
  def fetch_or_store(key, ttl_ms, call_timeout, fun) when is_function(fun, 0) do
    ttl_ms = normalize_ttl_ms(ttl_ms)
    call_timeout = normalize_call_timeout(call_timeout)

    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        call_cache(pid, {:fetch_or_store, key, ttl_ms, fun}, call_timeout)

      _ ->
        fun.()
    end
  end

  @spec invalidate() :: :ok
  def invalidate do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :invalidate)
      _ -> :ok
    end
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:fetch_or_store, key, ttl_ms, fun}, from, %__MODULE__{} = state) do
    # Keep slow snapshot building outside this GenServer so invalidation stays cheap.
    handle_fetch_or_store(key, ttl_ms, fun, from, state)
  end

  @impl true
  def handle_call(:invalidate, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | generation: state.generation + 1, payloads: %{}}}
  end

  @impl true
  def handle_info({:build_complete, token, key, generation, ttl_ms, payload}, %__MODULE__{} = state) do
    in_flight_key = {key, generation}
    {in_flight, state} = pop_in_flight(state, in_flight_key, token)

    Enum.each(waiters(in_flight), &GenServer.reply(&1, payload))

    state =
      if generation == state.generation do
        now_ms = System.monotonic_time(:millisecond)
        %{state | payloads: Map.put(state.payloads, key, %{expires_at_ms: now_ms + ttl_ms, payload: payload})}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:build_failed, token, key, generation, kind, reason, stacktrace}, %__MODULE__{} = state) do
    in_flight_key = {key, generation}
    {in_flight, state} = pop_in_flight(state, in_flight_key, token)
    error = {:__observability_state_cache_error__, kind, reason, stacktrace}

    Enum.each(waiters(in_flight), &GenServer.reply(&1, error))

    {:noreply, state}
  end

  defp handle_fetch_or_store(key, ttl_ms, fun, from, %__MODULE__{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    payloads = prune_expired_payloads(state.payloads, now_ms)
    in_flight_key = {key, state.generation}

    case Map.get(payloads, key) do
      %{expires_at_ms: expires_at_ms, payload: payload} when expires_at_ms > now_ms ->
        {:reply, payload, %{state | payloads: payloads}}

      _ ->
        state = %{state | payloads: payloads}

        case Map.get(state.in_flight, in_flight_key) do
          %{waiters: waiters} = in_flight ->
            state = put_in_flight(state, in_flight_key, %{in_flight | waiters: [from | waiters]})
            {:noreply, state}

          nil ->
            token = make_ref()
            start_builder(self(), token, key, state.generation, ttl_ms, fun)

            state =
              put_in_flight(state, in_flight_key, %{
                token: token,
                waiters: [from]
              })

            {:noreply, state}
        end
    end
  end

  defp call_cache(pid, message, timeout) do
    case GenServer.call(pid, message, timeout) do
      {:__observability_state_cache_error__, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      payload ->
        payload
    end
  end

  defp normalize_ttl_ms(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0, do: ttl_ms
  defp normalize_ttl_ms(_ttl_ms), do: @default_ttl_ms

  defp normalize_call_timeout(:infinity), do: :infinity
  defp normalize_call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_call_timeout(_timeout), do: @default_ttl_ms + 16_000

  defp prune_expired_payloads(payloads, now_ms) when is_map(payloads) do
    Map.reject(payloads, fn {_key, value} ->
      match?(%{expires_at_ms: expires_at_ms} when is_integer(expires_at_ms) and expires_at_ms <= now_ms, value)
    end)
  end

  defp start_builder(cache_pid, token, key, generation, ttl_ms, fun) do
    spawn(fn ->
      try do
        payload = fun.()
        send(cache_pid, {:build_complete, token, key, generation, ttl_ms, payload})
      catch
        kind, reason ->
          send(cache_pid, {:build_failed, token, key, generation, kind, reason, __STACKTRACE__})
      end
    end)

    :ok
  end

  defp pop_in_flight(state, in_flight_key, token) do
    case Map.get(state.in_flight, in_flight_key) do
      %{token: ^token} = in_flight ->
        {in_flight, %{state | in_flight: Map.delete(state.in_flight, in_flight_key)}}

      _ ->
        {nil, state}
    end
  end

  defp put_in_flight(state, in_flight_key, in_flight) do
    %{state | in_flight: Map.put(state.in_flight, in_flight_key, in_flight)}
  end

  defp waiters(%{waiters: waiters}) when is_list(waiters), do: waiters
  defp waiters(_in_flight), do: []
end
