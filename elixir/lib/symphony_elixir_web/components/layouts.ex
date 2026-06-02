defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign_new(:locale, fn -> "en" end)

    ~H"""
    <!DOCTYPE html>
    <html lang={@locale}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;

            function formatRuntimeSeconds(seconds, locale) {
              var wholeSeconds = Math.max(Math.trunc(seconds || 0), 0);
              var mins = Math.floor(wholeSeconds / 60);
              var secs = wholeSeconds % 60;

              if (locale === "zh-CN") return mins + "分 " + secs + "秒";

              return mins + "m " + secs + "s";
            }

            function refreshRuntimeClocks() {
              var nowSeconds = Math.floor(Date.now() / 1000);

              document.querySelectorAll("[data-runtime-clock]").forEach(function (node) {
                var locale = node.dataset.locale || "en";

                if (node.dataset.runtimeClock === "total") {
                  var baseSeconds = Number(node.dataset.baseSeconds || 0);
                  var renderedAt = Number(node.dataset.renderedAt || nowSeconds);
                  node.textContent = formatRuntimeSeconds(baseSeconds + nowSeconds - renderedAt, locale);
                  return;
                }

                if (node.dataset.runtimeClock === "session") {
                  var startedAt = Number(node.dataset.startedAt || nowSeconds);
                  var turnCount = Number(node.dataset.turnCount || 0);
                  var runtime = formatRuntimeSeconds(nowSeconds - startedAt, locale);

                  node.textContent = turnCount > 0 ? runtime + " / " + turnCount : runtime;
                }
              });
            }

            refreshRuntimeClocks();
            setInterval(refreshRuntimeClocks, 1000);
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
