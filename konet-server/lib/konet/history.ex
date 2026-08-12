defmodule Konet.History do
  @moduledoc """
  Optional per-room replay buffer: keeps the last N broadcast messages of each
  room in memory so late joiners receive recent context via a single
  `konet:history` push right after joining.

  Off by default (`KONET_HISTORY_LIMIT=0`). This is deliberately not durable
  storage — everything lives in ETS and is lost on restart. It exists so an
  agent/backend can broadcast into an empty room and a client connecting a few
  seconds later still sees it, without Konet growing a database.

  Rows expire on age rather than on the room emptying, because outliving the
  room is the whole point: dropping a room's buffer when its last member leaves
  would delete exactly the messages a late joiner came for. `KONET_HISTORY_TTL`
  bounds how long that can go on, so a workload that creates many short-lived
  room names does not grow the table without limit.
  """
  use GenServer

  @table :konet_history
  @default_ttl_seconds 900
  @sweep_every_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def limit, do: Application.get_env(:konet, :history_limit, 0)

  def enabled?, do: limit() > 0

  @doc "How long a room's buffer outlives its last message, in seconds."
  def ttl_seconds, do: Application.get_env(:konet, :history_ttl_seconds, @default_ttl_seconds)

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
         [{_, entries, _written_at}] <- :ets.lookup(@table, room_id) do
      Enum.reverse(entries)
    else
      _ -> []
    end
  end

  @doc "Drops a room's buffer. Used by tests and by the sweep."
  def forget(room_id), do: :ets.delete(@table, room_id)

  # Table owned by Konet.Tables — see the note there.
  @impl true
  def init(_) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, room_id, entry}, state) do
    entries =
      case :ets.lookup(@table, room_id) do
        [{_, existing, _written_at}] -> [entry | existing]
        [] -> [entry]
      end

    :ets.insert(@table, {room_id, Enum.take(entries, limit()), now_ms()})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - ttl_seconds() * 1_000
    # =< rather than <, so a TTL of 0 still evicts a room written in the current
    # millisecond instead of silently keeping everything.
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
