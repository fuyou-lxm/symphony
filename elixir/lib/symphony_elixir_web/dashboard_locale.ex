defmodule SymphonyElixirWeb.DashboardLocale do
  @moduledoc false

  @default_locale "en"
  @zh_locale "zh-CN"

  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @spec resolve(map()) :: String.t()
  def resolve(%{"lang" => lang}) when lang in [@zh_locale, "zh", "zh_CN", "zh-CN"], do: @zh_locale
  def resolve(_params), do: @default_locale
end
