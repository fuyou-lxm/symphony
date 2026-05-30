defmodule SymphonyElixir.Codeup.Client do
  @moduledoc """
  Minimal Yunxiao / Codeup HTTP client used by non-Codex merge watchers.
  """

  require Logger

  @default_domain "openapi-rdc.aliyuncs.com"

  @spec fetch_change_request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_change_request(metadata, opts \\ []) when is_map(metadata) and is_list(opts) do
    with {:ok, token} <- access_token(opts),
         {:ok, url} <- change_request_url(metadata),
         {:ok, response} <- request_fun(opts).(url, request_opts(token)) do
      decode_response(response)
    end
  end

  defp access_token(opts) do
    token =
      if Keyword.has_key?(opts, :token) do
        opts[:token]
      else
        Application.get_env(:symphony_elixir, :yunxiao_access_token) ||
          System.get_env("YUNXIAO_ACCESS_TOKEN") ||
          System.get_env("CODEUP_ACCESS_TOKEN")
      end

    case normalize_optional_string(token) do
      nil -> {:error, :missing_yunxiao_access_token}
      token -> {:ok, token}
    end
  end

  defp change_request_url(metadata) do
    with {:ok, organization_id} <-
           required_metadata(metadata, :organization_id, [:organizationId, "organization_id", "organizationId"]),
         {:ok, repository_id} <- required_metadata(metadata, :repository_id, [:repo_id, "repository_id", "repo_id"]),
         {:ok, change_request_id} <-
           required_metadata(metadata, :change_request_id, [:local_id, :localId, "change_request_id", "local_id", "localId"]) do
      domain = normalize_domain(metadata_value(metadata, :domain, ["domain"]) || @default_domain)
      path = "/oapi/v1/codeup/organizations/#{encode_path_segment(organization_id)}/repositories/#{encode_path_segment(repository_id)}/changeRequests/#{encode_path_segment(change_request_id)}"

      {:ok, "https://#{domain}#{path}"}
    end
  end

  defp required_metadata(metadata, primary_key, aliases) do
    case normalize_optional_string(metadata_value(metadata, primary_key, aliases)) do
      nil -> {:error, {:missing_codeup_metadata, primary_key}}
      value -> {:ok, value}
    end
  end

  defp metadata_value(metadata, primary_key, aliases) do
    Enum.find_value([primary_key | aliases], fn key -> Map.get(metadata, key) end)
  end

  defp normalize_domain(domain) do
    domain
    |> to_string()
    |> String.trim()
    |> String.trim_leading("https://")
    |> String.trim_leading("http://")
    |> String.trim_trailing("/")
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(_value), do: nil

  defp encode_path_segment(value) do
    value
    |> to_string()
    |> URI.encode_www_form()
  end

  defp request_opts(token) do
    [
      headers: [
        {"x-yunxiao-token", token},
        {"accept", "application/json"}
      ],
      connect_options: [timeout: 30_000]
    ]
  end

  defp request_fun(opts), do: Keyword.get(opts, :request_fun, &Req.get/2)

  defp decode_response(%{status: status, body: body}) when status in 200..299 do
    unwrap_body(body)
  end

  defp decode_response(%{status: status, body: body}) do
    Logger.warning("Codeup change request fetch failed status=#{inspect(status)} body=#{summarize_body(body)}")
    {:error, {:codeup_api_status, status}}
  end

  defp decode_response(response) do
    Logger.warning("Codeup change request fetch returned unexpected response: #{inspect(response)}")
    {:error, :codeup_unexpected_response}
  end

  defp unwrap_body(%{"success" => true, "result" => result}) when is_map(result), do: {:ok, result}
  defp unwrap_body(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp unwrap_body(body) when is_map(body), do: {:ok, body}
  defp unwrap_body(body), do: {:error, {:codeup_unexpected_body, body}}

  defp summarize_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 1_000)
  end

  defp summarize_body(body) do
    inspect(body, printable_limit: 1_000, limit: 20)
  end
end
