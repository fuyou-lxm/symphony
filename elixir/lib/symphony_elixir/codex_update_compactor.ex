defmodule SymphonyElixir.CodexUpdateCompactor do
  @moduledoc """
  Keeps Codex worker updates small before they reach long-lived state or mailboxes.
  """

  @text_preview_graphemes 240
  @large_field_threshold_bytes 16 * 1024

  @spec compact(map()) :: map()
  def compact(%{payload: %{payload: payload} = envelope} = message) do
    envelope = compact_envelope_raw(envelope)

    case compact_message_payload(payload) do
      {:compact, compacted_payload} ->
        Map.put(message, :payload, envelope |> Map.put(:payload, compacted_payload) |> Map.put(:raw, ""))

      :unchanged ->
        Map.put(message, :payload, Map.put(envelope, :payload, compact_large_fields(payload)))
    end
  end

  def compact(message), do: message

  @spec summarize(map()) :: map()
  def summarize(update) when is_map(update) do
    %{
      event: update[:event],
      message: compact_payload(update[:payload] || update[:raw]),
      timestamp: update[:timestamp]
    }
  end

  @spec compact_payload(term()) :: term()
  def compact_payload(payload) do
    case compact_message_payload(payload) do
      {:compact, compacted_payload} -> compacted_payload
      :unchanged -> compact_large_fields(payload)
    end
  end

  defp compact_message_payload(%{"method" => "antigravity_cli/event/stdout", "params" => params} = payload)
       when is_map(params) do
    {:compact,
     %{
       payload
       | "params" =>
           params
           |> Map.drop(["text", "stderr"])
           |> Map.put("text_bytes", reported_byte_size(params, "text_bytes", "text"))
           |> Map.put("stderr_bytes", reported_byte_size(params, "stderr_bytes", "stderr"))
     }}
  end

  defp compact_message_payload(%{"method" => "antigravity_cli/event/log", "params" => params} = payload)
       when is_map(params) do
    {:compact,
     %{
       payload
       | "params" =>
           params
           |> Map.drop(["text"])
           |> Map.put("text_bytes", reported_byte_size(params, "text_bytes", "text"))
           |> maybe_put_text_preview(Map.get(params, "text"))
     }}
  end

  defp compact_message_payload(_payload), do: :unchanged

  defp compact_envelope_raw(%{raw: raw} = envelope) when is_binary(raw) and byte_size(raw) > @large_field_threshold_bytes do
    envelope
    |> Map.put(:raw, "")
    |> Map.put(:raw_bytes, byte_size(raw))
    |> Map.put(:raw_preview, text_preview(raw, @text_preview_graphemes))
  end

  defp compact_envelope_raw(envelope), do: envelope

  defp compact_large_fields(%{} = payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      put_compact_field(acc, key, compact_large_fields(value))
    end)
  end

  defp compact_large_fields(values) when is_list(values), do: Enum.map(values, &compact_large_fields/1)
  defp compact_large_fields(value), do: value

  defp put_compact_field(acc, key, value) when is_binary(value) and byte_size(value) > @large_field_threshold_bytes do
    acc
    |> Map.put(byte_count_key(key), byte_size(value))
    |> Map.put(preview_key(key), text_preview(value, @text_preview_graphemes))
  end

  defp put_compact_field(acc, key, value), do: Map.put(acc, key, value)

  defp byte_count_key(key) when is_binary(key), do: "#{key}_bytes"
  defp byte_count_key(key) when is_atom(key), do: :"#{key}_bytes"
  defp byte_count_key(key), do: key

  defp preview_key(key) when is_binary(key), do: "#{key}_preview"
  defp preview_key(key) when is_atom(key), do: :"#{key}_preview"
  defp preview_key(key), do: key

  defp reported_byte_size(params, byte_key, fallback_key) when is_map(params) do
    case Map.get(params, byte_key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> byte_size_or_zero(Map.get(params, fallback_key))
    end
  end

  defp byte_size_or_zero(value) when is_binary(value), do: byte_size(value)
  defp byte_size_or_zero(_value), do: 0

  defp maybe_put_text_preview(params, text) when is_binary(text) do
    Map.put(params, "text_preview", text_preview(text, @text_preview_graphemes))
  end

  defp maybe_put_text_preview(params, _text), do: params

  defp text_preview(value, max_graphemes) when is_binary(value) do
    preview = String.slice(value, 0, max_graphemes)

    if preview == value do
      preview
    else
      :binary.copy(preview <> "...")
    end
  end
end
