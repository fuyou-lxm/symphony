defmodule SymphonyElixir.AgentProvider do
  @moduledoc """
  Selects and describes the coding-agent runtime used by `AgentRunner`.
  """

  alias SymphonyElixir.AgentProvider.{AntigravityCli, AntigravitySdk, CodexAppServer}
  alias SymphonyElixir.Config

  @type session :: term()
  @type turn_result :: map()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, turn_result()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec configured_provider() :: module()
  def configured_provider do
    case Config.settings!().agent.provider do
      "antigravity_cli" -> AntigravityCli
      "antigravity_sdk" -> AntigravitySdk
      _ -> CodexAppServer
    end
  end
end
