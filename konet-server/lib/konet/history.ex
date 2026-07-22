defmodule Konet.History do
  @moduledoc """
  Optional per-room replay buffer: keeps the last N broadcast messages of each
  room in memory so late joiners receive recent context via a single
  `konet:history` push right after joining.

  Off by default (`KONET_HISTORY_LIMIT=0`). This is deliberately not durable
  storage — everything lives in ETS and is lost on restart. It exists so an
  agent/backend can broadcast into an empty room and a client connecting a few
  seconds later still sees it, without Konet growing a database.
  """
  use GenServer

  @table :konet_history

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def limit, do: Application.get_env(:konet, :history_limit, 0)

  def enabled?, do: limit() > 0

  def record(room_id, event, payload) do
    if enabled?() do
      entry = %{
        event: event,
        payload: payload,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      GenServer.cast(__MODULE__, {:record, room_id, entry})
    end

    :ok
  end

  @doc "Buffered messages for a room, oldest first."
  def list(room_id) do
    with true <- enabled?(),
         [{_, entries}] <- :ets.lookup(@table, room_id) do
      Enum.reverse(entries)
    else
      _ -> []
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, room_id, entry}, state) do
    entries =
      case :ets.lookup(@table, room_id) do
        [{_, existing}] -> [entry | existing]
        [] -> [entry]
      end

    :ets.insert(@table, {room_id, Enum.take(entries, limit())})
    {:noreply, state}
  end
end
