defmodule Mix.Tasks.Observability.MemoryMonitor do
  use Mix.Task

  @shortdoc "Sample Symphony observability memory metrics"

  @moduledoc """
  Samples Symphony's observability API and prints compact NDJSON memory records.

  Usage:

      mix observability.memory_monitor --port 4011
      mix observability.memory_monitor --port 4011 --samples 120 --interval-ms 5000 --max-rss-bytes 5368709120
      mix observability.memory_monitor --port 4011 --samples 120 --interval-ms 1000 --min-running 10 --summary --output memory.ndjson
      mix observability.memory_monitor --port 4011 --startup-grace-ms 30000 --summary
      mix observability.memory_monitor --url http://127.0.0.1:4011/api/v1/memory
  """

  @switches [
    help: :boolean,
    interval_ms: :integer,
    max_rss_bytes: :integer,
    min_running: :integer,
    output: :string,
    port: :integer,
    samples: :integer,
    startup_grace_ms: :integer,
    summary: :boolean,
    url: :string
  ]
  @aliases [h: :help]
  @default_port 4011
  @default_samples 1
  @default_interval_ms 5_000
  @default_startup_grace_ms 30_000
  @bytes_per_gib 1024 * 1024 * 1024

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        opts
        |> normalize_options()
        |> sample_loop()
    end
  end

  defp normalize_options(opts) do
    %{
      interval_ms: positive_integer_opt(opts, :interval_ms, @default_interval_ms),
      max_rss_bytes: optional_positive_integer_opt(opts, :max_rss_bytes),
      min_running: optional_positive_integer_opt(opts, :min_running),
      output: normalize_output_path(opts[:output]),
      samples: positive_integer_opt(opts, :samples, @default_samples),
      startup_grace_ms: non_negative_integer_opt(opts, :startup_grace_ms, @default_startup_grace_ms),
      summary?: Keyword.get(opts, :summary, false),
      url: opts[:url] || "http://127.0.0.1:#{opts[:port] || @default_port}/api/v1/memory"
    }
  end

  defp positive_integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> Mix.raise("--#{dash_key(key)} must be a positive integer, got: #{inspect(value)}")
    end
  end

  defp optional_positive_integer_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value when is_integer(value) and value > 0 -> value
      value -> Mix.raise("--#{dash_key(key)} must be a positive integer, got: #{inspect(value)}")
    end
  end

  defp non_negative_integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value -> Mix.raise("--#{dash_key(key)} must be a non-negative integer, got: #{inspect(value)}")
    end
  end

  defp normalize_output_path(nil), do: nil

  defp normalize_output_path(path) when is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: Mix.raise("--output must not be blank"), else: Path.expand(trimmed)
  end

  defp normalize_output_path(value), do: Mix.raise("--output must be a path, got: #{inspect(value)}")

  defp dash_key(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp sample_loop(%{samples: samples} = opts) do
    ensure_req_started!()
    prepare_output_file!(opts.output)
    startup_deadline_ms = System.monotonic_time(:millisecond) + opts.startup_grace_ms

    {summary, threshold_message} =
      1..samples
      |> Enum.reduce_while({new_summary(opts.max_rss_bytes, opts.min_running), nil}, fn index, {summary, _threshold_message} ->
        payload = fetch_payload!(opts.url, startup_deadline_ms, opts.interval_ms, index)
        record = memory_record(payload, index)

        emit_sample_record(record, opts.output)

        summary = update_summary(summary, record)

        case threshold_message(record, opts.max_rss_bytes) do
          nil ->
            if index < samples do
              Process.sleep(opts.interval_ms)
            end

            {:cont, {summary, nil}}

          message ->
            {:halt, {summary, message}}
        end
      end)

    if opts.summary? do
      Mix.shell().info(Jason.encode!(summary_record(summary)))
    end

    maybe_raise_on_failure(threshold_message, summary)

    :ok
  end

  defp ensure_req_started! do
    case Application.ensure_all_started(:req) do
      {:ok, _apps} -> :ok
      {:error, reason} -> Mix.raise("Failed to start Req dependencies: #{inspect(reason)}")
    end
  end

  defp prepare_output_file!(nil), do: :ok

  defp prepare_output_file!(output_path) when is_binary(output_path) do
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, "")
  end

  defp emit_sample_record(record, nil) when is_map(record) do
    Mix.shell().info(Jason.encode!(record))
  end

  defp emit_sample_record(record, output_path) when is_map(record) and is_binary(output_path) do
    File.write!(output_path, Jason.encode!(record) <> "\n", [:append])
  end

  defp fetch_payload!(url, startup_deadline_ms, interval_ms, sample_index) do
    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        body

      {:ok, %{status: status, body: body}} ->
        maybe_retry_startup_fetch(url, startup_deadline_ms, interval_ms, sample_index, "status=#{status} body=#{inspect(body)}")

      {:error, reason} ->
        maybe_retry_startup_fetch(url, startup_deadline_ms, interval_ms, sample_index, inspect(reason))
    end
  end

  defp maybe_retry_startup_fetch(url, startup_deadline_ms, interval_ms, 1, reason) do
    if System.monotonic_time(:millisecond) < startup_deadline_ms do
      Process.sleep(startup_retry_sleep_ms(interval_ms))
      fetch_payload!(url, startup_deadline_ms, interval_ms, 1)
    else
      Mix.raise("Failed to fetch observability state: #{reason}")
    end
  end

  defp maybe_retry_startup_fetch(_url, _startup_deadline_ms, _interval_ms, _sample_index, reason) do
    Mix.raise("Failed to fetch observability state: #{reason}")
  end

  defp startup_retry_sleep_ms(interval_ms) when is_integer(interval_ms), do: max(min(interval_ms, 1_000), 10)
  defp startup_retry_sleep_ms(_interval_ms), do: 100

  defp memory_record(payload, sample_index) when is_map(payload) do
    counts = Map.get(payload, "counts", %{})
    memory = Map.get(payload, "process_memory", %{})
    rss_bytes = integer_value(memory, "symphony_process_tree_rss_bytes")

    %{
      sample: sample_index,
      sampled_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      running: integer_value(counts, "running"),
      retrying: integer_value(counts, "retrying"),
      blocked: integer_value(counts, "blocked"),
      external_waiting: integer_value(counts, "external_waiting"),
      symphony_process_tree_rss_bytes: rss_bytes,
      symphony_process_tree_rss_gib: rss_bytes / @bytes_per_gib,
      symphony_process_tree_process_count: integer_value(memory, "symphony_process_tree_process_count"),
      running_preview_rss_bytes: integer_value(memory, "running_preview_rss_bytes")
    }
  end

  defp integer_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  defp threshold_message(_record, nil), do: nil

  defp threshold_message(%{symphony_process_tree_rss_bytes: rss_bytes} = record, max_rss_bytes)
       when is_integer(rss_bytes) and is_integer(max_rss_bytes) and rss_bytes >= max_rss_bytes do
    "RSS threshold exceeded: #{rss_bytes} bytes >= #{max_rss_bytes} bytes " <>
      "(sample=#{record.sample}, processes=#{record.symphony_process_tree_process_count})"
  end

  defp threshold_message(_record, _max_rss_bytes), do: nil

  defp maybe_raise_on_failure(nil, summary) do
    case running_requirement_message(summary) do
      nil ->
        :ok

      message ->
        Mix.shell().error(message)
        Mix.raise(message)
    end
  end

  defp maybe_raise_on_failure(message, _summary) when is_binary(message) do
    Mix.shell().error(message)
    Mix.raise(message)
  end

  defp running_requirement_message(%{min_running: min_running, max_running: max_running})
       when is_integer(min_running) and is_integer(max_running) and max_running < min_running do
    "Running count requirement not met: max_running=#{max_running} < min_running=#{min_running}"
  end

  defp running_requirement_message(_summary), do: nil

  defp new_summary(max_rss_bytes, min_running) do
    %{
      sample_count: 0,
      max_running: 0,
      max_retrying: 0,
      max_blocked: 0,
      max_external_waiting: 0,
      peak_record: nil,
      max_rss_bytes: max_rss_bytes,
      min_running: min_running
    }
  end

  defp update_summary(summary, record) do
    %{
      summary
      | sample_count: summary.sample_count + 1,
        max_running: max(summary.max_running, record.running),
        max_retrying: max(summary.max_retrying, record.retrying),
        max_blocked: max(summary.max_blocked, record.blocked),
        max_external_waiting: max(summary.max_external_waiting, record.external_waiting),
        peak_record: peak_record(summary.peak_record, record)
    }
  end

  defp peak_record(nil, record), do: record

  defp peak_record(%{symphony_process_tree_rss_bytes: peak_rss} = peak_record, %{symphony_process_tree_rss_bytes: rss} = record) do
    if rss >= peak_rss, do: record, else: peak_record
  end

  defp summary_record(%{peak_record: peak_record} = summary) do
    threshold_exceeded =
      is_integer(summary.max_rss_bytes) and
        peak_record.symphony_process_tree_rss_bytes >= summary.max_rss_bytes

    %{
      kind: "summary",
      sampled_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      sample_count: summary.sample_count,
      max_running: summary.max_running,
      max_retrying: summary.max_retrying,
      max_blocked: summary.max_blocked,
      max_external_waiting: summary.max_external_waiting,
      peak_sample: peak_record.sample,
      peak_symphony_process_tree_rss_bytes: peak_record.symphony_process_tree_rss_bytes,
      peak_symphony_process_tree_rss_gib: peak_record.symphony_process_tree_rss_gib,
      peak_symphony_process_tree_process_count: peak_record.symphony_process_tree_process_count,
      peak_running_preview_rss_bytes: peak_record.running_preview_rss_bytes,
      max_rss_bytes: summary.max_rss_bytes,
      min_running: summary.min_running,
      min_running_met: min_running_met?(summary),
      threshold_exceeded: threshold_exceeded
    }
  end

  defp min_running_met?(%{min_running: min_running, max_running: max_running})
       when is_integer(min_running) and is_integer(max_running),
       do: max_running >= min_running

  defp min_running_met?(_summary), do: nil
end
