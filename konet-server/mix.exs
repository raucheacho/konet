defmodule Konet.MixProject do
  use Mix.Project

  # The release tag is the source of truth. CI passes it in as a build arg, so
  # /api/health and the Studio report what actually shipped instead of a literal
  # that nobody remembers to bump.
  @version System.get_env("KONET_VERSION") || "0.0.0-dev"

  def project do
    [
      app: :konet,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Konet.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.5"},
      {:phoenix_pubsub, "~> 2.1"},
      {:joken, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:corsica, "~> 2.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild konet"],
      "assets.deploy": ["esbuild konet --minify", "phx.digest"]
    ]
  end
end
