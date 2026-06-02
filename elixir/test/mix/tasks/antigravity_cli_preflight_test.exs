defmodule Mix.Tasks.AntigravityCli.PreflightTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.AntigravityCli.Preflight
  alias SymphonyElixir.Config

  setup do
    Mix.Task.reenable("antigravity_cli.preflight")
    :ok
  end

  test "passes when the Antigravity CLI workflow is configured for the low-memory 10 issue run" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_provider: "antigravity_cli",
      poll_interval_ms: 5_000,
      max_concurrent_agents: 10,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      dispatch_rss_reservation_bytes: 384 * 1024 * 1024,
      memory_watchdog_interval_ms: 1_000,
      observability_enabled: true,
      observability_terminal_dashboard_enabled: false,
      observability_refresh_ms: 1_000,
      observability_state_sample_interval_ms: 5_000
    )

    output =
      capture_io(fn ->
        assert :ok = Preflight.run([])
      end)

    assert output =~ "Antigravity CLI preflight passed"
    assert output =~ "polling_interval_ms=5000"
    assert output =~ "max_concurrent_agents=10"
    assert output =~ "max_process_tree_rss_bytes=5368709120"
    assert output =~ "memory_watchdog_interval_ms=1000"
    assert output =~ "observability_dashboard_enabled=true"
    assert output =~ "state_sample_interval_ms=5000"
  end

  test "can validate an explicit workflow path without changing the default workflow" do
    workflow_path = Path.join(System.tmp_dir!(), "symphony-antigravity-cli-preflight-#{System.unique_integer([:positive])}.md")

    on_exit(fn -> File.rm_rf(workflow_path) end)

    write_workflow_file!(Workflow.workflow_file_path(), agent_provider: "codex")

    write_workflow_file!(workflow_path,
      agent_provider: "antigravity_cli",
      poll_interval_ms: 5_000,
      max_concurrent_agents: 10,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      dispatch_rss_reservation_bytes: 384 * 1024 * 1024,
      memory_watchdog_interval_ms: 1_000,
      observability_enabled: true,
      observability_terminal_dashboard_enabled: false,
      observability_refresh_ms: 1_000,
      observability_state_sample_interval_ms: 5_000
    )

    output =
      capture_io(fn ->
        assert :ok = Preflight.run(["--workflow", workflow_path])
      end)

    assert output =~ "Antigravity CLI preflight passed"
    assert Config.settings!().agent.provider == "codex"
  end

  test "raises with actionable details when memory-critical settings are unsafe" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_provider: "antigravity_cli",
      poll_interval_ms: 1_000,
      max_concurrent_agents: 10,
      max_process_tree_rss_bytes: 5 * 1024 * 1024 * 1024,
      dispatch_rss_reservation_bytes: 900 * 1024 * 1024,
      memory_watchdog_interval_ms: 5_000,
      observability_enabled: false,
      observability_terminal_dashboard_enabled: true,
      observability_state_sample_interval_ms: 1_000
    )

    assert_raise Mix.Error, fn ->
      capture_io(fn -> Preflight.run([]) end)
    end
  end
end
