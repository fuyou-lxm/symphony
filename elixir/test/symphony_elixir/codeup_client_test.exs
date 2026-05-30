defmodule SymphonyElixir.CodeupClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codeup.Client

  test "fetch_change_request calls the Yunxiao center-edition Codeup endpoint with token auth" do
    metadata = %{
      domain: "openapi-rdc.aliyuncs.com",
      organization_id: "org-123",
      repository_id: "group/demo",
      change_request_id: "3"
    }

    request_fun = fn url, opts ->
      send(self(), {:request, url, opts})
      {:ok, %{status: 200, body: %{"success" => true, "result" => %{"status" => "MERGED"}}}}
    end

    assert {:ok, %{"status" => "MERGED"}} =
             Client.fetch_change_request(metadata,
               token: "pt-test",
               request_fun: request_fun
             )

    assert_receive {:request, url, opts}
    assert url == "https://openapi-rdc.aliyuncs.com/oapi/v1/codeup/organizations/org-123/repositories/group%2Fdemo/changeRequests/3"
    assert {"x-yunxiao-token", "pt-test"} in Keyword.fetch!(opts, :headers)
  end

  test "fetch_change_request requires organization id" do
    metadata = %{
      domain: "openapi-rdc.aliyuncs.com",
      repository_id: "6907286",
      change_request_id: "3"
    }

    request_fun = fn _url, _opts ->
      flunk("request should not be sent without organization_id")
    end

    assert {:error, {:missing_codeup_metadata, :organization_id}} =
             Client.fetch_change_request(metadata,
               token: "pt-test",
               request_fun: request_fun
             )
  end

  test "fetch_change_request requires a Yunxiao token" do
    metadata = %{
      domain: "openapi-rdc.aliyuncs.com",
      organization_id: "org-123",
      repository_id: "6907286",
      change_request_id: "3"
    }

    assert {:error, :missing_yunxiao_access_token} = Client.fetch_change_request(metadata, token: nil)
  end
end
