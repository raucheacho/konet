defmodule Konet.Version do
  @moduledoc """
  The running server's version.

  Read from the compiled application spec, which mix.exs fills from the
  KONET_VERSION build arg. It used to be a "0.1.0" literal repeated in the two
  controllers and the Studio overview, so a v0.2.0 release still reported 0.1.0
  on /api/health.
  """

  @doc "The version string, e.g. \"0.3.0\" or \"0.0.0-dev\" for a local build."
  def current do
    case :application.get_key(:konet, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "unknown"
    end
  end
end
