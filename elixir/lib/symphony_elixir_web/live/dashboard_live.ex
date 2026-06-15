defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{DashboardLocale, Endpoint, ObservabilityPubSub, Presenter}
  @zh_locale "zh-CN"

  @impl true
  def mount(params, _session, socket) do
    locale = DashboardLocale.resolve(params)
    now = DateTime.utc_now()

    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:rendered_at, now)
      |> assign(:locale, locale)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    now = DateTime.utc_now()

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:rendered_at, now)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              <%= t(@locale, :eyebrow) %>
            </p>
            <h1 class="hero-title">
              <%= t(@locale, :hero_title) %>
            </h1>
            <p class="hero-copy">
              <%= t(@locale, :hero_copy) %>
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              <%= t(@locale, :live) %>
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              <%= t(@locale, :offline) %>
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            <%= t(@locale, :snapshot_unavailable) %>
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_running) %></p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail"><%= t(@locale, :metric_running_detail) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_retrying) %></p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail"><%= t(@locale, :metric_retrying_detail) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_blocked) %></p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail"><%= t(@locale, :metric_blocked_detail) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_external_waiting) %></p>
            <p class="metric-value numeric"><%= @payload.counts.external_waiting %></p>
            <p class="metric-detail"><%= t(@locale, :metric_external_waiting_detail) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_recent_external) %></p>
            <p class="metric-value numeric"><%= @payload.counts.recent_external_finalizations %></p>
            <p class="metric-detail"><%= t(@locale, :metric_recent_external_detail) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_total_tokens) %></p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens, @locale) %></p>
            <p class="metric-detail numeric">
              <%= t(@locale, :tokens_in) %> <%= format_int(@payload.codex_totals.input_tokens, @locale) %> / <%= t(@locale, :tokens_out) %> <%= format_int(@payload.codex_totals.output_tokens, @locale) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label"><%= t(@locale, :metric_runtime) %></p>
            <p
              class="metric-value numeric"
              data-runtime-clock="total"
              data-base-seconds={total_runtime_seconds(@payload, @rendered_at)}
              data-rendered-at={unix_seconds(@rendered_at)}
              data-locale={@locale}
            ><%= format_runtime_seconds(total_runtime_seconds(@payload, @rendered_at), @locale) %></p>
            <p class="metric-detail"><%= t(@locale, :metric_runtime_detail) %></p>
          </article>
        </section>

        <%= if @payload.recent_external_finalizations != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title"><%= t(@locale, :recent_external_title) %></h2>
                <p class="section-copy"><%= t(@locale, :recent_external_copy) %></p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table data-table-external">
                <colgroup>
                  <col style="width: 11rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 11rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 13rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th><%= t(@locale, :issue) %></th>
                    <th><%= t(@locale, :target_state) %></th>
                    <th><%= t(@locale, :codeup_cr) %></th>
                    <th><%= t(@locale, :cr_status) %></th>
                    <th><%= t(@locale, :revision) %></th>
                    <th><%= t(@locale, :workspace_cleanup) %></th>
                    <th><%= t(@locale, :finalized) %></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.recent_external_finalizations}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <%= if entry.url do %>
                          <a class="issue-link" href={entry.url}><%= t(@locale, :open_cr) %></a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.target_state || "Completed")}>
                        <%= entry.target_state || t(@locale, :completed) %>
                      </span>
                    </td>
                    <td class="mono"><%= format_provider_cr(entry.provider, entry.change_request, @locale) %></td>
                    <td>
                      <span class={state_badge_class(entry.cr_status || "unknown")}>
                        <%= entry.cr_status || t(@locale, :unknown) %>
                      </span>
                    </td>
                    <td class="mono" title={entry.observed_key || t(@locale, :not_available)}><%= entry.revision || t(@locale, :not_available) %></td>
                    <td>
                      <div class="detail-stack">
                        <span><%= entry.workspace_cleanup || t(@locale, :unknown) %></span>
                        <span class="muted"><%= t(@locale, :workspace_cleanup_detail) %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="mono numeric"><%= format_visible_time(entry.finalized_at, @locale) %></span>
                        <span class="muted"><%= entry.reason || t(@locale, :not_available) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= t(@locale, :rate_limits_title) %></h2>
              <p class="section-copy"><%= t(@locale, :rate_limits_copy) %></p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits, @locale) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= t(@locale, :running_sessions_title) %></h2>
              <p class="section-copy"><%= t(@locale, :running_sessions_copy) %></p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state"><%= t(@locale, :no_active_sessions) %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th><%= t(@locale, :issue) %></th>
                    <th><%= t(@locale, :state) %></th>
                    <th><%= t(@locale, :session) %></th>
                    <th><%= t(@locale, :runtime_turns) %></th>
                    <th><%= t(@locale, :codex_update) %></th>
                    <th><%= t(@locale, :tokens) %></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}><%= t(@locale, :json_details) %></a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label={t(@locale, :copy_id)}
                            data-copy={entry.session_id}
                            data-copied-label={t(@locale, :copied)}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = this.dataset.copiedLabel; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            <%= t(@locale, :copy_id) %>
                          </button>
                        <% else %>
                          <span class="muted"><%= t(@locale, :not_available) %></span>
                        <% end %>
                      </div>
                    </td>
                    <td
                      class="numeric"
                      data-runtime-clock="session"
                      data-started-at={unix_seconds(entry.started_at)}
                      data-turn-count={entry.turn_count}
                      data-locale={@locale}
                    ><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @rendered_at, @locale) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || t(@locale, :not_available))}
                        ><%= entry.last_message || to_string(entry.last_event || t(@locale, :not_available)) %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || t(@locale, :not_available) %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= format_visible_time(entry.last_event_at, @locale) %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span><%= t(@locale, :tokens_total) %>: <%= format_int(entry.tokens.total_tokens, @locale) %></span>
                        <span class="muted"><%= t(@locale, :tokens_in) %> <%= format_int(entry.tokens.input_tokens, @locale) %> / <%= t(@locale, :tokens_out) %> <%= format_int(entry.tokens.output_tokens, @locale) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= t(@locale, :external_waiting_title) %></h2>
              <p class="section-copy"><%= t(@locale, :external_waiting_copy) %></p>
            </div>
          </div>

          <%= if @payload.external_waiting == [] do %>
            <p class="empty-state"><%= t(@locale, :no_external_waits) %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-external">
                <colgroup>
                  <col style="width: 11rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 11rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 13rem;" />
                  <col />
                </colgroup>
                <thead>
                  <tr>
                    <th><%= t(@locale, :issue) %></th>
                    <th><%= t(@locale, :linear_state) %></th>
                    <th><%= t(@locale, :codeup_cr) %></th>
                    <th><%= t(@locale, :cr_status) %></th>
                    <th><%= t(@locale, :token_policy) %></th>
                    <th><%= t(@locale, :last_checked) %></th>
                    <th><%= t(@locale, :next_action) %></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.external_waiting}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}><%= t(@locale, :json_details) %></a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.linear_state || "External waiting")}>
                        <%= entry.linear_state || t(@locale, :external_waiting_title) %>
                      </span>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="mono"><%= format_provider_cr(entry.provider, entry.change_request, @locale) %></span>
                        <%= if entry.url do %>
                          <a class="issue-link" href={entry.url}><%= t(@locale, :open_cr) %></a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={state_badge_class(entry.cr_status || "pending")}>
                          <%= entry.cr_status || t(@locale, :pending) %>
                        </span>
                        <span class="muted mono event-meta" title={entry.observed_key || t(@locale, :not_available)}>
                          <%= entry.observed_key || t(@locale, :not_available) %>
                        </span>
                      </div>
                    </td>
                    <td class="mono"><%= entry.token_policy || t(@locale, :not_available) %></td>
                    <td class="mono numeric"><%= format_visible_time(entry.last_checked_at, @locale) %></td>
                    <td>
                      <div class="detail-stack">
                        <span><%= entry.next_action || t(@locale, :not_available) %></span>
                        <%= if entry.error do %>
                          <span class="error-inline" title={entry.error}><%= entry.error %></span>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= t(@locale, :blocked_sessions_title) %></h2>
              <p class="section-copy"><%= t(@locale, :blocked_sessions_copy) %></p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state"><%= t(@locale, :no_blocked_sessions) %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th><%= t(@locale, :issue) %></th>
                    <th><%= t(@locale, :state) %></th>
                    <th><%= t(@locale, :session) %></th>
                    <th><%= t(@locale, :blocked_at) %></th>
                    <th><%= t(@locale, :last_update) %></th>
                    <th><%= t(@locale, :error) %></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}><%= t(@locale, :json_details) %></a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || t(@locale, :blocked) %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label={t(@locale, :copy_id)}
                          data-copy={entry.session_id}
                          data-copied-label={t(@locale, :copied)}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = this.dataset.copiedLabel; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          <%= t(@locale, :copy_id) %>
                        </button>
                      <% else %>
                        <span class="muted"><%= t(@locale, :not_available) %></span>
                      <% end %>
                    </td>
                    <td class="mono"><%= format_visible_time(entry.blocked_at, @locale) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || t(@locale, :not_available))}
                        ><%= entry.last_message || to_string(entry.last_event || t(@locale, :not_available)) %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || t(@locale, :not_available) %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= format_visible_time(entry.last_event_at, @locale) %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || t(@locale, :not_available) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= t(@locale, :retry_queue_title) %></h2>
              <p class="section-copy"><%= t(@locale, :retry_queue_copy) %></p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state"><%= t(@locale, :no_retrying_issues) %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th><%= t(@locale, :issue) %></th>
                    <th><%= t(@locale, :attempt) %></th>
                    <th><%= t(@locale, :due_at) %></th>
                    <th><%= t(@locale, :error) %></th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}><%= t(@locale, :json_details) %></a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || t(@locale, :not_available) %></td>
                    <td><%= entry.error || t(@locale, :not_available) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now, locale)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now), locale)} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now, locale),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now), locale)

  defp format_runtime_seconds(seconds, locale) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)

    case locale do
      @zh_locale -> "#{mins}分 #{secs}秒"
      _ -> "#{mins}m #{secs}s"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp unix_seconds(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)

  defp unix_seconds(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _offset} -> unix_seconds(parsed)
      _ -> nil
    end
  end

  defp unix_seconds(_datetime), do: nil

  defp format_visible_time(nil, locale), do: t(locale, :not_available)

  defp format_visible_time(%DateTime{} = datetime, locale) do
    format_beijing_time(DateTime.shift_zone!(datetime, "Etc/UTC"), locale)
  end

  defp format_visible_time(datetime, locale) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, parsed, _offset} -> format_visible_time(parsed, locale)
      _ -> datetime
    end
  end

  defp format_visible_time(_datetime, locale), do: t(locale, :not_available)

  defp format_beijing_time(%DateTime{} = datetime, locale) do
    datetime
    |> DateTime.add(8 * 60 * 60, :second)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
    |> then(fn timestamp ->
      case locale do
        @zh_locale -> "北京时间 #{timestamp}"
        _ -> "#{timestamp} CST"
      end
    end)
  end

  defp format_int(value, _locale) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value, locale), do: t(locale, :not_available)

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["merged", "done"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["merging", "waiting", "external"]) -> "#{base} state-badge-info"
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp format_provider_cr(provider, change_request, locale) do
    provider = provider || t(locale, :external_provider)
    change_request = change_request || t(locale, :unknown)
    "#{provider} ##{change_request}"
  end

  defp pretty_value(nil, locale), do: t(locale, :not_available)
  defp pretty_value(value, _locale), do: inspect(value, pretty: true, limit: :infinity)

  defp t(@zh_locale, key), do: Map.fetch!(translations_zh(), key)
  defp t(_locale, key), do: Map.fetch!(translations_en(), key)

  defp translations_en do
    %{
      attempt: "Attempt",
      blocked: "Blocked",
      blocked_at: "Blocked at",
      blocked_sessions_copy: "Issues paused because Codex requested operator input or approval.",
      blocked_sessions_title: "Blocked sessions",
      codeup_cr: "Codeup CR",
      codex_update: "Codex update",
      completed: "Completed",
      copied: "Copied",
      copy_id: "Copy ID",
      cr_status: "CR status",
      due_at: "Due at",
      error: "Error",
      external_provider: "external",
      external_waiting_copy: "Merging issues monitored through Linear and Codeup without starting Codex.",
      external_waiting_title: "External waiting",
      eyebrow: "Symphony Observability",
      finalized: "Finalized",
      hero_copy: "Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.",
      hero_title: "Operations Dashboard",
      issue: "Issue",
      json_details: "JSON details",
      last_checked: "Last checked",
      last_update: "Last update",
      linear_state: "Linear state",
      live: "Live",
      metric_blocked: "Blocked",
      metric_blocked_detail: "Issues paused for operator input or approval.",
      metric_external_waiting: "External waiting",
      metric_external_waiting_detail: "No-Codex issues watched through external APIs.",
      metric_recent_external: "Recent external",
      metric_recent_external_detail: "Externally finalized issues retained for review.",
      metric_retrying: "Retrying",
      metric_retrying_detail: "Issues waiting for the next retry window.",
      metric_running: "Running",
      metric_running_detail: "Active issue sessions in the current runtime.",
      metric_runtime: "Runtime",
      metric_runtime_detail: "Total Codex runtime across completed and active sessions.",
      metric_total_tokens: "Total tokens",
      next_action: "Next action",
      not_available: "n/a",
      no_active_sessions: "No active sessions.",
      no_blocked_sessions: "No blocked sessions.",
      no_external_waits: "No external waits.",
      no_retrying_issues: "No issues are currently backing off.",
      offline: "Offline",
      open_cr: "Open CR",
      pending: "pending",
      rate_limits_copy: "Latest upstream rate-limit snapshot, when available.",
      rate_limits_title: "Rate limits",
      recent_external_copy: "No-Codex external merges recently completed and retained for review.",
      recent_external_title: "Recent external finalizations",
      retry_queue_copy: "Issues waiting for the next retry window.",
      retry_queue_title: "Retry queue",
      revision: "Revision",
      running_sessions_copy: "Active issues, last known agent activity, and token usage.",
      running_sessions_title: "Running sessions",
      runtime_turns: "Runtime / turns",
      session: "Session",
      snapshot_unavailable: "Snapshot unavailable",
      state: "State",
      target_state: "Target state",
      token_policy: "Token policy",
      tokens: "Tokens",
      tokens_in: "In",
      tokens_out: "Out",
      tokens_total: "Total",
      unknown: "unknown",
      workspace_cleanup: "Workspace cleanup",
      workspace_cleanup_detail: "workspace cleanup"
    }
  end

  defp translations_zh do
    %{
      attempt: "尝试次数",
      blocked: "已阻塞",
      blocked_at: "阻塞时间",
      blocked_sessions_copy: "因 Codex 请求人工输入或审批而暂停的 issue。",
      blocked_sessions_title: "阻塞会话",
      codeup_cr: "Codeup CR",
      codex_update: "Codex 更新",
      completed: "已完成",
      copied: "已复制",
      copy_id: "复制 ID",
      cr_status: "CR 状态",
      due_at: "到期时间",
      error: "错误",
      external_provider: "外部",
      external_waiting_copy: "通过 Linear 和 Codeup 监控、无需启动 Codex 的合并中 issue。",
      external_waiting_title: "外部等待",
      eyebrow: "Symphony 可观测性",
      finalized: "完成时间",
      hero_copy: "展示当前状态、重试压力、Token 使用量，以及当前 Symphony 运行时的编排健康情况。",
      hero_title: "运维仪表盘",
      issue: "Issue",
      json_details: "JSON 详情",
      last_checked: "上次检查",
      last_update: "最近更新",
      linear_state: "Linear 状态",
      live: "在线",
      metric_blocked: "已阻塞",
      metric_blocked_detail: "等待人工输入或审批的 issue。",
      metric_external_waiting: "外部等待",
      metric_external_waiting_detail: "通过外部 API 监控的 No-Codex issue。",
      metric_recent_external: "最近外部完成",
      metric_recent_external_detail: "保留用于复查的外部完成 issue。",
      metric_retrying: "重试中",
      metric_retrying_detail: "等待下一个重试窗口的 issue。",
      metric_running: "运行中",
      metric_running_detail: "当前运行时中的活跃 issue 会话。",
      metric_runtime: "运行时长",
      metric_runtime_detail: "已完成和活跃会话累计的 Codex 运行时长。",
      metric_total_tokens: "Token 总数",
      next_action: "下一步",
      not_available: "无",
      no_active_sessions: "当前没有活跃会话。",
      no_blocked_sessions: "当前没有阻塞会话。",
      no_external_waits: "当前没有外部等待。",
      no_retrying_issues: "当前没有处于退避等待的 issue。",
      offline: "离线",
      open_cr: "打开 CR",
      pending: "待处理",
      rate_limits_copy: "可用时显示最新的上游限流快照。",
      rate_limits_title: "限流状态",
      recent_external_copy: "近期已完成并保留用于复查的 No-Codex 外部合并。",
      recent_external_title: "最近外部完成",
      retry_queue_copy: "等待下一个重试窗口的 issue。",
      retry_queue_title: "重试队列",
      revision: "版本",
      running_sessions_copy: "活跃 issue、最近一次 agent 活动和 Token 使用量。",
      running_sessions_title: "运行会话",
      runtime_turns: "运行时长 / 轮次",
      session: "会话",
      snapshot_unavailable: "快照不可用",
      state: "状态",
      target_state: "目标状态",
      token_policy: "Token 策略",
      tokens: "Token",
      tokens_in: "输入",
      tokens_out: "输出",
      tokens_total: "总计",
      unknown: "未知",
      workspace_cleanup: "工作区清理",
      workspace_cleanup_detail: "工作区清理"
    }
  end
end
