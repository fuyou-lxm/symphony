defmodule Mix.Tasks.Observability.MemoryMonitorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Observability.MemoryMonitor

  setup do
    Mix.Task.reenable("observability.memory_monitor")
    :ok
  end

  test "prints help" do
    output =
      capture_io(fn ->
        MemoryMonitor.run(["--help"])
      end)

    assert output =~ "mix observability.memory_monitor"
    assert output =~ "--port 4011"
  end

  test "samples the observability API and prints compact NDJSON" do
    parent = self()

    port =
      start_memory_server!(fn conn ->
        send(parent, {:memory_request_path, conn.request_path})

        %{
          "counts" => %{"running" => 10, "retrying" => 1},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 4_294_967_296,
            "symphony_process_tree_process_count" => 42,
            "running_preview_rss_bytes" => 536_870_912
          }
        }
      end)

    output =
      capture_io(fn ->
        assert :ok =
                 MemoryMonitor.run([
                   "--port",
                   Integer.to_string(port),
                   "--samples",
                   "1",
                   "--interval-ms",
                   "1"
                 ])
      end)

    assert [line] = String.split(output, "\n", trim: true)
    assert {:ok, payload} = Jason.decode(line)
    assert payload["running"] == 10
    assert payload["retrying"] == 1
    assert payload["symphony_process_tree_rss_bytes"] == 4_294_967_296
    assert payload["symphony_process_tree_rss_gib"] == 4.0
    assert payload["symphony_process_tree_process_count"] == 42
    assert payload["running_preview_rss_bytes"] == 536_870_912
    assert_receive {:memory_request_path, "/api/v1/memory"}
  end

  test "starts req dependencies when invoked as an isolated mix task process" do
    port =
      start_memory_server!(fn _conn ->
        %{
          "counts" => %{"running" => 10},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 1_073_741_824,
            "symphony_process_tree_process_count" => 20
          }
        }
      end)

    {output, status} =
      System.cmd(
        "mise",
        [
          "exec",
          "--",
          "mix",
          "observability.memory_monitor",
          "--port",
          Integer.to_string(port),
          "--samples",
          "1",
          "--interval-ms",
          "1"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    line =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "{"))

    assert is_binary(line), output
    assert {:ok, payload} = Jason.decode(line)
    assert payload["running"] == 10
    assert payload["symphony_process_tree_rss_bytes"] == 1_073_741_824
  end

  test "waits through startup connection errors before the first successful sample" do
    port = unused_tcp_port()

    monitor_task =
      Task.async(fn ->
        capture_io(fn ->
          assert :ok =
                   MemoryMonitor.run([
                     "--port",
                     Integer.to_string(port),
                     "--samples",
                     "1",
                     "--interval-ms",
                     "10",
                     "--startup-grace-ms",
                     "1000"
                   ])
        end)
      end)

    Process.sleep(50)

    assert ^port =
             start_memory_server!(
               fn _conn ->
                 %{
                   "counts" => %{"running" => 10},
                   "process_memory" => %{
                     "symphony_process_tree_rss_bytes" => 1_073_741_824,
                     "symphony_process_tree_process_count" => 20
                   }
                 }
               end,
               port: port
             )

    output = Task.await(monitor_task, 2_000)
    assert [line] = String.split(output, "\n", trim: true)
    assert {:ok, payload} = Jason.decode(line)
    assert payload["running"] == 10
  end

  test "prints final summary with peak memory when requested" do
    payloads =
      [
        %{
          "counts" => %{"running" => 2, "retrying" => 0},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 1 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 12,
            "running_preview_rss_bytes" => 128 * 1024 * 1024
          }
        },
        %{
          "counts" => %{"running" => 10, "retrying" => 1},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 4 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 54,
            "running_preview_rss_bytes" => 512 * 1024 * 1024
          }
        }
      ]

    port = start_memory_server!(payloads)

    output =
      capture_io(fn ->
        assert :ok =
                 MemoryMonitor.run([
                   "--port",
                   Integer.to_string(port),
                   "--samples",
                   "2",
                   "--interval-ms",
                   "1",
                   "--max-rss-bytes",
                   Integer.to_string(5 * 1024 * 1024 * 1024),
                   "--min-running",
                   "10",
                   "--summary"
                 ])
      end)

    assert [sample_1_line, sample_2_line, summary_line] = String.split(output, "\n", trim: true)
    assert {:ok, sample_1} = Jason.decode(sample_1_line)
    assert {:ok, sample_2} = Jason.decode(sample_2_line)
    assert {:ok, summary} = Jason.decode(summary_line)

    assert sample_1["sample"] == 1
    assert sample_2["sample"] == 2
    assert summary["kind"] == "summary"
    assert summary["sample_count"] == 2
    assert summary["max_running"] == 10
    assert summary["max_retrying"] == 1
    assert summary["peak_symphony_process_tree_rss_bytes"] == 4 * 1024 * 1024 * 1024
    assert summary["peak_symphony_process_tree_rss_gib"] == 4.0
    assert summary["peak_symphony_process_tree_process_count"] == 54
    assert summary["peak_running_preview_rss_bytes"] == 512 * 1024 * 1024
    assert summary["threshold_exceeded"] == false
    assert summary["max_rss_bytes"] == 5 * 1024 * 1024 * 1024
    assert summary["min_running"] == 10
    assert summary["min_running_met"] == true
  end

  test "raises when max running count never reaches the requested minimum" do
    port =
      start_memory_server!([
        %{
          "counts" => %{"running" => 8},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 2 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 40
          }
        },
        %{
          "counts" => %{"running" => 9},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 3 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 45
          }
        }
      ])

    output =
      capture_io(fn ->
        error_output =
          capture_io(:stderr, fn ->
            assert_raise Mix.Error, ~r/Running count requirement not met/, fn ->
              MemoryMonitor.run([
                "--port",
                Integer.to_string(port),
                "--samples",
                "2",
                "--interval-ms",
                "1",
                "--min-running",
                "10",
                "--summary"
              ])
            end
          end)

        assert error_output =~ "Running count requirement not met"
      end)

    assert [_sample_1_line, _sample_2_line, summary_line] = String.split(output, "\n", trim: true)
    assert {:ok, summary} = Jason.decode(summary_line)
    assert summary["max_running"] == 9
    assert summary["min_running"] == 10
    assert summary["min_running_met"] == false
  end

  test "writes samples to an output file while keeping stdout to the summary" do
    output_path = Path.join(System.tmp_dir!(), "symphony-memory-monitor-#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm_rf(output_path) end)
    File.write!(output_path, Jason.encode!(%{old_sample: true}) <> "\n")

    port =
      start_memory_server!([
        %{
          "counts" => %{"running" => 9, "retrying" => 0},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 2 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 41
          }
        },
        %{
          "counts" => %{"running" => 10, "retrying" => 1},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 3 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 46
          }
        }
      ])

    output =
      capture_io(fn ->
        assert :ok =
                 MemoryMonitor.run([
                   "--port",
                   Integer.to_string(port),
                   "--samples",
                   "2",
                   "--interval-ms",
                   "1",
                   "--min-running",
                   "10",
                   "--summary",
                   "--output",
                   output_path
                 ])
      end)

    assert [summary_line] = String.split(output, "\n", trim: true)
    assert {:ok, summary} = Jason.decode(summary_line)
    assert summary["kind"] == "summary"
    assert summary["sample_count"] == 2
    assert summary["max_running"] == 10
    assert summary["min_running_met"] == true

    assert [sample_1_line, sample_2_line] =
             output_path
             |> File.read!()
             |> String.split("\n", trim: true)

    assert {:ok, sample_1} = Jason.decode(sample_1_line)
    assert {:ok, sample_2} = Jason.decode(sample_2_line)
    refute Map.has_key?(sample_1, "old_sample")
    assert sample_1["sample"] == 1
    assert sample_2["sample"] == 2
  end

  test "raises when sampled process tree RSS exceeds threshold" do
    port =
      start_memory_server!(fn _conn ->
        %{
          "counts" => %{"running" => 10},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 6 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 50
          }
        }
      end)

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/RSS threshold exceeded/, fn ->
          capture_io(fn ->
            MemoryMonitor.run([
              "--port",
              Integer.to_string(port),
              "--samples",
              "1",
              "--max-rss-bytes",
              Integer.to_string(5 * 1024 * 1024 * 1024)
            ])
          end)
        end
      end)

    assert error_output =~ "RSS threshold exceeded"
  end

  test "prints summary before raising when threshold is exceeded" do
    threshold_bytes = 5 * 1024 * 1024 * 1024

    port =
      start_memory_server!([
        %{
          "counts" => %{"running" => 8},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 4 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 44
          }
        },
        %{
          "counts" => %{"running" => 10},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => 6 * 1024 * 1024 * 1024,
            "symphony_process_tree_process_count" => 61
          }
        }
      ])

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/RSS threshold exceeded/, fn ->
            MemoryMonitor.run([
              "--port",
              Integer.to_string(port),
              "--samples",
              "2",
              "--interval-ms",
              "1",
              "--max-rss-bytes",
              Integer.to_string(threshold_bytes),
              "--summary"
            ])
          end
        end)
      end)

    assert [sample_1_line, sample_2_line, summary_line] = String.split(output, "\n", trim: true)
    assert {:ok, sample_1} = Jason.decode(sample_1_line)
    assert {:ok, sample_2} = Jason.decode(sample_2_line)
    assert {:ok, summary} = Jason.decode(summary_line)

    assert sample_1["sample"] == 1
    assert sample_2["sample"] == 2
    assert summary["kind"] == "summary"
    assert summary["sample_count"] == 2
    assert summary["max_running"] == 10
    assert summary["peak_sample"] == 2
    assert summary["peak_symphony_process_tree_rss_bytes"] == 6 * 1024 * 1024 * 1024
    assert summary["threshold_exceeded"] == true
    assert summary["max_rss_bytes"] == threshold_bytes
  end

  test "raises when sampled process tree RSS equals threshold" do
    threshold_bytes = 5 * 1024 * 1024 * 1024

    port =
      start_memory_server!(fn _conn ->
        %{
          "counts" => %{"running" => 10},
          "process_memory" => %{
            "symphony_process_tree_rss_bytes" => threshold_bytes,
            "symphony_process_tree_process_count" => 50
          }
        }
      end)

    capture_io(:stderr, fn ->
      assert_raise Mix.Error, ~r/RSS threshold exceeded/, fn ->
        capture_io(fn ->
          MemoryMonitor.run([
            "--port",
            Integer.to_string(port),
            "--samples",
            "1",
            "--max-rss-bytes",
            Integer.to_string(threshold_bytes)
          ])
        end)
      end
    end)
  end

  defp start_memory_server!(payload_fun, opts \\ []) do
    payload_fun =
      case payload_fun do
        payloads when is_list(payloads) ->
          {:ok, counter} = Agent.start_link(fn -> 0 end)

          fn _conn ->
            index = Agent.get_and_update(counter, fn value -> {value, value + 1} end)
            Enum.at(payloads, index, List.last(payloads))
          end

        fun when is_function(fun, 1) ->
          fun
      end

    plug = fn conn, _opts ->
      case {conn.method, conn.request_path} do
        {"GET", path} when path in ["/api/v1/memory", "/api/v1/state"] ->
          payload = payload_fun.(conn)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(payload))

        _ ->
          Plug.Conn.send_resp(conn, 404, "not found")
      end
    end

    pid =
      start_supervised!(
        {Bandit,
         [
           plug: plug,
           port: Keyword.get(opts, :port, 0),
           thousand_island_options: [shutdown_timeout: 100]
         ]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp unused_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
