defmodule SymphonyElixir.CodexUpdateCompactorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexUpdateCompactor

  test "compacts Antigravity CLI stdout messages without retaining text or raw payloads" do
    large_text = String.duplicate("stdout-", 200_000)

    message = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        payload: %{
          "method" => "antigravity_cli/event/stdout",
          "params" => %{
            "text" => large_text,
            "stderr" => "",
            "conversation_id" => "agy-thread",
            "log_file" => "/tmp/agy.log"
          }
        },
        raw: large_text
      }
    }

    assert %{
             payload: %{
               payload: %{
                 "method" => "antigravity_cli/event/stdout",
                 "params" => params
               },
               raw: ""
             }
           } = CodexUpdateCompactor.compact(message)

    assert params["text_bytes"] == byte_size(large_text)
    assert params["stderr_bytes"] == 0
    assert params["conversation_id"] == "agy-thread"
    refute Map.has_key?(params, "text")
    refute Map.has_key?(params, "stderr")
    refute inspect(params) =~ large_text
  end

  test "compacts Antigravity CLI log messages to byte counts and a bounded preview" do
    large_text = String.duplicate("log-", 200_000)

    message = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        payload: %{
          "method" => "antigravity_cli/event/log",
          "params" => %{
            "text" => large_text,
            "conversation_id" => "agy-thread",
            "turn_id" => "turn-1",
            "offset_start" => 1024,
            "offset_end" => 2048,
            "bytes_read" => 1024,
            "bytes_available" => byte_size(large_text),
            "status" => "failed",
            "category" => "auth_required",
            "fatal" => true,
            "summary" => "You are not logged into Antigravity."
          }
        },
        raw: large_text
      }
    }

    assert %{
             payload: %{
               payload: %{
                 "method" => "antigravity_cli/event/log",
                 "params" => params
               },
               raw: ""
             }
           } = CodexUpdateCompactor.compact(message)

    assert params["text_bytes"] == byte_size(large_text)
    assert params["conversation_id"] == "agy-thread"
    assert params["offset_start"] == 1024
    assert params["offset_end"] == 2048
    assert params["bytes_read"] == 1024
    assert params["bytes_available"] == byte_size(large_text)
    assert params["status"] == "failed"
    assert params["category"] == "auth_required"
    assert params["fatal"] == true
    assert params["summary"] == "You are not logged into Antigravity."
    assert byte_size(params["text_preview"]) <= 243
    refute Map.has_key?(params, "text")
    refute inspect(params) =~ large_text
  end

  test "summarizes compacted updates with the same Antigravity payload rules" do
    large_text = String.duplicate("log-summary-", 100_000)

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "antigravity_cli/event/log",
        "params" => %{"text" => large_text}
      },
      raw: large_text
    }

    assert %{event: :notification, message: %{"params" => params}, timestamp: %DateTime{}} =
             CodexUpdateCompactor.summarize(update)

    assert params["text_bytes"] == byte_size(large_text)
    refute Map.has_key?(params, "text")
    refute inspect(params) =~ large_text
  end

  test "leaves non-Antigravity messages unchanged" do
    message = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{payload: %{"method" => "codex/event", "params" => %{"text" => "keep"}}, raw: "keep"}
    }

    assert CodexUpdateCompactor.compact(message) == message
  end

  test "bounds large raw fields for non-Antigravity messages" do
    large_raw = String.duplicate("raw-", 300_000)

    message = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        payload: %{"method" => "item/completed", "params" => %{"status" => "done"}},
        raw: large_raw
      }
    }

    compacted = CodexUpdateCompactor.compact(message)

    assert compacted.payload.raw_bytes == byte_size(large_raw)
    assert byte_size(compacted.payload.raw_preview) <= 243
    assert compacted.payload.raw == ""
    refute inspect(compacted) =~ large_raw
  end

  test "bounds common large Codex streaming fields while preserving method and counters" do
    large_delta = String.duplicate("delta-", 250_000)

    update = %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{
          "outputDelta" => large_delta,
          "sequence" => 42
        }
      },
      raw: large_delta
    }

    assert %{message: %{"method" => "item/commandExecution/outputDelta", "params" => params}} =
             CodexUpdateCompactor.summarize(update)

    assert params["sequence"] == 42
    assert params["outputDelta_bytes"] == byte_size(large_delta)
    assert byte_size(params["outputDelta_preview"]) <= 243
    refute Map.has_key?(params, "outputDelta")
    refute inspect(params) =~ large_delta
  end
end
