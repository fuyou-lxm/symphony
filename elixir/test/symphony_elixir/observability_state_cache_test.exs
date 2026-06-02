defmodule SymphonyElixir.ObservabilityStateCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.ObservabilityStateCache

  test "invalidate does not block behind a slow payload build" do
    parent = self()
    cache_key = {:slow_payload, System.unique_integer([:positive])}

    task =
      Task.async(fn ->
        ObservabilityStateCache.fetch_or_store(cache_key, 1_000, 2_000, fn ->
          send(parent, :payload_build_started)
          Process.sleep(250)
          :slow_payload
        end)
      end)

    assert_receive :payload_build_started

    started_at_ms = System.monotonic_time(:millisecond)
    assert :ok = ObservabilityStateCache.invalidate()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert elapsed_ms < 100
    assert Task.await(task) == :slow_payload
  end
end
