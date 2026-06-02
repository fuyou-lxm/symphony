defmodule SymphonyElixir.ObservabilityPubSubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.{ObservabilityPubSub, ObservabilityStateCache}

  setup do
    clear_pending_update()

    if Process.whereis(ObservabilityPubSub) do
      :sys.replace_state(ObservabilityPubSub, fn state ->
        %{
          state
          | broadcast_interval_ms: 1_000,
            last_broadcast_at_ms: nil,
            pending?: false,
            timer_ref: nil
        }
      end)
    end

    :ok
  end

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update coalesces burst updates behind one pending broadcast" do
    assert :ok = ObservabilityPubSub.subscribe()
    original_state = :sys.get_state(ObservabilityPubSub)

    on_exit(fn ->
      if Process.whereis(ObservabilityPubSub) do
        :sys.replace_state(ObservabilityPubSub, fn _state -> original_state end)
      end
    end)

    :sys.replace_state(ObservabilityPubSub, fn state ->
      %{
        state
        | broadcast_interval_ms: 50,
          last_broadcast_at_ms: System.monotonic_time(:millisecond),
          pending?: false,
          timer_ref: nil
      }
    end)

    for _ <- 1..20 do
      assert :ok = ObservabilityPubSub.broadcast_update()
    end

    refute_receive :observability_updated, 20
    assert_receive :observability_updated, 100
    refute_receive :observability_updated, 40
  end

  test "broadcast_update invalidates cached state only when the coalesced update is delivered" do
    assert :ok = ObservabilityPubSub.subscribe()
    cache_key = {:observability_pubsub_test, System.unique_integer([:positive])}
    counter = :counters.new(1, [])
    original_state = :sys.get_state(ObservabilityPubSub)

    on_exit(fn ->
      if Process.whereis(ObservabilityPubSub) do
        :sys.replace_state(ObservabilityPubSub, fn _state -> original_state end)
      end
    end)

    cached_value = fn ->
      :counters.add(counter, 1, 1)
      :counters.get(counter, 1)
    end

    assert ObservabilityStateCache.fetch_or_store(cache_key, 1_000, cached_value) == 1

    :sys.replace_state(ObservabilityPubSub, fn state ->
      %{
        state
        | broadcast_interval_ms: 50,
          last_broadcast_at_ms: System.monotonic_time(:millisecond),
          pending?: false,
          timer_ref: nil
      }
    end)

    assert :ok = ObservabilityPubSub.broadcast_update()
    refute_receive :observability_updated, 20
    assert ObservabilityStateCache.fetch_or_store(cache_key, 1_000, cached_value) == 1

    assert_receive :observability_updated, 100
    assert ObservabilityStateCache.fetch_or_store(cache_key, 1_000, cached_value) == 2
  end

  test "broadcast_update queues at most one pending message while coalescer is busy" do
    pid = Process.whereis(ObservabilityPubSub)
    assert is_pid(pid)

    :sys.suspend(pid)

    try do
      for _ <- 1..100 do
        assert :ok = ObservabilityPubSub.broadcast_update()
      end

      {:message_queue_len, queue_len} = Process.info(pid, :message_queue_len)
      assert queue_len <= 1
    after
      :sys.resume(pid)
    end
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(SymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(SymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(SymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(SymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end

  defp clear_pending_update do
    :ets.delete(:symphony_observability_pubsub_pending, :dashboard_update)
  rescue
    ArgumentError -> :ok
  end
end
