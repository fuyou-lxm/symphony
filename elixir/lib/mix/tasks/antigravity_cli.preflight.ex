defmodule Mix.Tasks.AntigravityCli.Preflight do
  use Mix.Task

  alias SymphonyElixir.Config

  @shortdoc "Check low-memory Antigravity CLI workflow settings"

  @moduledoc """
  Validates that the current workflow is configured for the low-memory
  Antigravity CLI run before starting real issues.

  This task reads configuration only. It does not contact Linear and does not
  start `agy`.

  Usage:

      mix antigravity_cli.preflight
      mix antigravity_cli.preflight --workflow WORKFLOW.en.powerchat-agy.md
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @switches [workflow: :string]
  @bytes_per_gib 1024 * 1024 * 1024
  @target_parallel_issues 10
  @target_rss_bytes 5 * @bytes_per_gib
  @minimum_baseline_headroom_bytes 1 * @bytes_per_gib
  @maximum_memory_watchdog_interval_ms 1_000
  @minimum_polling_interval_ms 5_000
  @maximum_state_sample_interval_ms 5_000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    settings = settings!(opts)
    errors = validation_errors(settings)

    if errors == [] do
      Mix.shell().info(
        "Antigravity CLI preflight passed " <>
          "provider=#{settings.agent.provider} " <>
          "polling_interval_ms=#{settings.polling.interval_ms} " <>
          "max_concurrent_agents=#{settings.agent.max_concurrent_agents} " <>
          "max_process_tree_rss_bytes=#{settings.agent.max_process_tree_rss_bytes} " <>
          "dispatch_rss_reservation_bytes=#{settings.agent.dispatch_rss_reservation_bytes} " <>
          "memory_watchdog_interval_ms=#{settings.agent.memory_watchdog_interval_ms} " <>
          "observability_dashboard_enabled=#{settings.observability.dashboard_enabled} " <>
          "state_sample_interval_ms=#{settings.observability.state_sample_interval_ms}"
      )

      :ok
    else
      Enum.each(errors, fn error -> Mix.shell().error(error) end)
      Mix.raise("Antigravity CLI preflight failed with #{length(errors)} issue(s)")
    end
  end

  defp validation_errors(settings) do
    []
    |> require_value(settings.agent.provider == "antigravity_cli", "agent.provider must be antigravity_cli")
    |> require_value(
      settings.polling.interval_ms >= @minimum_polling_interval_ms,
      "polling.interval_ms should be at least #{@minimum_polling_interval_ms}ms for low-memory CLI runs"
    )
    |> require_value(settings.agent.max_concurrent_agents >= @target_parallel_issues, "agent.max_concurrent_agents must be at least #{@target_parallel_issues}")
    |> require_value(settings.agent.max_process_tree_rss_bytes == @target_rss_bytes, "agent.max_process_tree_rss_bytes must be #{@target_rss_bytes} bytes")
    |> require_value(
      is_integer(settings.agent.memory_watchdog_interval_ms) and
        settings.agent.memory_watchdog_interval_ms <= @maximum_memory_watchdog_interval_ms,
      "agent.memory_watchdog_interval_ms must be at most #{@maximum_memory_watchdog_interval_ms}ms"
    )
    |> require_value(
      reservation_safe?(settings),
      "agent.dispatch_rss_reservation_bytes * #{@target_parallel_issues} must leave at least #{@minimum_baseline_headroom_bytes} bytes headroom under #{@target_rss_bytes}"
    )
    |> require_value(settings.observability.dashboard_enabled == true, "observability.dashboard_enabled must be true for memory evidence collection")
    |> require_value(settings.observability.terminal_dashboard_enabled == false, "observability.terminal_dashboard_enabled must be false for low-memory CLI runs")
    |> require_value(settings.observability.refresh_ms >= 1_000, "observability.refresh_ms should be at least 1000ms")
    |> require_value(
      settings.observability.state_sample_interval_ms >= @maximum_state_sample_interval_ms,
      "observability.state_sample_interval_ms should be at least #{@maximum_state_sample_interval_ms}ms"
    )
  end

  defp settings!(opts) do
    case Keyword.get(opts, :workflow) do
      nil ->
        Config.settings!()

      workflow_path when is_binary(workflow_path) ->
        workflow_path
        |> Workflow.load()
        |> parse_settings!()
    end
  end

  defp parse_settings!({:ok, %{config: config}}) when is_map(config) do
    case Schema.parse(config) do
      {:ok, settings} -> settings
      {:error, reason} -> Mix.raise("Invalid WORKFLOW config: #{inspect(reason)}")
    end
  end

  defp parse_settings!({:error, reason}), do: Mix.raise("Failed to load workflow: #{inspect(reason)}")

  defp reservation_safe?(settings) do
    reservation = settings.agent.dispatch_rss_reservation_bytes
    limit = settings.agent.max_process_tree_rss_bytes

    is_integer(reservation) and reservation > 0 and
      is_integer(limit) and
      reservation * @target_parallel_issues <= limit - @minimum_baseline_headroom_bytes
  end

  defp require_value(errors, true, _message), do: errors
  defp require_value(errors, _value, message), do: [message | errors]
end
