defmodule Konet.Tables do
  @moduledoc """
  Owns every named ETS table in Konet, and nothing else.

  The tables used to be created inside each worker's `init/1`. ETS tables die
  with their owning process, so a worker crash destroyed its table and the
  `:one_for_one` restart recreated it **empty**. For `Konet.RateLimiter` that was
  harmless; for `Konet.Floor` it silently freed every held floor; for
  `Konet.ChannelRegistry` the Studio's channel list emptied while sockets were
  still connected and **never recovered**, because counts are only incremented on
  join.

  This process exists so that cannot happen. It is started before the workers,
  creates the tables `:public` so they need no ownership to be written to, and
  then does nothing at all — it has no callbacks that can fail, so the only way
  it dies is the supervisor going down, at which point the tables are moot
  anyway.

  Workers therefore read and write the tables without owning them, and a worker
  crash costs its own in-memory state (which is small and rebuildable) rather
  than the data.
  """
  use GenServer

  @tables [
    # {name, options}
    {:konet_channels, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:konet_rl, [:named_table, :public, :set, {:write_concurrency, true}]},
    {:konet_floor, [:named_table, :public, :set, {:read_concurrency, true}]},
    {:konet_history, [:named_table, :public, :set, {:read_concurrency, true}]}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "The tables this process owns, for tests and diagnostics."
  def names, do: Enum.map(@tables, fn {name, _opts} -> name end)

  @impl true
  def init(_) do
    for {name, opts} <- @tables do
      # :undefined rather than a crash if something already made it — the test
      # suite restarts the application in-process, and losing the race here is
      # not worth taking the supervisor down for.
      if :ets.whereis(name) == :undefined do
        :ets.new(name, opts)
      end
    end

    {:ok, %{}}
  end
end
