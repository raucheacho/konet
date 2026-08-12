defmodule KonetWeb.Cors do
  @moduledoc """
  Origin allow-list for the REST API, backed by the same `KONET_ALLOWED_ORIGINS`
  value as the WebSocket origin check.

  Kept as a function rather than a literal list in the endpoint because the
  endpoint's plug options are fixed at compile time, while the allow-list is
  read from the environment at boot.
  """

  @doc """
  Whether `origin` may call the REST API.

  Unset or `"*"` means open, which is the default and matches
  `check_origin: false` on the socket.
  """
  def allowed?(origin) do
    case Application.get_env(:konet, :allowed_origins) do
      nil -> true
      [] -> true
      origins when is_list(origins) -> origin in origins
      _ -> true
    end
  end
end
